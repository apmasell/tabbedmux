/**
 * Create an open new session dialog
 */
[GtkTemplate (ui = "/name/masella/tabbedmux/open.ui")]
public class TabbedMux.OpenDialog : Gtk.Window {
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
	[GtkChild]
	private Gtk.Entry binary;

	internal OpenDialog (Window parent) {
		Object (application: parent.application);
		transient_for = parent;
	}

	[GtkCallback]
	private void on_cancel () {
		destroy ();
	}

	/**
	 * If the user start typying in an SSH-only box, flip the connection type.
	 */
	[GtkCallback]
	private void on_ssh_changed () {
		if (!remote_connection.active) {
			remote_connection.active = true;
		}
	}

	/**
	 * Validate the user input, try to create a session (blocking) and then register it with the application.
	 */
	[GtkCallback]
	private void on_connect () {
		try {
			TMuxStream? stream;

			var session_name = session.text.strip ();
			if (":" in session_name) {
				show_error (this, "Session names may not contain colons.");
				return;
			}
			if (session_name.length == 0) {
				session_name = "0";
			}

			var tmux_binary = binary.text.strip ();
			if (tmux_binary.length == 0) {
				tmux_binary = "tmux";
			}

			if (remote_connection.active) {
				var hostname = host.text.strip ();
				if (hostname.length == 0) {
					show_error (this, "Host is missing.");
					return;
				}

				uint64 port_number = 22;
				var port_text = port.text.strip ();
				if (port_text.length != 0) {
					if (!uint64.try_parse (port.text.strip (), out port_number)) {
						show_error (this, "Port is too large.");
						return;
					}
					if (port_number > short.MAX) {
						show_error (this, "Port is too large.");
						return;
					}
				}
				var username = user.text.strip ();
				if (username.length == 0) {
					username = Environment.get_user_name ();
				}
				var keybd_dialog = new KeyboardInteractiveDialog (this, host.text);
				stream = TMuxSshStream.open (session_name, host.text, (short) port_number, username, tmux_binary, keybd_dialog.respond);
			} else {
				stream = TMuxLocalStream.open (session_name, tmux_binary);
			}
			if (stream == null) {
				show_error (this, "Could not connect.");
			} else {
				((Application) application).add_stream ((!)stream);
			}
		} catch (Error e) {
			show_error (this, e.message);
		}
		destroy ();
	}
}
