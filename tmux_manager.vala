namespace TabbedMux {
	public const string TERM_TYPE = "xterm";

	private enum NextOutput {
		NONE,
		CAPTURE,
		SESSION_ID,
		WINDOWS
	}

	private class OutputTodo {
		internal NextOutput action;
		internal int id;
	}

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
		public string? session_name {
			get; internal set;
		}

		protected TMuxStream (string name, string session_name) {
			this.name = name;
			this.session_name = session_name;
		}

		public virtual signal void connection_closed (string reason) {
			foreach (var window in windows.values) {
				window.closed ();
			}
		}
		public signal void renamed ();
		public signal void window_created (TMuxWindow window);

		public void cancel () {
			cancellable.cancel ();
		}

		public void create_window () {
			try {
				exec ("new-window");
			} catch (IOError e) {
				critical ("Failed to create window: %s", e.message);
			}
		}

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

		private async string process_io () {
			while (true) {
				try {
					var str = yield read_line_async (cancellable);
					if (str == null) {
						message ("%s:%s: End of stream.", name, session_name);
						return "No more data to read";
					}
					var parts = str.split (" ");
					message ("%s:%s: Processing: %s", name, session_name, parts[0]);
					switch (parts[0]) {
					 case "%begin" :
						 var output_num = int.parse (parts[2]);
						 NextOutput action = NextOutput.NONE;
						 int window_id = 0;
						 if (outputs.has_key (output_num)) {
							 var todo = outputs[output_num];
							 outputs.unset (output_num);
							 action = todo.action;
							 window_id = todo.id;
						 }
						 string? output_line;
						 while ((output_line = yield read_line_async (cancellable)) !=  null && !(output_line.has_prefix ("%end") || output_line.has_prefix ("%error"))) {

							 switch (action) {
							  case NextOutput.CAPTURE :
								  if (windows.has_key (window_id)) {
									  var window = windows[window_id];
									  if (output_line.length > 0) {
										  window.rx_data (output_line.data);
									  }
								  } else {
									  warning ("%s: Received capture for non-existent window %d.", name, window_id);
								  }
								  break;

							  case NextOutput.SESSION_ID:
								  var id = int.parse (output_line);
								  this.id = id;
								  break;

							  case NextOutput.WINDOWS:
								  message ("%s:%s: Received pane information. %s", name, session_name, output_line);
								  var info_parts = output_line.split (":");
								  if (info_parts.length > 3) {
									  var id = parse_window (info_parts[0]);
									  var width = int.parse (info_parts[1]);
									  var height = int.parse (info_parts[2]);
									  var title = compress_and_join (info_parts[3 : info_parts.length]);
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
								  } else {
									  critical ("Cannot parse list-windows output: %s.", output_line);
								  }
								  break;

							  case NextOutput.NONE:
								  break;

							  default:
								  if (output_line.length > 0) {
									  message ("%s:%s: Unsolicited output: %s", name, session_name, output_line);
								  }
								  break;
							 }
						 }
						 message ("%s:%s: Finished output block: %s", name, session_name, output_line);
						 if (output_line == null) {
							 message ("%s:%s: End of input reading data block from TMux.", name, session_name);
							 return "Connection unceremoniously terminated.";
						 }
						 break;

					 case "%exit":
						 message ("%s:%s: Explicit exit request from TMux.", name, session_name);
						 if (parts.length > 1) {
							 return compress_and_join (parts[2 : parts.length]);
						 } else {
							 return "TMux server shutdown.";
						 }

					 case "%sessions-changed":
					 case "%unlinked-window-add":
						 break;

					 case "%session-renamed":
						 if (id == parse_window (parts[1])) {

							 session_name = compress_and_join (parts[2 : parts.length]);
							 renamed ();
						 }
						 break;

					 case "%session-changed":
					 case "%window-add":
						 exec (@"list-windows -t $(Shell.quote(session_name)) -F \"#{window_id}:#{window_width}:#{window_height}:#{window_name}\"", NextOutput.WINDOWS);
						 break;

					 case "%window-close":
						 var window_id = parse_window (parts[1]);
						 if (windows.has_key (window_id)) {
							 windows[window_id].closed ();
							 windows.unset (window_id);
							 message ("%s:%s: Closing window %d.", name, session_name, window_id);
						 }
						 break;

					 case "%window-renamed":
						 var window_id = parse_window (parts[1]);
						 if (windows.has_key (window_id)) {
							 var window = windows[window_id];
							 window.title = compress_and_join (parts[2 : parts.length]);
							 window.renamed ();
							 message ("%s:%s: Renaming window %d.", name, session_name, window_id);
						 }
						 break;

					 case "%layout-change":
						 var window_id = parse_window (parts[1]);
						 if (windows.has_key (window_id)) {
							 var layout = parts[2].split (",");
							 var window = windows[window_id];
							 var coords = layout[1].split ("x");
							 window.set_size (int.parse (coords[0]), int.parse (coords[1]));
							 message ("%s:%s: Layout change on window %d.", name, session_name, window_id);
						 }
						 break;

					 case "%output":
						 var window_id = parse_window (parts[1]);
						 if (windows.has_key (window_id)) {
							 var window = windows[window_id];
							 var text = compress_and_join (parts[2 : parts.length]);
							 window.rx_data (text.data);
							 message ("%s:%s: Output for window %d.", name, session_name, window_id);
						 }
						 break;

					 default:
						 critical ("%s:%s: Unrecognised command from TMux: %s", name, session_name, str);
						 break;
					}
				} catch (Error e) {
					critical (e.message);
					return e.message;
				}
			}
		}

		protected abstract async string? read_line_async (Cancellable cancellable) throws Error;

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

		protected abstract void write (uint8[] data) throws IOError;
	}

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

		public signal void closed ();
		public signal void renamed ();
		public signal void rx_data (uint8[] data);
		public signal void size_changed (int old_width, int old_height);

		public void refresh () {
			try {
				stream.exec (@"capture-pane -p -e -q -J -t @$(id)", NextOutput.CAPTURE, id);
			} catch (IOError e) {
				critical (e.message);
			}
		}

		public void resize (int width, int height) {
			if (width == this.width && height == this.height) {
				return;
			}
			try {
				stream.exec (@"refresh-client -C $(width),$(height)");
			} catch (IOError e) {
				critical (e.message);
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

		public void tx_data (uint8[] text) {
			try {
				var command = new StringBuilder ();
				command.append_printf ("send-keys -t @%d", id);
				for (var it = 0; it < text.length; it++) {
					command.append_printf (" 0x%02x", text[it]);
				}
				stream.exec (command.str);
			} catch (IOError e) {
				critical (e.message);
			}
		}
	}

	private string compress_and_join (string[] parts) {
		if (parts.length == 0) {
			return "";
		}
		var buffer = new StringBuilder ();
		buffer.append (parts[0].compress ());
		for (var it = 1; it < parts.length; it++) {
			buffer.append_c (' ');
			buffer.append (parts[it].compress ());
		}
		return buffer.str;
	}

	private int parse_window (string str) {
		return int.parse (str[1 : str.length]);
	}
}
