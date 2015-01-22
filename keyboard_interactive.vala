/**
 * Create a GTK dialog populated from libssh keyboard-interactive information.
 */
public class KeyboardInteractiveDialog : Gtk.Dialog {
	public KeyboardInteractiveDialog (Gtk.Window parent, string host) {
		Object (title: @"Connect $(host)...", transient_for: parent, modal: true);
		add_button ("Ok", 0);
		set_default_response (0);
	}
	public void respond (string instruction, SSH2.keyboard_prompt[] prompts, SSH2.keyboard_response[] responses) {
		var entries = new Gtk.Entry[prompts.length];
		var box = get_content_area ();
		var grid = new Gtk.Grid ();
		box.add (grid);
		grid.attach (new Gtk.Label (instruction), 0, 0, 2, 1);
		/* SSH provides a list of prompts, so prepare a grid of text boxes. */
		for (var it = 0; it < prompts.length; it++) {
			grid.attach (new Gtk.Label ((string) prompts[it].text), 0, it + 1, 1, 1);
			var entry = new Gtk.Entry ();
			entry.visibility = prompts[it].echo;
			if (it == prompts.length - 1) {
				entry.activates_default = true;
			}
			grid.attach (entry, 1, it + 1, 1, 1);
			entries[it] = entry;
		}
		show_all ();
		run ();
		for (var it = 0; it < entries.length; it++) {
			responses[it].text = entries[it].text.data;
		}
		get_content_area ().remove (grid);
		hide ();
	}
}
