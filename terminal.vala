public class SshMux.Terminal : Vte.Terminal {
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
			var regex = new GLib.Regex ("[a-zA-Z][a-zA-Z0-9+.-]*:([A-Za-z0-9_~:/?#[]@!$&'()*+,;=-]|%[0-9A-Fa-f][0-9A-Fa-f])+");
			int id = this.match_add_gregex (regex, 0);
			match_set_cursor_type (id, Gdk.CursorType.HAND2);
		} catch (RegexError e) {
			critical (e.message);
		}
		unowned Terminal unowned_this = this;
		tmux_window.renamed.connect (unowned_this.update_tab_label);
		tmux_window.stream.renamed.connect (unowned_this.update_tab_label);
		tmux_window.rx_data.connect (unowned_this.feed);
		tmux_window.size_changed.connect (unowned_this.set_size_from_tmux);
	}

	public void update_tab_label () {
		message ("Updating window name: %s - %s - %s\n", tmux_window.title, tmux_window.stream.session_name, tmux_window.stream.name);
		tab_label.set_text (tmux_window.title);
		tab_label.set_tooltip_text (@"$(tmux_window.stream.session_name) - $(tmux_window.stream.name)");
		queue_draw ();
	}

	public override void commit (string text, uint size) {
		tmux_window.tx_data (text.data);
	}

	public override bool map_event (Gdk.EventAny event) {
		if (event.type == Gdk.EventType.MAP) {
			resize_tmux ();
		}
		return false;
	}
	public string? get_link (long x, long y) {
		int tag;
		return match_check (x / get_char_width (), y / get_char_height (), out tag);
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
