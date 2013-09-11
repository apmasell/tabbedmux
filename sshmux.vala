namespace SshMux {

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

		public TMuxStream(string name, InputStream input_stream, OutputStream output_stream) {
			input = new DataInputStream(input_stream);
			output = output_stream;
			this.name = name;
		}

		internal void exec(string command, NextOutput output_type = NextOutput.NONE, int window_id = 0) throws IOError {
			var command_id = ++output_num;
			message("sending command %d: %s", command_id, command);
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
			this.emulation = "xterm";
			try {
				var regex = new GLib.Regex("(https?|ftps?|magnet:)://\\S+");
				int id = this.match_add_gregex(regex, 0);

				match_set_cursor_type(id, Gdk.CursorType.HAND2);
			} catch(RegexError e) {
				critical(e.message);
			}
		}

		public void check_resize(bool gui_overrides) {
			warning("check_resize");
			var height = int.max(10, (int)(get_allocated_height() / get_char_height()));
			var width = int.max(10, (int)(get_allocated_width() / get_char_width()));
			if (height != term_height || width != term_width) {
				warning("term mismatch was %dx%d, have space for %dx%d", term_width, term_height, width, height);
				if (gui_overrides) {
					term_height = height;
					term_width = width;
					try {
						stream.exec("resize-pane -T %$(tmux_window) -x $(term_width) -y $(term_height)");
					} catch (IOError e) {
						warning(e.message);
					}
				}
				set_size(term_width, term_height);
				set_size_request((int)((term_width + 1) * get_char_width()), (int)((term_height + 1) * get_char_height()));
				queue_resize();
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

		private Regex pane_list_pattern = /^ *(\d+): \[(\d+)x(\d+)\].*/;

		public Gee.Set<TMuxStream> tmux_streams { owned get { return streams.read_only_view; } }

		public TerminalGroup() {
			streams = new Gee.HashSet<TMuxStream>();
			resize_mode = Gtk.ResizeMode.PARENT;
			this.page_removed.connect((tg, child, id) => { if (tg.get_n_pages() == 0) ((TerminalGroup)tg).no_more_children(); });
		}

		~TerminalGroup() {
			foreach (var stream in streams) {
				stream.cancellable.cancel();
			}
		}

		public signal void no_more_children();

		private void add_stream(string name, InputStream input, OutputStream output) {
			var stream = new TMuxStream(name, input, output);
			streams.add(stream);
			this.read_line.begin(stream, (obj, result) => { this.read_line.end(result); });
		}

		public override void check_resize() {
			warning ("check_resize_tabl");
			var page = get_nth_page(page) as TerminalPage;
			if (page != null)
				page.check_resize(true);
		}

		public override bool change_current_page(int offset) {
			var page = get_nth_page(page) as TerminalPage;
			if (page != null)
				page.check_resize(true);
			return true;
		}

		private TerminalPage create_terminal(TMuxStream stream, int id) {
			var page = new TerminalPage(stream, id);
			append_page(page, page.tab_label);
			stream.sessions[id] = page;
			show_all();
			warning("create window");
			return page;
		}

		private void destroy_terminal(TMuxStream stream, int id) {
			var page = stream.sessions[id];
			if (page == null)
				return;
			var num = page_num(page);
			if (num < 0)
				return;
			stream.sessions.unset(id);
			remove_page(num);
		}

		private TerminalPage get_or_create(TMuxStream stream, int id) {
			var page = stream.sessions[id];
			return (page == null) ? create_terminal(stream, id) : page;
		}

		public bool open_local() {
			try {
				int exit_status;
				string[] command;
				if (Process.spawn_sync(null, new string[] {"tmux", "has-session"}, null, SpawnFlags.SEARCH_PATH, null, null, null, out exit_status)) {
					if (exit_status == 0) {
						command = new string[] { "tmux", "-C", "attach", "-d" };
					} else {
						command = new string[] { "tmux", "-C", "new", "-AD" };
					}
				} else {
					return false;
				}
				Pid child_pid;
				int standard_input;
				int standard_output;
				if (Process.spawn_async_with_pipes(null, command, null, SpawnFlags.SEARCH_PATH, null, out child_pid, out standard_input, out standard_output)) {
					var input = new UnixInputStream(standard_output, true);
					var output = new UnixOutputStream(standard_input, true);
					add_stream(@"$(Environment.get_host_name()) (Local)", input, output);
					return true;
				}
				return false;
			} catch (SpawnError e) {
				critical(e.message);
			}
			return false;
		}
		//TODO open remote

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
						case "%session-renamed":
							break;
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
											pane.check_resize(false);
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
							stream.exec(@"list-panes -t %$(id)", NextOutput.PANES);
							stream.exec(@"capture-pane -p -e -q -J -t %$(id)", NextOutput.CAPTURE, id);
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
							var page = get_or_create(stream, id);
							page.tmux_title = compress_and_join(parts[2:parts.length]);
							break;
						case "%layout-change":
							var id = parse_window(parts[1]);
							var layout = parts[2].split(",");
							var page = get_or_create(stream, id);
							var coords = layout[1].split("x");
							page.term_width = int.parse(coords[0]);
							page.term_height = int.parse(coords[1]);
							page.check_resize(false);
							break;
						case "%output":
							var id = parse_window(parts[1]);
							var page = get_or_create(stream, id);
							var text = compress_and_join(parts[2:parts.length]);
							page.feed(text.data);
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

		private void remove_stream(TMuxStream stream) {
			// Duplicate to prevent concurrent modification.
			var keys = new Gee.HashSet<int>();
			keys.add_all(stream.sessions.keys);
			foreach (var id in keys) {
				destroy_terminal(stream, id);
			}
			this.streams.remove(stream);
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

	private int parse_window(string str) {
		return int.parse(str[1:str.length]);
	}

	public class Window : Gtk.Window {
		private TerminalGroup terminals;
		public Window() {
			terminals = new TerminalGroup();
			add(terminals);
			terminals.no_more_children.connect(() => { Gtk.main_quit(); });
			terminals.open_local();
		}
		private static void main(string[] args) {
			Gtk.init(ref args);
			var window = new Window();
			window.show_all();
			Gtk.main();
		}
	}
}
