class TabbedMux.ContextMenu : Gtk.Menu {
	private string url;
	internal ContextMenu (string url) {
		unowned ContextMenu unowned_this = this;
		this.url = url;

		var open = new Gtk.MenuItem.with_label ("Open Link");
		append (open);
		open.activate.connect (unowned_this.open);

		var copy = new Gtk.MenuItem.with_label ("Copy Link Address");
		append (copy);
		copy.activate.connect (unowned_this.copy);

		show_all ();
	}
	private void open () {
		try {
			AppInfo.launch_default_for_uri (url, null);
		} catch (Error e) {
			var dialog = new Gtk.MessageDialog (get_toplevel () as Gtk.Window, Gtk.DialogFlags.MODAL, Gtk.MessageType.ERROR, Gtk.ButtonsType.OK, "%s", e.message);
			dialog.run ();
			dialog.destroy ();
		}
	}
	private void copy () {
		var display = get_display ();
		var clipboard = Gtk.Clipboard.get_for_display (display, Gdk.SELECTION_CLIPBOARD);
		clipboard.set_text (url, -1);
	}
}
