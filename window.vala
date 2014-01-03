public class SshMux.MenuItem : Gtk.MenuItem {
	public TMuxStream stream {
		get; private set;
	}
	public MenuItem (TMuxStream stream) {
		Object ();
		this.stream = stream;
		unowned MenuItem unowned_this = this;
		stream.connection_closed.connect (unowned_this.on_rename);
		on_rename ();
	}

	private void on_rename () {
		set_label (@"$(stream.session_name) - $(stream.name)");
	}
}
public class SshMux.NewMenuItem : MenuItem {
	public NewMenuItem (TMuxStream stream) {
		base (stream);
	}

	public override void activate () {
		stream.create_window ();
	}
}

public class SshMux.DisconnectMenuItem : MenuItem {
	public DisconnectMenuItem (TMuxStream stream) {
		base (stream);
	}

	public override void activate () {
		stream.cancel ();
	}
}
[GtkTemplate (ui = "/name/masella/sshmux/window.ui")]
public class SshMux.Window : Gtk.ApplicationWindow {
	[GtkChild]
	private Gtk.MenuItem copy_item;
	[GtkChild]
	private Gtk.Menu new_menu;
	[GtkChild]
	private Gtk.Notebook notebook;
	[GtkChild]
	private Gtk.Menu disconnect_menu;

	private Gee.Set<Terminal> unsized_children = new Gee.HashSet<Terminal> ();

	internal Window (Application app) {
		Object (application: app, title: "SSHMux", show_menubar: true);
		add_events (Gdk.EventMask.STRUCTURE_MASK | Gdk.EventMask.SUBSTRUCTURE_MASK);
		this.set_default_size (600, 400);
		if (app is Application) {
			foreach (var stream in ((Application) app).streams) {
				add_new_stream (stream);
			}
		}
	}

	[GtkCallback]
	private void add_stream () {
		var open_dialog = new OpenDialog (this);
		open_dialog.show ();
	}

	internal void add_new_stream (TMuxStream stream) {
		var new_item = new NewMenuItem (stream);
		new_menu.append (new_item);
		var disconnect_item = new DisconnectMenuItem (stream);
		disconnect_menu.append (disconnect_item);
		unowned Window unowned_this = this;
		stream.connection_closed.connect (unowned_this.on_connection_closed);
	}

	private static void menu_remove (Gtk.Widget widget, Gtk.Menu parent, TMuxStream stream) {
		if (widget is MenuItem && ((MenuItem) widget).stream == stream) {
			parent.remove (widget);
		}
	}

	internal void on_connection_closed (TMuxStream stream, string reason) {
		new_menu.@foreach ((widget) => menu_remove (widget, new_menu, stream));
		disconnect_menu.@foreach ((widget) => menu_remove (widget, disconnect_menu, stream));
	}

	private void on_selection_changed (Vte.Terminal terminal) {
		if (notebook.get_nth_page (notebook.page) == terminal) {
			copy_item.sensitive = terminal.get_has_selection ();
		}
	}

	internal void add_window (TMuxWindow window) {
		var terminal = new Terminal (window);
		unowned Window unowned_this = this;
		// TODO disconnect on close
		window.closed.connect (unowned_this.on_tmux_window_closed);
		terminal.selection_changed.connect (unowned_this.on_selection_changed);
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
				var dialog = new Gtk.MessageDialog (this, Gtk.DialogFlags.MODAL,  Gtk.MessageType.WARNING, Gtk.ButtonsType.OK, "Multiple TMux instances are currently connected.");
				dialog.run ();
				dialog.destroy ();
			} else {
				add_stream ();
			}
		}
	}
	[GtkCallback]
	private void on_about () {
		Gtk.show_about_dialog (this,
				       "program-name", "SshMux",
				       "copyright", "Copyright 2013-2014 Andre Masella",
				       "authors", new string[] { "Andre Masella" },
				       "website", "https://github.com/apmasell/sshmux",
				       "website-label", "GitHub Repository"
				       );
	}
	[GtkCallback]
	private void on_copy () {
		var widget = notebook.get_nth_page (notebook.page) as Terminal;
		if (widget != null) {
			widget.copy_primary ();
		}
	}

	[GtkCallback]
	private void on_paste () {
		var widget = notebook.get_nth_page (notebook.page) as Terminal;
		if (widget != null) {
			widget.paste_primary ();
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
			copy_item.sensitive = terminal.get_has_selection ();
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
