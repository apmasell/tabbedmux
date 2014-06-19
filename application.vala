public class TabbedMux.Application : Gtk.Application {
	internal Gee.Set<TMuxStream> streams = new Gee.HashSet<TMuxStream> ();
	internal SavedSessions saved_sessions;

	protected override void activate () {
		new Window (this).show_all ();
	}

	internal Application () {
		Object (application_id: "name.masella.tabbedmux");
		saved_sessions = new SavedSessions (application_id);
	}

	/**
	 * Add a new TMuxStream to the applications menus.
	 *
	 * This registers all the appropriate callbacks so the application can handle events from the stream.
	 */
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

	/**
	 * Deal with a stream dying for any reason.
	 */
	private void on_stream_closed (TMuxStream stream, string reason) {
		streams.remove (stream);
		try {
			var notification = new Notify.Notification (@"Disconnected from $(stream.name) session '$(stream.session_name)'.", reason, null);
			notification.show ();
		} catch (Error e) {
			critical ("Notification error: %s", e.message);
		}
	}

	/**
	 * When a window is created remotely, figure out what GTK+ windw to stick it in.
	 */
	private void on_window_created (TMuxWindow tmux_window) {
		var window = (active_window as Window);
		if (window == null) {
			critical ("Unknown window type active.");
		}
		((!)window).add_window (tmux_window);
	}

	/**
	 * On startup, create a TMux on the current system.
	 */
	protected override void startup () {
		base.startup ();
		try {
			var stream = TMuxLocalStream.open ("0");
			if (stream != null) {
				add_stream ((!)stream);
			}
		} catch (Error e) {
			critical ("Startup error: %s", e.message);
		}
	}
}
