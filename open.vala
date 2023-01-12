/**
 * Create an open new session dialog
 */
[GtkTemplate (ui = "/name/masella/tabbedmux/open.ui")]
public class TabbedMux.OpenDialog : Gtk.Dialog {
	public bool success = false;
	[GtkChild]
	private unowned Gtk.RadioButton remote_connection;
	[GtkChild]
	private unowned Gtk.Entry user;
	[GtkChild]
	private unowned Gtk.Entry host;
	[GtkChild]
	private unowned Gtk.Entry port;
	[GtkChild]
	private unowned Gtk.Entry session;
	[GtkChild]
	private unowned Gtk.Entry binary;
	[GtkChild]
	private unowned Gtk.CheckButton save;

	internal OpenDialog (Window parent) {
		Object (application: parent.application, transient_for: parent);
	}

	[GtkCallback]
	private void on_cancel () {
		destroy ();
	}

	/**
	 * If the user start typing in an SSH-only box, flip the connection type.
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
			/* Validate fields common to SSH and local. */
			var session_name = strip (session.text);
			if (":" in session_name) {
				show_error (this, "Session names may not contain colons.");
				return;
			}
			if (session_name.length == 0) {
				session_name = "0";
			}

			var tmux_binary = strip (binary.text);
			if (tmux_binary.length == 0) {
				tmux_binary = "tmux";
			}

			if (remote_connection.active) {
				/* SSH. Validate all the fields. */
				var hostname = strip (host.text);
				if (hostname.length == 0) {
					show_error (this, "Host is missing.");
					return;
				}

				uint64 port_number = 22;
				var port_text = strip (port.text);
				if (port_text.length != 0) {
					if (!uint64.try_parse (strip (port.text), out port_number)) {
						show_error (this, "Port is not a number.");
						return;
					}
					if (port_number > ushort.MAX) {
						show_error (this, "Port is too large.");
						return;
					}
				}
				var username = strip (user.text);
				if (username.length == 0) {
					username = Environment.get_user_name ();
				}

				/* Create a handler for the password/prompts. */
				var busy_dialog = new BusyDialog (this);
				var keybd_dialog = new KeyboardInteractiveDialog (busy_dialog, host.text);
				busy_dialog.show ();
				TMuxSshStream.open.begin (session_name, host.text, (uint16) port_number, username, tmux_binary, keybd_dialog.respond, busy_dialog, (sender, result) => {
								  try {
									  var stream = TMuxSshStream.open.end (result);

				                                          /* Save if desired */
									  if (stream != null && save.active && application is Application) {
										  ((Application) application).saved_sessions.append_ssh (session_name, host.text, (uint16) port_number, username, tmux_binary);
									  }
									  deal_with_stream (stream);
								  } catch (IOError.CANCELLED e) {
								  } catch (Error e) {
									  show_error (this, e.message);
								  }
								  keybd_dialog.destroy ();
								  busy_dialog.destroy ();
							  });
			} else {
				/* Local. Don't validate SSH fields. */

				var stream = TMuxLocalStream.open (session_name, tmux_binary);

				/* Save if desired */
				if (stream != null && save.active && application is Application) {
					((Application) application).saved_sessions.append_local (session_name, tmux_binary);
				}
				deal_with_stream (stream);
			}
		} catch (IOError.CANCELLED e) {
		} catch (Error e) {
			show_error (this, e.message);
		}
	}
	/* Deal with the connection attempt. */
	void deal_with_stream (TMuxStream? stream) {
		if (stream == null) {
			show_error (this, "Could not connect.");
		} else {
			((Application) application).add_stream ((!)stream);
			success = true;
			destroy ();
		}
	}
}
[GtkTemplate (ui = "/name/masella/tabbedmux/busy.ui")]
public class TabbedMux.BusyDialog : Gtk.Dialog {
	[GtkChild]
	private unowned Gtk.Label text;
	public string message {
		set {
			text.label = value;
		}
	}
	public Cancellable cancellable {
		get; private set;
	}
	public BusyDialog (Gtk.Window parent) {
		Object (application : parent.application, transient_for: parent);
		cancellable = new Cancellable ();
	}
	[GtkCallback]
	private void on_cancel () {
		cancellable.cancel ();
	}
}
