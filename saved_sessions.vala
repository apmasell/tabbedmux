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

	public delegate void UpdateLocal (string session, string binary);
	public delegate void UpdateSsh (string session, string host, uint16 port, string username, string binary);

	private Variant append (Variant original, Variant extra) {
		var count = original.n_children ();
		var items = new Variant[count + 1];
		for (var it = 0; it < count; it++) {
			items[it] = original.get_child_value (it);
		}
		items[count] = extra;
		return new Variant.array (extra.get_type (), items);
	}

	private delegate bool Filter (Variant item);
	private Variant filter (Variant list, Filter filter) {
		var count = list.n_children ();
		if (count == 0) {
			return list;
		}
		var items = new Variant[0];
		foreach (var item in list) {
			if (filter (item)) {
				items += item;
			}
		}
		return new Variant.array (list.get_child_value (0).get_type (), items);
	}

	public void append_local (string session, string binary) {
		local_sessions = append (local_sessions, new Variant ("(ss)", session, binary));
		settings.set_value ("saved-local", local_sessions);
	}

	public void append_ssh (string session, string host, uint16 port, string username, string binary) {
		ssh_sessions = append (ssh_sessions, new Variant ("(ssqss)", session, host, port, username, binary));
		settings.set_value ("saved-ssh", ssh_sessions);
	}

	public void update (UpdateLocal update_local, UpdateSsh update_ssh) {
		if (local_sessions != null) {
			foreach (var local_session in local_sessions) {
				string session;
				string binary;
				local_session.get ("(ss)", out session, out binary);
				update_local (session, binary);
			}
		}
		if (ssh_sessions != null) {
			foreach (var ssh_session in ssh_sessions) {
				string session;
				string host;
				uint16 port;
				string username;
				string binary;
				ssh_session.get ("(ssqss)", out session, out host, out port, out username, out binary);
				update_ssh (session, host, port, username, binary);
			}
		}
	}
}
