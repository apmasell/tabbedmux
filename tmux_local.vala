/**
 * Talk to a TMux instance spawned locally.
 */
public class TabbedMux.TMuxLocalStream : TMuxStream {
	DataInputStream input;
	UnixOutputStream output;
	internal TMuxLocalStream (string session_name, string binary, InputStream input, UnixOutputStream output) {
		base ("%s (Local:%s)".printf (Environment.get_host_name (), binary), session_name, binary);
		this.output = output;
		this.input = new DataInputStream (input);
	}
	protected override async string? read_line_async (Cancellable cancellable) throws Error {
		return yield input.read_line_async (Priority.DEFAULT, cancellable);
	}

	protected override void write (uint8[] data) throws IOError {
		output.write (data);
	}

	public static TMuxStream? open (string session_name, string binary = "tmux") throws Error {
		Pid child_pid;
		int standard_input;
		int standard_output;
		if (Process.spawn_async_with_pipes (null, { binary, "-C", "new", "-A", "-s", session_name }, { "TERM", TERM_TYPE }, SpawnFlags.SEARCH_PATH, null, out child_pid, out standard_input, out standard_output)) {
			var input = new UnixInputStream (standard_output, true);
			var output = new UnixOutputStream (standard_input, true);
			var stream = new TMuxLocalStream (session_name, binary, input, output);
			return stream;
		}
		return null;
	}
}
