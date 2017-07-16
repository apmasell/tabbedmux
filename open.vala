/**
 * Create an open new session dialog
 */
[GtkTemplate (ui = "/name/masella/tabbedmux/open.ui")]
public class TabbedMux.OpenDialog : Gtk.Dialog {

	public BusyDialog (Gtk.Window parent) {
		Object (application : parent.application, transient_for: parent);
		cancellable = new Cancellable ();
	}
	[GtkCallback]
	private void on_cancel () {
		cancellable.cancel ();
	}
}
