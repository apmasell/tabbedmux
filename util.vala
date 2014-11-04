namespace TabbedMux {
	public extern string strip (string input);

	/**
	 * Show a GTK message box for the provided string.
	 */
	public void show_error (Gtk.Window window, string message) {
		var dialog = new Gtk.MessageDialog (window, Gtk.DialogFlags.MODAL, Gtk.MessageType.ERROR, Gtk.ButtonsType.OK, "%s", message);
		dialog.title = "TabbedMux";
		unowned Gtk.Widget unowned_this = dialog;
		dialog.response.connect (() => unowned_this.destroy ());
		dialog.show ();
	}
}
