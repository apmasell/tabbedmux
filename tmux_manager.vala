namespace TabbedMux {
	public const string TERM_TYPE = "xterm";
	private extern async void wait_idle ();

	/**
	 * The kind of data we expect back from TMux. This controls how the data will be parsed.
	 */
	private enum NextOutput {
		NONE,
		CAPTURE,
		SESSION_ID,
		WINDOWS,
		WINDOW_SIZE
	}

	/**
	 * A cookie for future TMux output.
	 */
	private class OutputTodo {
		internal NextOutput action;
		internal int id;
	}

	private class ExecTodo {
		internal string command;
		internal NextOutput action;
		internal int window_id;
	}

	/**
	 * A TMux session where a subclass will provide a byte stream to talk to that session.
	 */
	public abstract class TMuxStream : Object {
		private const uint8 new_line[] = { '\n' };

		StringBuilder buffer = new StringBuilder ();
		protected Cancellable cancellable = new Cancellable ();
		protected bool die_on_cancel = false;
		private Gee.Queue<ExecTodo> exec_queue = new Gee.ArrayQueue<ExecTodo> ();
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
		 * Update the font in all the interested children.
		 */
		public signal void change_font (Pango.FontDescription? font);

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

		internal void attempt_command (string command, NextOutput output_type = NextOutput.NONE, int window_id = 0) {
			var todo = new ExecTodo ();
			todo.command = command;
			todo.action = output_type;
			todo.window_id = window_id;
			exec_queue.offer (todo);
			cancellable.cancel ();
		}

		/**
		 * Tell the underlying asynchronous I/O process to stop.
		 */
		public void cancel () {
			die_on_cancel = true;
			cancellable.cancel ();
		}

		/**
		 * Create a new TMux window on the server.
		 */
		public void create_window () {
			attempt_command ("new-window");
		}

		/**
		 * Delete a TMux buffer.
		 */
		public void delete_buffer (uint buffer = 0) {
			attempt_command (@"delete-buffer -b $(buffer)");
		}

		/**
		 * Kill the current session.
		 */
		public void destroy () {
			attempt_command ("kill-session");
		}

		/**
		 * Ask the remote TMux server to die in a fire.
		 */
		public void kill () {
			attempt_command ("kill-server");
		}

		/**
		 * Rename the session on the other side.
		 */
		public void rename (string name) {
			attempt_command (@"rename-session $(Shell.quote(name))");
		}

		/**
		 * Set a TMux buffer.
		 */
		public void set_buffer (string data, uint buffer = 0) {
			attempt_command (@"set-buffer -b $(buffer) $(Shell.quote (data))");
		}

		/**
		 * Blast some data at TMux and register a cookie to handle the output.
		 */
		internal async void exec (bool allow_dispatch, string command, NextOutput output_type = NextOutput.NONE, int window_id = 0) throws Error {
			var command_id = ++output_num;
			var todo = new OutputTodo ();
			todo.action = output_type;
			todo.id = window_id;
			outputs[command_id] = todo;
			yield write_helper (command.data, allow_dispatch);
			yield write_helper (new_line, allow_dispatch);
		}

		private async void write_helper (uint8[] data, bool allow_dispatch) throws Error {
			while (true) {
				try {
					var length = yield write (data);
					if (length != data.length) {
						throw new IOError.FAILED ("Incomplete write.");
					}
					return;
				} catch (IOError.CANCELLED e) {
					if (die_on_cancel) {
						throw e;
					}
					cancellable.reset ();
					if (allow_dispatch) {
						yield dispatch_queued_commands ();
					}
				}
			}
		}

		/**
		 * The “main loop” for handling TMux data.
		 */
		private async string process_io () {
			try {
				/* Our first command is to figure out what our own session ID is, since TMux uses a numeric one instead of text. */
				yield exec (true, "display-message -p '#S'", NextOutput.SESSION_ID);
				yield dispatch_queued_commands ();
			} catch (Error e) {
				message ("%s:%s: %s", name, session_name, e.message);
				return e.message;
			}

			while (true) {
				try {
					/* Read a line from TMux and shove it into a decoder. */
					var str = yield read_line_async ();
					if (str == null) {
						message ("%s:%s: End of stream.", name, session_name);
						return "No more data to read";
					}
					var decoder = Decoder ((!)(owned) str);
					switch (decoder.command) {
					 /*
					  * TMux sent some kind of data. Find the matching cookie and process the data.
					  */
					 case "%begin" :
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
							 /* Before we capture the pane, clear the screen. */
							 windows[window_id].rx_data ("\033[2J".data);
						 }
						 string? output_line;
						 while ((output_line = yield read_line_async ()) !=  null) {
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
									  window.rx_data ("\r\n".data);
									  if (((!)output_line).length > 0) {
										  window.rx_data (((!)output_line).data);
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
								  var info_decoder = Decoder ((!)(owned) output_line, false, ':');
								  var id = info_decoder.pop_id ();
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
								  message ("%s:%s: Got @%d. Title is: %s", name, session_name, id, title);
								  if (window.title != title) {
									  window.title = title;
									  window.renamed ();
								  }
								  break;

							  case NextOutput.WINDOW_SIZE:
								  var info_decoder = Decoder ((!)(owned) output_line, false, ':');
								  var id = info_decoder.pop_id ();
								  var width = info_decoder.pop_id ();
								  var height = info_decoder.pop_id ();
								  if (windows.has_key (id)) {
									  var window = windows[id];
									  window.set_size (width, height);
								  }
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
						 yield exec (true, @"list-windows -t $(Shell.quote(session_name)) -F \"#{window_id}:#{window_name}\"", NextOutput.WINDOWS);
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
							 var text = decoder.get_remainder ();
							 window.rx_data (text.data);
						 }
						 break;

					 default:
						 critical ("%s:%s: Unrecognised command from TMux: %s", name, session_name, (!)str);
						 break;
					}
					yield wait_idle ();
				} catch (Error e) {
					critical ("%s:%s: %s", name, session_name, e.message);
					return e.message;
				}
			}
		}

		protected async void dispatch_queued_commands () throws Error {
			ExecTodo todo;
			while ((todo = exec_queue.poll ()) != null) {
				yield exec (false, todo.command, todo.action, todo.window_id);
			}
		}

		/**
		 * A subclass must implement a method to read data from the TMux instance.
		 */
		protected abstract async ssize_t read (uint8[] buffer) throws Error;

		/**
		 * Read a line from the remote TMux instance.
		 */
		private async string? read_line_async () throws Error {
			uint8 data[1024];
			int new_line;
			/* Read and append to a StringBuilder until we have a line. */
			while ((new_line = search_buffer (buffer)) < 0) {
				try {
					var length = yield read (data);
					buffer.append_len ((string) data, length);
				} catch (IOError.CANCELLED e) {
					if (die_on_cancel) {
						throw e;
					}
					cancellable.reset ();
					yield dispatch_queued_commands ();
				}
			}
			/* Take the whole line from the buffer and return it. */
			var str = buffer.str[0 : new_line];
			buffer.erase (0, new_line + 1);
			return str;
		}

		/**
		 * Start reading data from TMux.
		 */
		public void start () {
			if (!started) {
				process_io.begin ((sender, result) => connection_closed (process_io.end (result)));
				started = true;
			}
		}

		/**
		 * A subclass must implement a method to blast data at the TMux instance.
		 */
		protected abstract async ssize_t write (uint8[] data) throws Error;
	}

	/**
	 * A window on the TMux instance, contained in a session.
	 */
	public class TMuxWindow : Object {
		private int id;
		public unowned TMuxStream stream {
			get; private set;
		}
		/**
		 * Width of the terminal, in characters.
		 */
		public int width {
			get; private set;
		}
		/**
		 * Height of the terminal, in characters.
		 */
		public int height {
			get; private set;
		}
		/**
		 * The terminal's session title, as set by your fancy prompt in the remote
		 * shell or renaming it in TMux.
		 */
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
			stream.attempt_command (@"kill-window -t @$(id)");
		}

		/**
		 * Paste a TMux buffer.
		 */
		public void paste_buffer (uint buffer = 0) {
			stream.attempt_command (@"paste-buffer -p -b $(buffer) -t @$(id)");
		}

		/**
		 * Paste text.
		 *
		 * Pastes text using bracketed pasting, when needed.
		 */
		public void paste_text (string text) {
			var buffer = new StringBuilder ();
			buffer.append ("set-buffer \"");
			for (var it = 0; it < text.length; it++) {
				switch (text[it]) {
				 case '\n':
					 buffer.append_c ('\r');
					 break;

				 case '\"':
					 buffer.append_c ('\\');
					 buffer.append_c ('\"');
					 break;

				 case '\\':
					 buffer.append_c ('\\');
					 buffer.append_c ('\\');
					 break;

				 default:
					 buffer.append_c (text[it]);
					 break;
				}
			}
			buffer.append_c ('\"');
			stream.attempt_command (buffer.str);
			stream.attempt_command (@"paste-buffer -dp -t @$(id)");
		}

		/**
		 * Get window size from TMux.
		 */
		public void pull_size () {
			stream.attempt_command (@"list-windows -t $(Shell.quote(stream.session_name)) -F \"#{window_id}:#{window_width}:#{window_height}\"", NextOutput.WINDOW_SIZE);
		}

		/**
		 * Re-request the contents of the window instead of getting incremenal changes.
		 */
		public void refresh () {
			stream.attempt_command (@"capture-pane -p -e -t @$(id)", NextOutput.CAPTURE, id);
		}

		/**
		 * Rename the window.
		 */
		public void rename (string name) {
			stream.attempt_command (@"rename-window -t @$(id) $(Shell.quote(name))");
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
			stream.attempt_command (@"refresh-client -C $(width),$(height)");
		}

		/**
		 * Change the size of the terminal.
		 */
		internal void set_size (int width, int height) {
			/* Don't do this if it hasn't changed. We get this event a lot from TMux because we listed the windows, but there might be no change. */
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
			var command = new StringBuilder ();
			for (var it = 0; it < text.length; it++) {
				if (it % 50 == 0) {
					if (it > 0) {
						stream.attempt_command (command.str);
					}
					command.printf ("send-keys -t @%d", id);
				}
				command.append_printf (" 0x%02x", text[it]);
			}
			stream.attempt_command (command.str);
		}
	}
}
