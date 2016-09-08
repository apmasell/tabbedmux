/**
 * Extend Vte to be wired to a TMuxWindow.
 *
 * This widget is actually a box that holds a VTE terminal, rather than
 * extending one. It does this to facilitate proper terminal sizing. TMux will
 * make a window only as large as the smallest client attached. If other
 * clients are attached, the terminal might not be as big.
 */
public class TabbedMux.Terminal : Gtk.Box {
	public Vte.Terminal terminal {
		get; private set; default = new Vte.Terminal ();
	}
	public TMuxWindow tmux_window {
		get; private set;
	}
	public Gtk.Label tab_label {
		get; private set; default = new Gtk.Label ("New Session");
	}
	public static Regex? uri_regex;
	private Gtk.Overlay overlay = new Gtk.Overlay ();
	private OverloadWidget overload = new OverloadWidget ();
	private const string X_SCHEME_HANDLER = "x-scheme-handler/";
	class construct {
		var buffer = new StringBuilder ();
		buffer.append ("(");
		var first = true;
		foreach (var info in AppInfo.get_all ()) {
			foreach (var type in info.get_supported_types ()) {
				if (!type.has_prefix (X_SCHEME_HANDLER)) {
					continue;
				}
				if (first) {
					first = false;
				} else {
					buffer.append_c ('|');
				}
				buffer.append (type.offset (X_SCHEME_HANDLER.length));
			}
		}
		buffer.append ("):([A-Za-z0-9_~:/?#@!$&'()*+,;=[\\].-]|%[0-9A-Fa-f][0-9A-Fa-f])+");
		message ("URL regex: %s", buffer.str);
		try {
			uri_regex = new Regex (buffer.str);
		} catch (RegexError e) {
			critical ("Regex error: %s", e.message);
		}
	}
	public Terminal (TMuxWindow tmux_window) {
		unowned Terminal unowned_this = this;

		this.tmux_window = tmux_window;
		this.orientation = Gtk.Orientation.VERTICAL;
		tab_label.ellipsize = Pango.EllipsizeMode.MIDDLE;
		tab_label.width_chars = 20;
		tab_label.max_width_chars = tab_label.width_chars + 30;

		/* Set up the VTE terminal. */
		terminal.pointer_autohide = true;
		terminal.encoding = "UTF-8";
		var list = new Gtk.TargetList ({});
		list.add_text_targets (0);
		list.add_uri_targets (1);
		Gtk.drag_dest_set (terminal, Gtk.DestDefaults.ALL, Gtk.target_table_new_from_list (list), Gdk.DragAction.COPY | Gdk.DragAction.MOVE);
		/* Handle key and mouse presses */
		terminal.commit.connect (unowned_this.vte_commit);
		terminal.button_press_event.connect (unowned_this.vte_button_press_event);
		terminal.char_size_changed.connect (unowned_this.set_size_from_tmux);
		terminal.drag_data_received.connect (unowned_this.vte_drag);
		terminal.increase_font_size.connect (unowned_this.increase_font);
		terminal.decrease_font_size.connect (unowned_this.decrease_font);

		int id = terminal.match_add_gregex (uri_regex, 0);
		terminal.match_set_cursor_type (id, Gdk.CursorType.HAND2);

		/* Put the terminal in a box in this box. This ensure that the terminal can have both vertical and horizontal free padding*/
		var innerbox = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
		innerbox.pack_start (overlay, false);
		pack_start (innerbox, false);
		overlay.add (terminal);

		overload.send_ctrl_c.connect (unowned_this.send_ctrl_c_to_tmux);
		tmux_window.notify["overloaded"].connect (unowned_this.overloaded_changed);

		/* Wire all the TMux events */
		tmux_window.renamed.connect (unowned_this.update_tab_label);
		tmux_window.stream.renamed.connect (unowned_this.update_tab_label);
		tmux_window.rx_data.connect (terminal.feed);
		tmux_window.size_changed.connect (unowned_this.set_size_from_tmux);
		tmux_window.stream.change_font.connect (unowned_this.update_font);

		update_tab_label ();

		tmux_window.pull_size ();
	}

	/**
	 * Capture URL events and dispatch the rest to Vte.
	 */
	private bool vte_button_press_event (Gdk.EventButton event) {
		if (event.type == Gdk.EventType.BUTTON_PRESS && event.button == 3) {
			var url = terminal.match_check_event (event, null);
			if (url != null) {
				var context_menu = new ContextMenu ((!)url);
				context_menu.attach_to_widget (terminal, null);
				context_menu.popup (null, null, null, event.button, event.time);
				return true;
			}
		}
		return false;
	}

	private void vte_drag (Gtk.Widget widget,
			       Gdk.DragContext context,
			       int x,
			       int y,
			       Gtk.SelectionData selection_data,
			       uint info,
			       uint timestamp) {
		if (info == 1) {
			var first = true;
			foreach (var uri in selection_data.get_uris ()) {
				if (first) {
					first = false;
				} else {
					tmux_window.tx_data (" ".data);
				}
				tmux_window.tx_data (Shell.quote (uri).data);
			}
		} else {
			tmux_window.tx_data (selection_data.get_text ().data);
		}
	}

	public void update_tab_label () {
		message ("Updating window name: %s - %s - %s\n", tmux_window.title, tmux_window.stream.session_name, tmux_window.stream.name);
		tab_label.set_text (tmux_window.title);
		tab_label.set_tooltip_text (@"$(tmux_window.stream.session_name) - $(tmux_window.stream.name)");
		queue_draw ();
	}

	private void increase_font () {
		message ("Increase font");
		adjust_font (true);
	}
	private void decrease_font () {
		message ("Decrease font");
		adjust_font (false);
	}

	private void overloaded_changed (Object source, ParamSpec name) {
		message ("Changed overload to %s.", tmux_window.overloaded.to_string ());
		if (tmux_window.overloaded) {
			overlay.add_overlay (overload);
			overlay.show_all ();
		} else {
			overlay.remove (overload);
			overlay.show_all ();
		}
	}

	private void send_ctrl_c_to_tmux () {
		tmux_window.tx_data ("\x03".data);
	}

	public void adjust_font (bool increase) {
		var font = terminal.font_desc;
		font.set_size (font.get_size () + Pango.SCALE * (increase ? 1 : -1));
		if (font.get_size () > Pango.SCALE) {
			tmux_window.stream.change_font (font);
		} else {
			message ("Terminal font size (%d) too small. Not adjusting.", font.get_size ());
		}
	}

	private void update_font (Pango.FontDescription? font) {
		terminal.font_desc = font;
	}

	/**
	 * Pump Vte keyboard data to TMux.
	 */
	private void vte_commit (string text, uint size) {
		tmux_window.tx_data (text.data);
	}

	public void paste_text (Gtk.Clipboard sender, string? text) {
		if (text != null) {
			tmux_window.paste_text ((!)text);
		}
	}

	/**
	 * Resize the remote TMux window based on the size of the box holding the VTE session.
	 */
	public void resize_tmux () {
		long width = get_allocated_width () / terminal.get_char_width ();
		long height = get_allocated_height () / terminal.get_char_height ();
		if (width > 10 && height > 10) {
			tmux_window.resize ((int) width, (int) height);
		}
	}

	private void set_size_from_tmux () {
		message ("Resizing to TMux dimension %dx%d.", tmux_window.width, tmux_window.height);
		terminal.set_size (tmux_window.width, tmux_window.height);
		/* Yes, we are creating a positive feedback loop that we expect TMux to resolve. */
		resize_tmux ();
		queue_resize ();
	}

	/**
	 * Change the tab label if a window from the same TMux session is selected.
	 */
	public void sibling_selected (bool selected) {
		if (selected) {
			var description = new Pango.FontDescription ();
			description.set_weight (Pango.Weight.BOLD);
			tab_label.override_font (description);
		} else {
			tab_label.override_font (null);
		}
	}
}

[GtkTemplate (ui = "/name/masella/tabbedmux/overload_widget.ui")]
public class TabbedMux.OverloadWidget : Gtk.AspectFrame {

	public signal void send_ctrl_c ();
	[GtkCallback]
	private void on_clicked () {
		send_ctrl_c ();
	}
}
