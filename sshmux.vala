namespace SshMux {
	public class TMuxStream : Object {
		internal Cancellable cancellable;
		internal DataInputStream input;
		internal string name;
		internal Gee.HashMap<int, TerminalPage> sessions;
		internal OutputStream output;

		public string display_name { get { return name; } }

		public TMuxStream(string name, InputStream input_stream, OutputStream output_stream) {
			sessions = new Gee.HashMap<int, TerminalPage>();
			input = new DataInputStream(input_stream);
			output = output_stream;
			cancellable = new Cancellable();
			this.name = name;
		}
	}

	public class TerminalPage : Vte.Terminal {
		private unowned TMuxStream stream;
		internal Gtk.Label tab_label;
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
				warning(e.message);
			}
		}

		public override void commit(string text, uint size) {
			try {
				var encoded_text = Shell.quote(text);
				var command = @"send-keys -l -t %$(tmux_window) $(encoded_text)\n";
				warning(command);
				stream.output.write(command.data);
			} catch (IOError e) {
				warning(e.message);
			}
		}

		public string? get_link(long x, long y) {
			int tag;
			return match_check(x / get_char_width(), y / get_char_height(), out tag);
    }
	}

	public class TerminalGroup : Gtk.Notebook {
		private Gee.Set<TMuxStream> streams;

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
				warning(e.message);
			}
			return false;
		}
		//TODO open remote

		private async void read_line(TMuxStream stream) {
			while (true) {
				try {
					var str = yield stream.input.read_line_async(Priority.DEFAULT, stream.cancellable);
					if (str == null) {
						remove_stream(stream);
						return;
					}
					var parts = str.split(" ");
					warning(parts[0]);
					switch (parts[0]) {
						case "%session-renamed name":
						case "%sessions-changed":
						case "%unlinked-window-add":
							break;
						case "%exit":
							remove_stream(stream);
							return;
						case "%session-changed":
							var id = parse_window(parts[1]);
							stream.output.write(@"send-prefix -t %$(id)\nsend-keys -t %$(id) r\n".data);
							break;
						case "%window-add":
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
							page.set_size(long.parse(coords[0]), long.parse(coords[1]));
							page.queue_resize();
							break;
						case "%output":
							var id = parse_window(parts[1]);
							var page = get_or_create(stream, id);
							var text = compress_and_join(parts[2:parts.length]);
							page.feed(text.data);
							break;
						default:
							warning(str);
							break;
					}
				} catch (Error e) {
					warning(e.message);
				}
			}
		}

		private void remove_stream(TMuxStream stream) {
			foreach (var id in stream.sessions.keys) {
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

			try {
				set_icon_from_file("/usr/share/pixmaps/gnome-term.png");
			} catch(Error er) {
				warning(er.message);
			}
		}
		private static void main(string[] args) {
			Gtk.init(ref args);
			var window = new Window();
			window.show_all();
			Gtk.main();
		}
	}
}
