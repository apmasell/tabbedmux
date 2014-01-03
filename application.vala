public class SshMux.Application : Gtk.Application {
	internal Gee.Set<TMuxStream> streams = new Gee.HashSet<TMuxStream> ();

	protected override void activate () {
		new Window (this).show_all ();
	}

	internal Application () {
		Object (application_id: "name.masella.SSHMux");
	}

	public void add_stream (TMuxStream stream) {
		if (stream in streams) {
			return;
		}
		unowned Application unowned_this = this;
		stream.connection_closed.connect (unowned_this.on_stream_closed);
		stream.window_created.connect (unowned_this.on_window_created);
		streams.add (stream);
		stream.start ();
		foreach (var window in get_windows ()) {
			if (window is Window) {
				((Window) window).add_new_stream (stream);
			}
		}
		message ("Added TMux stream for %s:%s.",  stream.name, stream.session_name);
	}

	private void on_stream_closed (TMuxStream stream, string reason) {
		//TODO remove from new session menu
		streams.remove (stream);
		try {
			var notification = new Notify.Notification (@"Disconnected from $(stream.name) session '$(stream.session_name)'.", reason, null);
			notification.show ();
		} catch (Error e) {
			critical (e.message);
		}
	}

	private void on_window_created (TMuxWindow tmux_window) {
		var window = (active_window as Window);
		if (window == null) {
			critical ("Unknown window type active.");
		}
		window.add_window (tmux_window);
	}

	protected override void startup () {
		base.startup ();
		try {
			add_stream (TMuxLocalStream.open ("0"));
		} catch (Error e) {
			critical (e.message);
		}
	}
}
