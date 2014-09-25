/**
 * Smart Gtk+ menus that know about the sessions they are associated with.
 */
public class TabbedMux.MenuItem : Gtk.MenuItem {
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
		set_label (@"$(stream.name) - $(stream.session_name)");
	}
}

/**
 * Smart menu item to create a new TMux window.
 */
public class TabbedMux.NewMenuItem : MenuItem {
	public NewMenuItem (TMuxStream stream) {
		base (stream);
	}

	public override void activate () {
		stream.create_window ();
	}
}

/**
 * Smart menu item to disconnect from a TMux session.
 */
public class TabbedMux.DisconnectMenuItem : MenuItem {
	public DisconnectMenuItem (TMuxStream stream) {
		base (stream);
	}

	public override void activate () {
		stream.cancel ();
	}
}

/**
 * The main window for holding the set of tabs.
 */
[GtkTemplate (ui = "/name/masella/tabbedmux/window.ui")]
public class TabbedMux.Window : Gtk.ApplicationWindow {
	[GtkChild]
	private Gtk.MenuItem copy_item;
	[GtkChild]
	private Gtk.Menu new_menu;
	[GtkChild]
	private Gtk.MenuItem new_session_item;
	[GtkChild]
	private Gtk.Notebook notebook;
	[GtkChild]
	private Gtk.Menu disconnect_menu;
	[GtkChild]
	private Gtk.MenuItem paste_item;
	[GtkChild]
	private Gtk.Menu saved_menu;
	[GtkChild]
	private Gtk.MenuItem saved_sessions_item;
	[GtkChild]
	private Gtk.Menu remove_saved_menu;
	[GtkChild]
	private Gtk.MenuItem remove_saved_item;
	[GtkChild]
	private Gtk.MenuItem rename_window_item;

	private Settings settings;
	private uint configure_id;
	private Gtk.Clipboard clipboard;

	internal Window (Application app) {
		Object (application: app, title: "TabbedMux", show_menubar: true, icon_name: "utilities-terminal");
		/* Allow receiving detailed resize information. */
		add_events (Gdk.EventMask.STRUCTURE_MASK | Gdk.EventMask.SUBSTRUCTURE_MASK);

		clipboard =  Gtk.Clipboard.get_for_display (get_display (), Gdk.SELECTION_PRIMARY);

		settings = new Settings (application.application_id);
		int width;
		int height;
		settings.get ("size", "(ii)", out width, out height);
		set_default_size (width, height);

		bool maximized;
		settings.get ("maximized", "b", out maximized);
		if (maximized) {
			maximize ();
		}

		int x;
		int y;
		settings.get ("position", "(ii)", out x, out y);
		move (x, y);

		var accel_group = new Gtk.AccelGroup ();
		add_accel_group (accel_group);
		copy_item.add_accelerator ("activate", accel_group, 'C', Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.SHIFT_MASK, Gtk.AccelFlags.VISIBLE);
		new_session_item.add_accelerator ("activate", accel_group, 'T', Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.SHIFT_MASK, Gtk.AccelFlags.VISIBLE);
		paste_item.add_accelerator ("activate", accel_group, 'V', Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.SHIFT_MASK, Gtk.AccelFlags.VISIBLE);
		rename_window_item.add_accelerator ("activate", accel_group, 'R', Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.SHIFT_MASK, Gtk.AccelFlags.VISIBLE);

		if (app is Application) {
			/* Make menus and tabs for the open streams. */
			foreach (var stream in ((Application) app).streams) {
				add_new_stream (stream);
			}
			/* Populate a menu for saved sessions. */
			var saved_sessions = ((Application) app).saved_sessions;
			saved_sessions.changed.connect (this.on_saved_changed);
			on_saved_changed (saved_sessions);

			unowned Window unowned_this = this;

			/* Notebook new window button. */
			var add = new Gtk.Button ();
			add.tooltip_text = "New terminal";
			add.relief = Gtk.ReliefStyle.NONE;
			add.add (new Gtk.Image.from_gicon (new ThemedIcon.with_default_fallbacks ("tab-new-symbolic"), Gtk.IconSize.MENU));
			add.show_all ();
			notebook.set_action_widget (add, Gtk.PackType.START);
			add.clicked.connect (unowned_this.create_session);

			/* Notebook close window button. */
			var close = new Gtk.Button ();
			close.tooltip_text = "Close terminal";
			close.relief = Gtk.ReliefStyle.NONE;
			close.add (new Gtk.Image.from_gicon (new ThemedIcon.with_default_fallbacks ("window-close-symbolic"), Gtk.IconSize.MENU));
			close.show_all ();
			notebook.set_action_widget (close, Gtk.PackType.END);
			close.clicked.connect (unowned_this.destroy_window);
		}
	}

	public override bool window_state_event (Gdk.EventWindowState event) {
		var result = base.window_state_event (event);
		settings.set_boolean ("maximized",  Gdk.WindowState.MAXIMIZED in get_window ().get_state ());

		return result;
	}

	/**
	 * Check if the TMux session is currently connected.
	 */
	private bool is_stream_active (SessionItem item) {
		if (!(application is Application)) {
			return false;
		}
		foreach (var stream in ((Application) application).streams) {
			if (item.matches (stream)) {
				return true;
			}
		}
		return false;
	}
	/**
	 * Repopulate the menu of saved sessions.
	 */
	private void on_saved_changed (SavedSessions sender) {
		var non_empty = false;
		foreach (var child in saved_menu.get_children ()) {
			saved_menu.remove (child);
		}
		foreach (var child in remove_saved_menu.get_children ()) {
			remove_saved_menu.remove (child);
		}
		sender.update ((session, binary) => {
				       var open_item = new LocalSessionItem (session, binary);
				       var remove_item = new RemoveLocalSessionItem (sender, session, binary);
				       open_item.sensitive = !is_stream_active (open_item);
				       saved_menu.add (open_item);
				       remove_saved_menu.add (remove_item);
				       non_empty = true;
			       }, (session, host, port, username, binary) => {
				       var open_item = new SshSessionItem (session, host, port, username, binary);
				       var remove_item = new RemoveSshSessionItem (sender, session, host, port, username, binary);
				       open_item.sensitive = !is_stream_active (open_item);
				       saved_menu.add (open_item);
				       remove_saved_menu.add (remove_item);
				       non_empty = true;
			       });
		saved_menu.show_all ();
		remove_saved_menu.show_all ();
		saved_sessions_item.sensitive = non_empty;
		remove_saved_item.sensitive = non_empty;
	}

	[GtkCallback]
	private void add_stream () {
		var open_dialog = new OpenDialog (this);
		while (open_dialog.run () == 0 && !open_dialog.success) {}
		open_dialog.destroy ();
	}

	/**
	 * Create all the menu items for a newly-connected TMux stream.
	 */
	internal void add_new_stream (TMuxStream stream) {
		var new_item = new NewMenuItem (stream);
		new_menu.append (new_item);
		var disconnect_item = new DisconnectMenuItem (stream);
		disconnect_menu.append (disconnect_item);
		unowned Window unowned_this = this;
		stream.connection_closed.connect (unowned_this.on_connection_closed);
		if (application is Application) {
			on_saved_changed (((Application) application).saved_sessions);
		}
	}

	/**
	 * Remove all matching smart menu items from a menu.
	 */
	private static void menu_remove (Gtk.Widget widget, Gtk.Menu parent, TMuxStream stream) {
		if (widget is MenuItem && ((MenuItem) widget).stream == stream) {
			parent.remove (widget);
		}
	}

	/**
	 * Clean up all the menu items for a dead TMux stream.
	 */
	internal void on_connection_closed (TMuxStream stream, string reason) {
		new_menu.@foreach ((widget) => menu_remove (widget, new_menu, stream));
		disconnect_menu.@foreach ((widget) => menu_remove (widget, disconnect_menu, stream));
		if (application is Application) {
			on_saved_changed (((Application) application).saved_sessions);
		}
	}

	/**
	 * Only have the Edit → Copy menu active if the selection is in the current tab.
	 */
	private void on_selection_changed (Vte.Terminal terminal) {
		if (((Terminal) notebook.get_nth_page (notebook.page)).terminal == terminal) {
			copy_item.sensitive = terminal.get_has_selection ();
		}
	}

	/**
	 * Make a tab for a new TMux window.
	 */
	internal void add_window (TMuxWindow window) {
		var terminal = new Terminal (window);
		unowned Window unowned_this = this;
		// TODO disconnect stream on close of last tab?
		window.closed.connect (unowned_this.on_tmux_window_closed);
		var id = notebook.append_page (terminal, terminal.tab_label);
		notebook.set_tab_reorderable (terminal, true);
		terminal.terminal.selection_changed.connect (unowned_this.on_selection_changed);
		message ("Adding window from %s.", window.stream.name);
		show_all ();
		notebook.set_current_page (id);
	}

	/**
	 * Create a “new” window.
	 *
	 * This will create one for the TMux stream of the current tab. If the current tab isn't helpful, show a dialog.
	 */
	[GtkCallback]
	private void create_session () {
		var widget = notebook.get_nth_page (notebook.page) as Terminal;
		if (widget != null) {
			((!)widget).tmux_window.stream.create_window ();
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

	/**
	 * Remove the current window.
	 */
	[GtkCallback]
	private void destroy_window () {
		var widget = notebook.get_nth_page (notebook.page) as Terminal;
		if (widget != null) {
			var window = ((!)widget).tmux_window;
			var dialog = new Gtk.MessageDialog (this, Gtk.DialogFlags.MODAL,  Gtk.MessageType.WARNING, Gtk.ButtonsType.YES_NO, "Kill TMux window “%s” and terminate running process?", window.title);
			if (dialog.run () == Gtk.ResponseType.YES) {
				window.destroy ();
			}
			dialog.destroy ();
		}
	}

	/**
	 * Kill the remote TMux server for the current window.
	 */
	[GtkCallback]
	private void destroy_server () {
		var widget = notebook.get_nth_page (notebook.page) as Terminal;
		if (widget != null) {
			var stream = ((!)widget).tmux_window.stream;
			var dialog = new Gtk.MessageDialog (this, Gtk.DialogFlags.MODAL,  Gtk.MessageType.WARNING, Gtk.ButtonsType.YES_NO, "Kill TMux server running on %s and terminate all running sessions and their windows and processes?", stream.name);
			if (dialog.run () == Gtk.ResponseType.YES) {
				stream.kill ();
			}
			dialog.destroy ();
		}
	}

	/**
	 * Kill the remote TMux session for the current window.
	 */
	[GtkCallback]
	private void destroy_session () {
		var widget = notebook.get_nth_page (notebook.page) as Terminal;
		if (widget != null) {
			var stream = ((!)widget).tmux_window.stream;
			var dialog = new Gtk.MessageDialog (this, Gtk.DialogFlags.MODAL,  Gtk.MessageType.WARNING, Gtk.ButtonsType.YES_NO, "Kill TMux server running session “%s” on %s and terminate all running windows and processes?", stream.session_name, stream.name);
			if (dialog.run () == Gtk.ResponseType.YES) {
				stream.destroy ();
			}
			dialog.destroy ();
		}
	}

	/**
	 * Rename the remote TMux session for the current window.
	 */
	[GtkCallback]
	private void rename_session () {
		var widget = notebook.get_nth_page (notebook.page) as Terminal;
		if (widget != null) {
			var stream = ((!)widget).tmux_window.stream;
			var dialog = new Gtk.MessageDialog (this, Gtk.DialogFlags.MODAL,  Gtk.MessageType.QUESTION, Gtk.ButtonsType.OK_CANCEL, "Rename session on “%s”:", stream.name);
			var entry = new Gtk.Entry ();
			entry.text = stream.session_name;
			entry.activates_default = true;
			dialog.get_content_area ().pack_end (entry);
			entry.show ();
			dialog.set_default_response (Gtk.ResponseType.OK);
			if (dialog.run () == Gtk.ResponseType.OK) {
				var name = strip (entry.text);
				if (name.length == 0 || ":" in name) {
					var error_dialog = new Gtk.MessageDialog (this, Gtk.DialogFlags.MODAL,  Gtk.MessageType.ERROR, Gtk.ButtonsType.OK, "Invalid session name.");
					error_dialog.run ();
					error_dialog.destroy ();
				} else {
					stream.rename (name);
				}
			}
			dialog.destroy ();
		}
	}

	/**
	 * Rename the remote TMux window.
	 */
	[GtkCallback]
	private void rename_window () {
		var widget = notebook.get_nth_page (notebook.page) as Terminal;
		if (widget != null) {
			var tmux_window = ((!)widget).tmux_window;
			var dialog = new Gtk.MessageDialog (this, Gtk.DialogFlags.MODAL,  Gtk.MessageType.QUESTION, Gtk.ButtonsType.OK_CANCEL, "Rename window on “%s”:", tmux_window.title);
			var entry = new Gtk.Entry ();
			entry.text = tmux_window.title;
			entry.activates_default = true;
			dialog.get_content_area ().pack_end (entry);
			entry.show ();
			dialog.set_default_response (Gtk.ResponseType.OK);
			if (dialog.run () == Gtk.ResponseType.OK) {
				var name = strip (entry.text);
				if (name.length == 0) {
					var error_dialog = new Gtk.MessageDialog (this, Gtk.DialogFlags.MODAL,  Gtk.MessageType.ERROR, Gtk.ButtonsType.OK, "Invalid window name.");
					error_dialog.run ();
					error_dialog.destroy ();
				} else {
					tmux_window.rename (name);
				}
			}
			dialog.destroy ();
		}
	}

	[GtkCallback]
	private void force_size_update () {
		var widget = notebook.get_nth_page (notebook.page) as Terminal;
		if (widget != null) {
			((!)widget).tmux_window.pull_size ();
		}
	}

	[GtkCallback]
	private void resize_tmux () {
		var widget = notebook.get_nth_page (notebook.page) as Terminal;
		if (widget != null) {
			((!)widget).resize_tmux ();
		}
	}

	[GtkCallback]
	private void zoom_in () {
		var widget = notebook.get_nth_page (notebook.page) as Terminal;
		if (widget != null) {
			((!)widget).adjust_font (true);
		}
	}

	[GtkCallback]
	private void zoom_out () {
		var widget = notebook.get_nth_page (notebook.page) as Terminal;
		if (widget != null) {
			((!)widget).adjust_font (false);
		}
	}

	[GtkCallback]
	private void zoom_normal () {
		var widget = notebook.get_nth_page (notebook.page) as Terminal;
		if (widget != null) {
			((!)widget).reset_font ();
		}
	}

	[GtkCallback]
	private void on_about () {
		Gtk.show_about_dialog (this,
				       "program-name", "TabbedMux",
				       "logo_icon_name", "utilities-terminal",
				       "copyright", "Copyright 2013-2014 Andre Masella",
				       "authors", new string[] { "Andre Masella" },
				       "website", "https://github.com/apmasell/tabbedmux",
				       "website-label", "GitHub Repository"
				       );
	}

	[GtkCallback]
	private void on_copy () {
		var widget = notebook.get_nth_page (notebook.page) as Terminal;
		if (widget != null) {
			((!)widget).terminal.copy_clipboard ();
		}
	}

	[GtkCallback]
	private void copy_to_tmux () {
		var widget = notebook.get_nth_page (notebook.page) as Terminal;
		if (widget != null) {
			var clipboard = Gtk.Clipboard.get_for_display (get_display (), Gdk.SELECTION_CLIPBOARD);
			((!)widget).tmux_window.stream.set_buffer (clipboard.wait_for_text ());
		}
	}

	[GtkCallback]
	private void on_paste () {
		var widget = notebook.get_nth_page (notebook.page) as Terminal;
		if (widget != null) {
			var tmux_window = ((!)widget).tmux_window;
			var text = clipboard.wait_for_text ();
			if (text != null) {
				tmux_window.paste_text ((!)text);
			}
		}
	}

	[GtkCallback]
	private void paste_tmux () {
		var widget = notebook.get_nth_page (notebook.page) as Terminal;
		if (widget != null) {
			((!)widget).tmux_window.paste_buffer ();
		}
	}

	[GtkCallback]
	private void on_quit () {
		destroy ();
	}

	private void on_tmux_window_closed (TMuxWindow tmux_window) {
		for (var it = 0; it < notebook.get_n_pages (); it++) {
			var terminal = notebook.get_nth_page (it) as Terminal;
			if (terminal != null && ((!)terminal).tmux_window == tmux_window) {
				notebook.remove_page (it);
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
			/* If we've switched to a terminal that doesn't know about the size of the window, force it to resize. */
			((!)terminal).resize_tmux ();
			copy_item.sensitive = ((!)terminal).terminal.get_has_selection ();
			var stream = ((!)terminal).tmux_window.stream;
			for (var it = 0; it < notebook.get_n_pages (); it++) {
				var other_terminal = notebook.get_nth_page (it) as Terminal;
				if (other_terminal != null) {
					((!)other_terminal).sibling_selected (((!)other_terminal).tmux_window.stream == stream);
				}
			}
		} else {
			message ("Non-terminal found in window.");
		}
	}

	/**
	 * Force redrawing the terminal on the remote end.
	 */
	[GtkCallback]
	private void refresh_tab () {
		var widget = notebook.get_nth_page (notebook.page) as Terminal;
		if (widget != null) {
			((!)widget).tmux_window.refresh ();
		}
	}

	/**
	 * When the container changes, resize the selected tab and mark that all the others are “the wrong size”.
	 */
	public override bool configure_event (Gdk.EventConfigure event) {
		var result = base.configure_event (event);
		if (configure_id != 0) {
			GLib.Source.remove (configure_id);
		}
		configure_id = Timeout.add (100, update_window_configuration);

		return result;
	}
	private bool update_window_configuration () {
		configure_id = 0;

		for (var it = 0; it < notebook.get_n_pages (); it++) {
			var terminal = notebook.get_nth_page (it) as Terminal;
			if (terminal != null) {
				((!)terminal).resize_tmux ();
			}
		}

		if (Gdk.WindowState.MAXIMIZED in get_window ().get_state ()) {
			return false;
		}
		int width;
		int height;
		get_size (out width, out height);
		settings.set ("size", "(ii)", width, height);

		int x;
		int y;
		get_position (out x, out y);
		settings.set ("position", "(ii)", x, y);
		return false;
	}
	public abstract class SessionItem : Gtk.MenuItem {
		protected abstract TMuxStream? open () throws Error;
		public abstract bool matches (TMuxStream stream);
		public override void activate () {
			var window = (Gtk.Window)get_toplevel ();
			while (window.attached_to != null) {
				window = (Gtk.Window)window.attached_to.get_toplevel ();
			}
			try {
				var stream = open ();
				if (stream == null) {
					show_error (window, "Could not connect.");
				} else {
					var application =  window.application as Application;
					if (application != null) {
						((!)application).add_stream ((!)stream);
					}
				}
			} catch (Error e) {
				show_error (window, e.message);
			}
		}
	}
	private class LocalSessionItem : SessionItem {
		private string session;
		private string binary;
		internal LocalSessionItem (string session, string binary) {
			this.session = session;
			this.binary = binary;
			label = "%s (Local: %s)".printf (session, binary);
		}
		public override bool matches (TMuxStream stream) {
			return stream is TMuxLocalStream && stream.session_name == session && stream.binary == binary;
		}
		protected override TMuxStream? open () throws Error {
			return TMuxLocalStream.open (session, binary);
		}
	}
	private class SshSessionItem : SessionItem {
		private string session;
		private string host;
		private uint16 port;
		private string username;
		private string binary;
		internal SshSessionItem (string session, string host, uint16 port, string username, string binary) {
			this.session = session;
			this.host = host;
			this.port = port;
			this.username = username;
			this.binary = binary;
			label = port == 22 ? "%s@%s - %s - %s".printf (username, host, binary, session) : "%s@%s:%hu - %s - %s".printf (username, host, port, binary, session);
		}
		public override bool matches (TMuxStream stream) {
			if (stream is TMuxSshStream && stream.session_name == session) {
				var ssh_stream = (TMuxSshStream) stream;
				return ssh_stream.host == host && ssh_stream.port == port && ssh_stream.username == username && ssh_stream.binary == binary;
			}
			return false;
		}
		protected override TMuxStream? open () throws Error {
			var keybd_dialog = new KeyboardInteractiveDialog ((Gtk.Window)get_toplevel (), host);
			return TMuxSshStream.open (session, host, port, username, binary, keybd_dialog.respond);
		}
	}
	public abstract class RemoveSessionItem : Gtk.MenuItem {
		protected abstract void remove_session ();
		public override void activate () {
			var window = (Gtk.Window)get_toplevel ();
			while (window.attached_to != null) {
				window = (Gtk.Window)window.attached_to.get_toplevel ();
			}
			var dialog = new Gtk.MessageDialog (window, Gtk.DialogFlags.MODAL,  Gtk.MessageType.WARNING, Gtk.ButtonsType.YES_NO, "Remove session “%s”?", label);
			if (dialog.run () == Gtk.ResponseType.YES) {
				remove_session ();
			}
			dialog.destroy ();
		}
	}
	private class RemoveLocalSessionItem : RemoveSessionItem {
		private SavedSessions saved;
		private string session;
		private string binary;
		internal RemoveLocalSessionItem (SavedSessions saved, string session, string binary) {
			this.saved = saved;
			this.session = session;
			this.binary = binary;
			label = "%s (Local: %s)".printf (session, binary);
		}
		protected override void remove_session () {
			saved.remove_local (session, binary);
		}
	}       private class RemoveSshSessionItem : RemoveSessionItem {
		private SavedSessions saved;
		private string session;
		private string host;
		private uint16 port;
		private string username;
		private string binary;
		internal RemoveSshSessionItem (SavedSessions saved, string session, string host, uint16 port, string username, string binary) {
			this.saved = saved;
			this.session = session;
			this.host = host;
			this.port = port;
			this.username = username;
			this.binary = binary;
			label = port == 22 ? "%s@%s - %s - %s".printf (username, host, binary, session) : "%s@%s:%hu - %s - %s".printf (username, host, port, binary, session);
		}
		protected override void remove_session () {
			saved.remove_ssh (session, host, port, username, binary);
		}
	}
}
