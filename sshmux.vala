namespace SshMux {
	public const string TERM_TYPE = "xterm";

	private enum NextOutput {
		NONE,
		CAPTURE,
		PANES
	}

	private class OutputTodo {
		internal NextOutput action;
		internal int id;
	}

	public class TMuxStream : Object {
		internal Cancellable cancellable = new Cancellable();
		private DataInputStream input;
		private OutputStream output;
		internal Gee.HashMap<int, TerminalPage> sessions = new Gee.HashMap<int, TerminalPage>();
		internal Gee.HashMap<int, OutputTodo> outputs = new Gee.HashMap<int, OutputTodo>();
		private int output_num = 1;

		public string name { get; private set; }
		public string session_name { get; internal set; }

		public TMuxStream(string name, InputStream input_stream, OutputStream output_stream) {
			input = new DataInputStream(input_stream);
			output = output_stream;
			this.name = name;
			session_name = "unknown";
		}

		public signal void renamed();

		internal void exec(string command, NextOutput output_type = NextOutput.NONE, int window_id = 0) throws IOError {
			var command_id = ++output_num;
			message("Sending command %d: %s", command_id, command);
			output.write(command.data);
			output.write(new uint8[] { '\n' });
			var todo = new OutputTodo();
			todo.action = output_type;
			todo.id = window_id;
			outputs[command_id] = todo;
		}
		internal async string? get_line() throws IOError {
			return yield input.read_line_async(Priority.DEFAULT, cancellable);
		}
	}

	public class TerminalPage : Vte.Terminal {
		private unowned TMuxStream stream;
		internal Gtk.Label tab_label;
		internal int term_width;
		internal int term_height;
		private int tmux_window;

		public string tmux_title {
			get { return tab_label.label; }
			internal set { tab_label.label = value; }
		}

		internal TerminalPage(TMuxStream stream, int tmux_window) {
			tab_label = new Gtk.Label("New Session");
			this.tmux_window = tmux_window;
			this.stream = stream;
			this.emulation = TERM_TYPE;
			this.pointer_autohide = true;
			try {
				var regex = new GLib.Regex("(https?|ftps?|magnet:)://\\S+");
				int id = this.match_add_gregex(regex, 0);

				match_set_cursor_type(id, Gdk.CursorType.HAND2);
			} catch(RegexError e) {
				critical(e.message);
			}
			stream.renamed.connect(on_rename);
			on_rename();
		}
		internal void on_rename() {
			tab_label.set_tooltip_text(@"$(stream.name) - $(stream.session_name)");
		}
		internal void update_size() {
			set_size(term_width, term_height);
			set_size_request((int)((term_width + 1) * get_char_width()), (int)((term_height + 1) * get_char_height()));
			queue_resize();
		}

		internal void force_resize() {
			warning("force resize");
			var height = int.max(10, (int)(get_allocated_height() / get_char_height()));
			var width = int.max(10, (int)(get_allocated_width() / get_char_width()));
			if (height != term_height) {
				try {
					stream.exec(@"resize-pane -$(term_height < height ? "D" : "U") -t %$(tmux_window) $((term_height - height).abs())", NextOutput.PANES);
				} catch (IOError e) {
					warning(e.message);
				}
				term_width = width;
			}
			if (width != term_width) {
				warning("changed resize");
				try {
					stream.exec(@"resize-pane -$(term_width < width ? "R" : "L") -t %$(tmux_window) $((term_width - width).abs())", NextOutput.PANES);
				} catch (IOError e) {
					warning(e.message);
				}
				term_width = width;
			}
		}

		public override void commit(string text, uint size) {
			try {
				var command = new StringBuilder();
				command.append_printf("send-keys -t %%%d", tmux_window);
				for (var it = 0; it < text.length; it++) {
					command.append_printf(" 0x%02x", text[it]);
				}
				stream.exec(command.str);
			} catch (IOError e) {
				critical(e.message);
			}
		}

		public string? get_link(long x, long y) {
			int tag;
			return match_check(x / get_char_width(), y / get_char_height(), out tag);
    }
	}

	public class TerminalGroup : Gtk.Notebook {
		private Gee.Set<TMuxStream> streams;
		private Gee.Map<string, StreamOpener> openers = new Gee.HashMap<string, StreamOpener>();
		private Regex pane_list_pattern = /^ *(\d+): \[(\d+)x(\d+)\].*/;

		public Gee.Set<TMuxStream> tmux_streams { owned get { return streams.read_only_view; } }

		public TerminalGroup() {
			streams = new Gee.HashSet<TMuxStream>();
			resize_mode = Gtk.ResizeMode.PARENT;
			this.page_removed.connect((tg, child, id) => { if (tg.get_n_pages() == 0) ((TerminalGroup)tg).no_more_children(); });
			openers["local"] = open_local;
		}

		~TerminalGroup() {
			foreach (var stream in streams) {
				stream.cancellable.cancel();
			}
		}

		public signal void no_more_children();

		public signal void stream_added(TMuxStream stream);
		public signal void stream_removed(TMuxStream stream);

		public void add_window(TMuxStream stream) {
			if (!(stream in streams)) {
				return;
			}
			try {
				stream.exec("new-window");
			} catch (IOError e) {
				critical("Failed to create window: %s", e.message);
			}
		}

		public override void check_resize() {
			warning ("check_resize_tabl");
			var pane = get_nth_page(page) as TerminalPage;
			if (pane != null) {
				pane.update_size();
			}
		}

		public void resize() {
			warning ("force resize");
			var pane = get_nth_page(page) as TerminalPage;
			if (pane != null) {
				pane.force_resize();
			}
		}

		public override bool change_current_page(int offset) {
			var pane = get_nth_page(page) as TerminalPage;
			if (pane != null) {
				pane.force_resize();
			}
			return true;
		}

		private TerminalPage create_terminal(TMuxStream stream, int id) {
			var pane = new TerminalPage(stream, id);
			append_page(pane, pane.tab_label);
			stream.sessions[id] = pane;
			set_tab_reorderable(pane, true);
			show_all();
			warning("create window");
			return pane;
		}

		private void destroy_terminal(TMuxStream stream, int id) {
			var pane = stream.sessions[id];
			if (pane == null)
				return;
			var num = page_num(pane);
			if (num < 0)
				return;
			stream.sessions.unset(id);
			stream.renamed.disconnect(pane.on_rename);
			remove_page(num);
		}

		private TerminalPage get_or_create(TMuxStream stream, int id) {
			var pane = stream.sessions[id];
			return (pane == null) ? create_terminal(stream, id) : pane;
		}

		public bool open(string uri) throws Error {
			var scheme = Uri.parse_scheme(uri);
			if (scheme == null || !openers.has_key(scheme))
				return false;
			var handler = openers[scheme];
			var stream = handler(uri);
			if (stream == null)
				return false;

			streams.add(stream);
			stream_added(stream);
			read_line.begin(stream, (obj, result) => { this.read_line.end(result); });
			return true;
		}

		private async void read_line(TMuxStream stream) {
			while (true) {
				try {
					var str = yield stream.get_line();
					if (str == null) {
						warning("no more - main");
						remove_stream(stream);
						return;
					}
					var parts = str.split(" ");
					warning("processing: %s", parts[0]);
					switch (parts[0]) {
						case "%sessions-changed":
							stream.exec(@"list-panes", NextOutput.PANES);
							break;
						case "%begin":
							var output_num = int.parse(parts[2]);
							NextOutput action = NextOutput.NONE;
							int window_id = 0;
							if (stream.outputs.has_key(output_num)) {
								var todo = stream.outputs[output_num];
								stream.outputs.unset(output_num);
								action = todo.action;
								window_id = todo.id;
							}
							string? output_line;
							while((output_line = yield stream.get_line()) !=  null && !(output_line.has_prefix("%end") || output_line.has_prefix("%error"))) {
warning("output: %s", output_line);
								switch (action) {
									case NextOutput.CAPTURE:
										var pane = get_or_create(stream, window_id);
							warning("capture %d", window_id);
										pane.feed(output_line.data);
										pane.queue_draw();
										break;
									case NextOutput.PANES:
										MatchInfo match_info;
							warning("matching pane");
										if (pane_list_pattern.match(output_line, 0, out match_info)) {
											var id = int.parse(match_info.fetch(1));
											var width = int.parse(match_info.fetch(2));
											var height = int.parse(match_info.fetch(3));
											var pane = get_or_create(stream, id);
											warning("got %d %d for %d", width, height, id);
											pane.term_width = width;
											pane.term_height = height;
											pane.update_size();
										} else {
											critical("Cannot parse list-panes output: %s", output_line);
										}
										break;
									case NextOutput.NONE:
										break;
									default:
										if (output_line.length > 0)
											message("Unsolicited output: %s", output_line);
										break;
								}
							}
warning("done: %s", output_line);
							if (output_line == null) {
								warning("no more - subordinate");
								remove_stream(stream);
								return;
							}
							break;
						case "%exit":
								warning("no more - exit");
							remove_stream(stream);
							return;
						case "%session-changed":
							var id = parse_window(parts[1]);
							stream.session_name = parts[3];
							stream.exec(@"list-panes -t %$(id)", NextOutput.PANES);
							stream.exec(@"capture-pane -p -e -q -J -t %$(id)", NextOutput.CAPTURE, id);
							break;
						case "%session-renamed":
							stream.session_name = parts[1];
							stream.renamed();
							break;
						case "%window-add":
						case "%unlinked-window-add":
							var id = parse_window(parts[1]);
							create_terminal(stream, id);
							break;
						case "%window-close":
							var id = parse_window(parts[1]);
							destroy_terminal(stream, id);
							break;
						case "%window-renamed":
							var id = parse_window(parts[1]);
							var pane = get_or_create(stream, id);
							pane.tmux_title = compress_and_join(parts[2:parts.length]);
							break;
						case "%layout-change":
							var id = parse_window(parts[1]);
							var layout = parts[2].split(",");
							var pane = get_or_create(stream, id);
							var coords = layout[1].split("x");
							pane.term_width = int.parse(coords[0]);
							pane.term_height = int.parse(coords[1]);
							if (pane == get_nth_page(page))
								pane.update_size();
							break;
						case "%output":
							var id = parse_window(parts[1]);
							var pane = get_or_create(stream, id);
							var text = compress_and_join(parts[2:parts.length]);
							pane.feed(text.data);
							break;
						default:
							critical("Unrecognised command from tmux: %s", str);
							break;
					}
				} catch (Error e) {
					critical(e.message);
				}
			}
		}

		public void register_stream(string uri_scheme, StreamOpener opener) {
			openers[uri_scheme] = opener;
		}

		private void remove_stream(TMuxStream stream) {
			// Duplicate to prevent concurrent modification.
			var keys = new Gee.HashSet<int>();
			keys.add_all(stream.sessions.keys);
			foreach (var id in keys) {
				destroy_terminal(stream, id);
			}
			this.streams.remove(stream);
			stream_removed(stream);
		}
	}

	private string compress_and_join(string[] parts) {
		if (parts.length == 0)
			return "";
		var buffer = new StringBuilder();
		buffer.append(parts[0].compress());
		for (var it = 1; it < parts.length; it++) {
			buffer.append_c(' ');
			buffer.append(parts[it].compress());
		}
		return buffer.str;
	}

	public TMuxStream? open_local(string uri) throws Error {
		var session = Uri.unescape_string(uri[uri.index_of(":") + 1 : uri.length]);
		int exit_status;
		string[] command;
		if (Process.spawn_sync(null, new string[] { "tmux", "has-session", "-t", session }, null, SpawnFlags.SEARCH_PATH, null, null, null, out exit_status)) {
			if (exit_status == 0) {
				command = new string[] { "tmux", "-C", "attach", "-d", "-t", session };
			} else {
				command = new string[] { "tmux", "-C", "new", "-AD", "-t", session };
			}
			warning(command[2]);
		} else {
			return null;
		}
		Pid child_pid;
		int standard_input;
		int standard_output;
		if (Process.spawn_async_with_pipes(null, command, new string[] { "TERM", TERM_TYPE }, SpawnFlags.SEARCH_PATH, null, out child_pid, out standard_input, out standard_output)) {
			var input = new UnixInputStream(standard_output, true);
			var output = new UnixOutputStream(standard_input, true);
			return new TMuxStream(Environment.get_host_name(), input, output);
		}
		return null;
	}
	//TODO open remote

	private int parse_window(string str) {
		return int.parse(str[1:str.length]);
	}

	public class Window : Gtk.ApplicationWindow {
		private TerminalGroup terminals;
		private bool resize_in_progress;

		internal Window(Application app) {
			Object(application: app, title: "SSHMux", show_menubar: true);
			this.set_default_size(600, 400);

			terminals = new TerminalGroup();
			add(terminals);
			terminals.no_more_children.connect(() => { Gtk.main_quit(); });
			try {
				terminals.open("local:");
			} catch (Error e) {
				critical("Failed to open local tmux: %s", e.message);
			}
			configure_event.connect((event) => {
				warning("conifgure %s", resize_in_progress.to_string());
				if (event.type == Gdk.EventType.CONFIGURE && !resize_in_progress) {
					resize_in_progress = true;
					terminals.resize();
					resize_in_progress = false;
				}
				return false;
			});
		}
	}
public class Application : Gtk.Application {
	protected override void activate () {
		new Window (this).show_all ();
	}

	internal Application () {
		Object (application_id: "name.masella.SSHMux");
	}

	protected override void startup() {
		base.startup ();

		var builder = new Gtk.Builder();
		builder.add_from_resource("/name/masella/sshmux/menu.ui");
		app_menu = builder.get_object("app-menu") as Menu;
		menubar = builder.get_object("win-menu") as Menu;

		var new_action = new SimpleAction ("new", null);
		new_action.activate.connect (this.new_cb);
		this.add_action (new_action);

		var quit_action = new SimpleAction ("quit", null);
		quit_action.activate.connect (this.quit);
		this.add_action (quit_action);
	}

	void new_cb (SimpleAction simple, Variant? parameter) {
		print ("You clicked \"New\"\n");
	}
}
	[CCode(has_target = false)]
	public delegate TMuxStream? StreamOpener(string uri) throws Error;
	public int main (string[] args) {
		return new Application ().run (args);
	}
}
