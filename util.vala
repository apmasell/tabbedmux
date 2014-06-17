namespace TabbedMux {
	public void show_error (Gtk.Window window, string message) {
		var dialog = new Gtk.MessageDialog (window, Gtk.DialogFlags.MODAL, Gtk.MessageType.ERROR, Gtk.ButtonsType.OK, "%s", message);
		dialog.run ();
		dialog.destroy ();
	}
}
