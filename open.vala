[GtkTemplate (ui = "/name/masella/sshmux/open.ui")]
public class SshMux.OpenDialog : Gtk.Window {
	[GtkChild]
	private Gtk.RadioButton remote_connection;
	[GtkChild]
	private Gtk.Entry user;
	[GtkChild]
	private Gtk.Entry host;
	[GtkChild]
	private Gtk.Entry port;
	[GtkChild]
	private Gtk.Entry session;

	internal OpenDialog (Window parent) {
		Object (application: parent.application);
		transient_for = parent;
	}

	[GtkCallback]
	private void on_cancel () {
		destroy ();
	}

	private void show_error (string message) {
		var dialog = new Gtk.MessageDialog (this, Gtk.DialogFlags.MODAL,  Gtk.MessageType.ERROR, Gtk.ButtonsType.OK, message);
		dialog.run ();
		dialog.destroy ();
	}

	[GtkCallback]
	private void on_connect () {
		try {
			TMuxStream stream;
			string session_name = session.text;
			if (":" in session_name) {
				show_error ("Session names may not contain colons.");
				return;
			}
			if (session_name.length == 0) {
				session_name = "0";
			}
			if (remote_connection.active) {
				var hostname = host.text.strip ();
				if (hostname.length == 0) {
					show_error ("Host is missing.");
					return;
				}

				uint64 port_number = 22;
				var port_text = port.text.strip ();
				if (port_text.length != 0) {
					if (!uint64.try_parse (port.text.strip (), out port_number)) {
						show_error ("Port is too large.");
						return;
					}
					if (port_number > short.MAX) {
						show_error ("Port is too large.");
						return;
					}
				}
				var username = user.text.strip ();
				if (username.length == 0) {
					username = Environment.get_user_name ();
				}
				stream = TMuxSshStream.open (session_name, host.text, (short) port_number, username, null); //TODO keyboard-interactive handler
			} else {
				stream = TMuxLocalStream.open (session.text);
			}
			if (stream == null) {
				show_error ("Could not connect.");
			} else {
				((Application) application).add_stream (stream);
			}
		} catch (Error e) {
			show_error (e.message);
		}
		destroy ();
	}
}
