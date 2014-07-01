namespace TabbedMux {
	public const string TERM_TYPE = "xterm";

	/**
	 * The kind of data we expect back from TMux. This controls how the data will be parsed.
	 */
	private enum NextOutput {
		NONE,
		CAPTURE,
		SESSION_ID,
		WINDOWS
	}

	/**
	 * A cookie for future TMux output.
	 */
	private class OutputTodo {
		internal NextOutput action;
		internal int id;
	}

	/**
	 * A TMux session where a subclass will provide a byte stream to talk to that session.
	 */
	public abstract class TMuxStream : Object {
		private Cancellable cancellable = new Cancellable ();
		private int id = -1;
		private int output_num = 1;
		private Gee.HashMap<int, OutputTodo> outputs = new Gee.HashMap<int, OutputTodo> ();
		private bool started = false;
		private Gee.HashMap<int, TMuxWindow> windows = new Gee.HashMap<int, TMuxWindow> ();

		public string name {
			get; private set;
		}
		public string session_name {
			get; internal set;
		}
		public string binary {
			get; internal set;
		}

		protected TMuxStream (string name, string session_name, string binary) {
			this.name = name;
			this.session_name = session_name;
			this.binary = binary;
		}

		/**
		 * Event fired when there is no more data from TMux.
		 */
		public virtual signal void connection_closed (string reason) {
			foreach (var window in windows.values) {
				window.closed ();
			}
		}
		/**
		 * Event fired when the TMux session is renamed.
		 */
		public signal void renamed ();
		/**
		 * Event fired when a new window is created.
		 *
		 * The window could be created because of a call to {@create_window} or because another concurrently-connected session created it.
		 */
		public signal void window_created (TMuxWindow window);

		/**
		 * Tell the underlying asynchronous I/O process to stop.
		 */
		public void cancel () {
			cancellable.cancel ();
		}

		/**
		 * Create a new TMux window on the server.
		 */
		public void create_window () {
			try {
				exec ("new-window");
			} catch (IOError e) {
				critical ("%s:%s: Failed to create window: %s", name, session_name, e.message);
			}
		}

		/**
		 * Delete a TMux buffer.
		 */
		public void delete_buffer (uint buffer = 0) {
			try {
				exec (@"delete-buffer -b $(buffer)");
			} catch (IOError e) {
				critical ("%s:%s: Delete buffer failed: %s", name, session_name, e.message);
			}
		}

		/**
		 * Kill the current session.
		 */
		public void destroy () {
			try {
				exec ("kill-session");
			} catch (IOError e) {
				critical ("%s:%s: Failed to kill session: %s", name, session_name, e.message);
			}
		}

		/**
		 * Ask the remote TMux server to die in a fire.
		 */
		public void kill () {
			try {
				exec ("kill-server");
			} catch (IOError e) {
				critical ("%s:%s: Failed to kill server: %s", name, session_name, e.message);
			}
		}

		/**
		 * Rename the session on the other side.
		 */
		public void rename (string name) {
			try {
				exec (@"rename-session $(Shell.quote(name))");
			} catch (IOError e) {
				critical ("%s:%s: Failed to rename session: %s", name, session_name, e.message);
			}
		}

		/**
		 * Set a TMux buffer.
		 */
		public void set_buffer (string data, uint buffer = 0) {
			try {
				exec (@"set-buffer -b $(buffer) $(Shell.quote (data))");
			} catch (IOError e) {
				critical ("%s:%s: Paste buffer failed: %s", name, session_name, e.message);
			}
		}

		/**
		 * Blast some data at TMux and register a cookie to handle the output.
		 */
		internal void exec (string command, NextOutput output_type = NextOutput.NONE, int window_id = 0) throws IOError {
			var command_id = ++output_num;
			message ("%s:%s: Sending command %d: %s", name, session_name, command_id, command);
			write (command.data);
			write (new uint8[] { '\n' });
			var todo = new OutputTodo ();
			todo.action = output_type;
			todo.id = window_id;
			outputs[command_id] = todo;
		}

		/**
		 * The “main loop” for handling TMux data.
		 */
		private async string process_io () {
			while (true) {
				try {
					var str = yield read_line_async (cancellable);
					if (str == null) {
						message ("%s:%s: End of stream.", name, session_name);
						return "No more data to read";
					}
					var decoder = Decoder ((!)(owned) str);
					message ("%s:%s: Processing: %s", name, session_name, decoder.command);
					switch (decoder.command) {
					 /*
					  * TMux sent some kind of data. Find the matching cookie and process the data.
					  */
					 case "%begin":
						 var time = decoder.pop_id ();
						 var output_num = decoder.pop_id ();
						 NextOutput action = NextOutput.NONE;
						 int window_id = 0;
						 if (outputs.has_key (output_num)) {
							 var todo = outputs[output_num];
							 outputs.unset (output_num);
							 action = todo.action;
							 window_id = todo.id;
						 }
						 if (action == NextOutput.CAPTURE && windows.has_key (window_id)) {
							 windows[window_id].rx_data ("\033[2J".data);
						 }
						 string? output_line;
						 while ((output_line = yield read_line_async (cancellable)) !=  null) {
							 if (((!)output_line).has_prefix ("%end") || ((!)output_line).has_prefix ("%error")) {
								 var temp = Decoder (((!)output_line).dup ());
								 if (temp.pop_id () == time && temp.pop_id () == output_num) {
									 break;
								 }
							 }

							 switch (action) {
							  /*
							   * A whole window update. Pump through to Vte.
							   */
							  case NextOutput.CAPTURE :
								  if (windows.has_key (window_id)) {
									  var window = windows[window_id];
									  if (((!)output_line).length > 0) {
										  window.rx_data (((!)output_line).data);
										  window.rx_data ("\r\n".data);
									  }
								  } else {
									  warning ("%s:%s: Received capture for non-existent window %d.", name, session_name, window_id);
								  }
								  break;

							  /*
							   * Our own session ID.
							   *
							   * TMux uses numeric session IDs, but we can login with a text one. This lets us get our own ID, so we can correctly identify messages for ourself.
							   */
							  case NextOutput.SESSION_ID:
								  var id = int.parse ((!)output_line);
								  this.id = id;
								  break;

							  /*
							   * A list of windows.
							   */
							  case NextOutput.WINDOWS:
								  message ("%s:%s: Received pane information. %s", name, session_name, (!)output_line);
								  var info_decoder = Decoder ((!)(owned) output_line, false, ':');
								  var id = info_decoder.pop_id ();
								  var width = info_decoder.pop_id ();
								  var height = info_decoder.pop_id ();
								  var title = info_decoder.get_remainder ();
								  TMuxWindow window;
								  if (windows.has_key (id)) {
									  window = windows[id];
								  } else {
									  window = new TMuxWindow (this, id);
									  windows[id] = window;
									  window.title = title;
									  window_created (window);
									  window.refresh ();
								  }
								  message ("%s:%s: Got %d %d for @%d. Title is: %s", name, session_name, width, height, id, title);
								  if (window.title != title) {
									  window.title = title;
									  window.renamed ();
								  }
								  window.set_size (width, height);
								  break;

							  case NextOutput.NONE:
								  break;

							  default:
								  if (((!)output_line).length > 0) {
									  message ("%s:%s: Unsolicited output: %s", name, session_name, (!)output_line);
								  }
								  break;
							 }
						 }
						 if (output_line == null) {
							 message ("%s:%s: End of input reading data block from TMux.", name, session_name);
							 return "Connection unceremoniously terminated.";
						 } else {
							 message ("%s:%s: Finished output block: %s", name, session_name, (!)output_line);
						 }
						 break;

					 /*
					  * The other end is dying gracefully.
					  */
					 case "%exit":
						 message ("%s:%s: Explicit exit request from TMux.", name, session_name);
						 if (str != null) {
							 return str;
						 } else {
							 return "TMux server shutdown.";
						 }

					 /*
					  * Stuff happened in other sessions that is completely immaterial to our lives.
					  */
					 case "%sessions-changed":
					 case "%unlinked-window-add":
					 case "%unlinked-window-rename":
					 case "%unlinked-window-delete":
						 break;

					 /*
					  * Pretty new name.
					  */
					 case "%session-renamed":
						 if (id == decoder.pop_id ()) {

							 session_name = decoder.get_remainder ();
							 renamed ();
						 }
						 break;

					 /*
					  * Something happened that affected the window. Not enough information is provided to do anything, so slot a window list update.
					  */
					 case "%session-changed":
					 case "%window-add":
						 exec (@"list-windows -t $(Shell.quote(session_name)) -F \"#{window_id}:#{window_width}:#{window_height}:#{window_name}\"", NextOutput.WINDOWS);
						 break;

					 /*
					  * Window closed. Kill the tab.
					  */
					 case "%window-close":
						 var window_id = decoder.pop_id ();
						 if (windows.has_key (window_id)) {
							 windows[window_id].closed ();
							 windows.unset (window_id);
							 message ("%s:%s: Closing window %d.", name, session_name, window_id);
						 }
						 break;

					 /*
					  * Window renamed. Update tab.
					  */
					 case "%window-renamed":
						 var window_id = decoder.pop_id ();
						 if (windows.has_key (window_id)) {
							 var window = windows[window_id];
							 window.title = decoder.get_remainder ();
							 window.renamed ();
							 message ("%s:%s: Renaming window %d.", name, session_name, window_id);
						 }
						 break;

					 /*
					  * Window size changed. Update the terminal size in the tab.
					  */
					 case "%layout-change":
						 var window_id = decoder.pop_id ();
						 if (windows.has_key (window_id)) {
							 var layout = decoder.get_remainder ().split (",");
							 var window = windows[window_id];
							 var coords = layout[1].split ("x");
							 window.set_size (int.parse (coords[0]), int.parse (coords[1]));
							 message ("%s:%s: Layout change on window %d.", name, session_name, window_id);
						 }
						 break;

					 /*
					  * Pump data to Vte.
					  */
					 case "%output":
						 var window_id = decoder.pop_id ();
						 if (windows.has_key (window_id)) {
							 var window = windows[window_id];
							 decoder.pop ();
							 var text = decoder.get_remainder ();
							 window.rx_data (text.data);
							 message ("%s:%s: Output for window %d.", name, session_name, window_id);
						 }
						 break;

					 default:
						 critical ("%s:%s: Unrecognised command from TMux: %s", name, session_name, (!)str);
						 break;
					}
				} catch (Error e) {
					critical ("%s:%s: %s", name, session_name, e.message);
					return e.message;
				}
			}
		}

		/**
		 * A subclass must implement a method to read data from the TMux instance.
		 */
		protected abstract async string? read_line_async (Cancellable cancellable) throws Error;

		/**
		 * Start reading data from TMux.
		 */
		public void start () {
			if (!started) {
				process_io.begin ((sender, result) => connection_closed (process_io.end (result)));
				started = true;
				try {
					exec ("display-message -p '#S'", NextOutput.SESSION_ID);
				} catch (Error e) {
					message ("%s:%s: %s", name, session_name, e.message);
				}
			}
		}

		/**
		 * A subclass must implement a method to blast data at the TMux instance.
		 */
		protected abstract void write (uint8[] data) throws IOError;
	}

	/**
	 * A window on the TMux instance, contained in a session.
	 */
	public class TMuxWindow : Object {
		private int id;
		public unowned TMuxStream stream {
			get; private set;
		}
		public int width {
			get; private set;
		}
		public int height {
			get; private set;
		}
		public string title {
			get; internal set; default = "unknown";
		}

		internal TMuxWindow (TMuxStream stream, int id) {
			this.stream = stream;
			this.id = id;
		}

		/**
		 * This window has been closed, either because the process has exited or the stream has closed.
		 */
		public signal void closed ();
		/**
		 * The title has been changed by the remote end.
		 */
		public signal void renamed ();
		/**
		 * Data has arrived from the process.
		 */
		public signal void rx_data (uint8[] data);
		/**
		 * The remote end has changed the size of the terminal window (rows and columns).
		 */
		public signal void size_changed (int old_width, int old_height);

		/**
		 * Kill the current window on the remote end.
		 */
		public void destroy () {
			try {
				stream.exec (@"kill-window -t @$(id)");
			} catch (IOError e) {
				critical ("%s:%s:%d: Kill window failed: %s", stream.name, stream.session_name, id, e.message);
			}
		}

		/**
		 * Paste a TMux buffer.
		 */
		public void paste_buffer (uint buffer = 0) {
			try {
				stream.exec (@"paste-buffer -p -b $(buffer) -t @$(id)");
			} catch (IOError e) {
				critical ("%s:%s:%d: Paste buffer failed: %s", stream.name, stream.session_name, id, e.message);
			}
		}

		/**
		 * Re-request the contents of the window instead of getting incremenal changes.
		 */
		public void refresh () {
			try {
				stream.exec (@"capture-pane -p -e -t @$(id)", NextOutput.CAPTURE, id);
			} catch (IOError e) {
				critical ("%s:%s:%d: Capture pane failed: %s", stream.name, stream.session_name, id, e.message);
			}
		}

		/**
		 * Rename the window.
		 */
		public void rename (string name) {
			try {
				stream.exec (@"rename-window -t @$(id) $(Shell.quote(name))");
			} catch (IOError e) {
				critical ("%s:%s:%d: Failed to rename window: %s", stream.name, stream.session_name, id, e.message);
			}
		}

		/**
		 * Tell the remote end the size of the window is changing.
		 *
		 * This is sort of shared across all windows in the current stream. It's the maximum size a window can be, but not necessarily the size any window will be.
		 */
		public void resize (int width, int height) {
			if (width == this.width && height == this.height || width == 10 && height == 10) {
				return;
			}
			try {
				stream.exec (@"refresh-client -C $(width),$(height)");
			} catch (IOError e) {
				critical ("%s:%s:%d: Resize client failed: %s", stream.name, stream.session_name, id, e.message);
			}
		}

		internal void set_size (int width, int height) {
			if (width != this.width || height != this.height) {
				var old_width = width;
				var old_height = height;
				this.width = width;
				this.height = height;
				size_changed (old_width, old_height);
			}
		}

		/**
		 * Call this when the user smashes the keyboard.
		 */
		public void tx_data (uint8[] text) {
			try {
				var command = new StringBuilder ();
				command.append_printf ("send-keys -t @%d", id);
				for (var it = 0; it < text.length; it++) {
					command.append_printf (" 0x%02x", text[it]);
				}
				stream.exec (command.str);
			} catch (IOError e) {
				critical ("%s:%s:%d: Send keys failed: %s", stream.name, stream.session_name, id, e.message);
			}
		}
	}
}
