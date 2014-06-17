public class TabbedMux.SavedSessions : GLib.MenuModel {
	private Settings settings;
	private Variant local_sessions;
	private Variant ssh_sessions;
	public SavedSessions (string schema) {
		settings = new Settings (schema);
		unowned SavedSessions unowned_this = this;
		settings.changed.connect (unowned_this.settings_changed);
		settings_changed ();
	}
	private void settings_changed () {
		local_sessions = settings.get_value ("saved-local");
		ssh_sessions = settings.get_value ("saved-ssh");
		changed ();
	}
	public signal void changed ();

	public delegate bool CheckDisabled (SessionItem item);

	public void update (Gtk.Menu menu, CheckDisabled check) {
		foreach (var child in menu.get_children ()) {
			menu.remove (child);
		}
		if (local_sessions != null) {
			foreach (var local_session in local_sessions) {
				var item = new LocalSessionItem (local_session.get_string ());
				item.sensitive = !check (item);
				menu.add (item);
			}
		}
		if (ssh_sessions != null) {
			foreach (var ssh_session in ssh_sessions) {
				string session;
				string host;
				uint16 port;
				string username;
				ssh_session.get ("(ssqs)", out session, out host, out port, out username);
				var item = new SshSessionItem (session, host, port, username);
				item.sensitive = !check (item);
				menu.add (item);
			}
		}
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
					((Application) window.application).add_stream (stream);
				}
			} catch (Error e) {
				show_error (window, e.message);
			}
		}
	}
	private class LocalSessionItem : SessionItem {
		private string session;
		internal LocalSessionItem (string session) {
			this.session = session;
			label = "%s (Local)".printf (session);
		}
		public override bool matches (TMuxStream stream) {
			return stream is TMuxLocalStream && stream.session_name == session;
		}
		protected override TMuxStream? open () throws Error {
			return TMuxLocalStream.open (session);
		}
	}
	private class SshSessionItem : SessionItem {
		private string session;
		private string host;
		private uint16 port;
		private string username;
		internal SshSessionItem (string session, string host, uint16 port, string username) {
			this.session = session;
			this.host = host;
			this.port = port;
			this.username = username;
			label = port == 22 ? "%s@%s - %s".printf (username, host, session) : "%s@%s:%hu - %s".printf (username, host, port, session);
		}
		public override bool matches (TMuxStream stream) {
			if (stream is TMuxSshStream && stream.session_name == session) {
				var ssh_stream = (TMuxSshStream) stream;
				return ssh_stream.host == host && ssh_stream.port == port && ssh_stream.username == username;
			}
			return false;
		}
		protected override TMuxStream? open () throws Error {
			var keybd_dialog = new KeyboardInteractiveDialog ((Gtk.Window)get_toplevel (), host);
			return TMuxSshStream.open (session, host, port, username, keybd_dialog.respond);
		}
	}
}
