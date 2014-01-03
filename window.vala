[GtkTemplate (ui = "/name/masella/sshmux/window.ui")]
public class SshMux.Window : Gtk.ApplicationWindow {
	[GtkChild]
	private Gtk.Notebook notebook;

	private Gee.Set<Terminal> unsized_children = new Gee.HashSet<Terminal> ();

	internal Window (Application app) {
		Object (application: app, title: "SSHMux", show_menubar: true);
		add_events (Gdk.EventMask.STRUCTURE_MASK | Gdk.EventMask.SUBSTRUCTURE_MASK);
		this.set_default_size (600, 400);
	}

	[GtkCallback]
	private void add_stream () {
		var open_dialog = new OpenDialog (this);
		open_dialog.show ();
	}
	internal void add_window (TMuxWindow window) {
		var terminal = new Terminal (window);
		unowned Window unowned_this = this;
		// TODO disconnect on close
		window.closed.connect (unowned_this.on_tmux_window_closed);
		notebook.append_page (terminal, terminal.tab_label);
		notebook.set_tab_reorderable (terminal, true);
		message ("Adding window from %s.", window.stream.name);
		show_all ();
	}
	[GtkCallback]
	private void create_session () {
		var widget = notebook.get_nth_page (notebook.page) as Terminal;
		if (widget != null) {
			widget.tmux_window.stream.create_window ();
		} else if (application is Application) {
			var streams = ((Application) application).streams;
			if (streams.size == 1) {
				foreach (var stream in streams) {
					stream.create_window ();
				}
			} else if (streams.size > 1) {
				//TODO show dialog
			} else {
				var dialog = new Gtk.MessageDialog (this, Gtk.DialogFlags.MODAL,  Gtk.MessageType.WARNING, Gtk.ButtonsType.OK, "No TMux instances are currently connected.");
				dialog.run ();
				dialog.destroy ();
			}
		}
	}
	[GtkCallback]
	private void on_quit () {
		destroy ();
	}
	private void on_tmux_window_closed (TMuxWindow tmux_window) {
		for (var it = 0; it < notebook.get_n_pages (); it++) {
			var terminal = notebook.get_nth_page (it) as Terminal;
			if (terminal != null && terminal.tmux_window == tmux_window) {
				notebook.remove_page (it);
				unsized_children.remove (terminal);
				return;
			}
		}
	}
	[GtkCallback]
	private void page_removed () {
		if (notebook.get_n_pages () == 0) {
			close ();
		}
	}
	[GtkCallback]
	private void page_switched (Gtk.Widget widget, uint index) {
		var terminal = widget as Terminal;
		if (terminal != null) {
			message ("Switched terminal.");
			if (terminal in unsized_children) {
				terminal.resize_tmux ();
				unsized_children.remove (terminal);
			}
		} else {
			message ("Non-terminal found in window.");
		}
	}
	[GtkCallback]
	private void refresh_tab () {
		var widget = notebook.get_nth_page (notebook.page) as Terminal;
		if (widget != null) {
			widget.tmux_window.refresh ();
		}
	}
	internal void update_tab_names () {
		for (var it = 0; it < notebook.get_n_pages (); it++) {
			var terminal = notebook.get_nth_page (it) as Terminal;
			if (terminal != null) {
				terminal.update_tab_label ();
			}
		}
	}
	public override bool configure_event (Gdk.EventConfigure event) {
		var result = base.configure_event (event);
		if (event.type == Gdk.EventType.CONFIGURE) {
			for (var it = 0; it < notebook.get_n_pages (); it++) {
				var terminal = notebook.get_nth_page (it) as Terminal;
				if (terminal != null) {
					if (it == notebook.page) {
						terminal.resize_tmux ();
						unsized_children.remove (terminal);
					} else {
						unsized_children.add (terminal);
					}
				}
			}
		}
		return result;
	}
}
