/**
 * Extend Vte to be wired to a TMuxWindow.
 */
public class TabbedMux.Terminal : Vte.Terminal {
	public TMuxWindow tmux_window {
		get; private set;
	}
	public Gtk.Label tab_label {
		get; private set;
	}

	public Terminal (TMuxWindow tmux_window) {
		tab_label = new Gtk.Label ("New Session");
		this.tmux_window = tmux_window;
		this.emulation = TERM_TYPE;
		this.pointer_autohide = true;
		try {
			var regex = new GLib.Regex ("(aim|apt|apt+http|bluetooth|callto|file|finger|fish|ftps?|https?|imaps?|info|ldaps?|magnet|man|mms[tu]?|nfs|nntps?|obexftp|pop3s?|rdp|rtsp[tu]?|sftp|sieve|skype|smb|smtps?|tel|vnc|webcal|webdavs?|xmpp):([A-Za-z0-9_~:/?#@!$&'()*+,;=[\\].-]|%[0-9A-Fa-f][0-9A-Fa-f])+");
			int id = match_add_gregex (regex, 0);
			match_set_cursor_type (id, Gdk.CursorType.HAND2);
		} catch (RegexError e) {
			critical ("Regex error: %s", e.message);
		}
		unowned Terminal unowned_this = this;
		tmux_window.renamed.connect (unowned_this.update_tab_label);
		tmux_window.stream.renamed.connect (unowned_this.update_tab_label);
		tmux_window.rx_data.connect (unowned_this.feed);
		tmux_window.size_changed.connect (unowned_this.set_size_from_tmux);
		update_tab_label ();
	}

	/**
	 * Capture URL events and dispatch the rest to Vte.
	 */
	public override bool button_press_event (Gdk.EventButton event) {
		if (event.type == Gdk.EventType.BUTTON_PRESS && event.button == 1) {
			var url = get_link ((long) event.x, (long) event.y);
			if (url != null) {
				try {
					AppInfo.launch_default_for_uri ((!)url, null);
				} catch (Error e) {
					var dialog = new Gtk.MessageDialog (get_toplevel () as Gtk.Window, Gtk.DialogFlags.MODAL, Gtk.MessageType.ERROR, Gtk.ButtonsType.OK, "%s", e.message);
					dialog.run ();
					dialog.destroy ();
				}
				return true;
			}
		}
		return false;
	}

	public void update_tab_label () {
		message ("Updating window name: %s - %s - %s\n", tmux_window.title, tmux_window.stream.session_name, tmux_window.stream.name);
		tab_label.set_text (tmux_window.title);
		tab_label.set_tooltip_text (@"$(tmux_window.stream.session_name) - $(tmux_window.stream.name)");
		queue_draw ();
	}

	/**
	 * Pump Vte keyboard data to TMux.
	 */
	public override void commit (string text, uint size) {
		tmux_window.tx_data (text.data);
	}

	/**
	 * When this thing gets originally laied out, the moon is waxing, and Mercury is in Ares, tell the remote TMux our size.
	 */
	public override bool map_event (Gdk.EventAny event) {
		if (event.type == Gdk.EventType.MAP) {
			resize_tmux ();
		}
		return false;
	}

	public string? get_link (long x, long y) {
		int tag;
		unowned Gtk.Border? border;
		style_get ("inner-border", out border);
		var x_pos = (x - (border == null ? 0 : ((!)border).left)) / get_char_width ();
		var y_pos = (y - (border == null ? 0 : ((!)border).top)) / get_char_height ();
		return match_check (x_pos, y_pos, out tag);
	}

	public void resize_tmux () {
		tmux_window.resize ((int) long.max (10, get_allocated_width () / get_char_width ()), (int) long.max (10,  get_allocated_height () / get_char_height ()));
	}

	private void set_size_from_tmux () {
		message ("Resizing to TMux dimension %dx%d.", tmux_window.width, tmux_window.height);
		set_size (tmux_window.width, tmux_window.height);
		queue_resize ();
	}
}
