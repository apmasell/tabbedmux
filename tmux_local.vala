/**
 * Talk to a TMux instance spawned locally.
 */
public class TabbedMux.TMuxLocalStream : TMuxStream {
	UnixInputStream input;
	UnixOutputStream output;
	internal TMuxLocalStream (string session_name, string binary, UnixInputStream input, UnixOutputStream output) {
		base ("%s (Local:%s)".printf (Environment.get_host_name (), binary), session_name, binary);
		this.output = output;
		this.input = input;
	}
	/**
	 * Reading from the underlying pipe.
	 */
	protected override async ssize_t read (uint8[] buffer) throws Error {
		PollableSource? source = null;
		while (true) {
			try {
				return input.read_nonblocking (buffer, cancellable);
			} catch (IOError.WOULD_BLOCK e) {
				source = input.create_source (cancellable);
				SourceFunc async_continue = read.callback;
				source.set_callback ((stream) => { async_continue (); return false; });
				source.attach (MainContext.default ());
				yield;
				source = null;
			}
		}
	}

	/**
	 * Write to the underlying pipe.
	 */
	protected override async ssize_t write (uint8[] data) throws Error {
		PollableSource? source = null;
		while (true) {
			try {
				return g_pollable_output_stream_write_nonblocking (output, data, cancellable);
			} catch (IOError.WOULD_BLOCK e) {
				source = input.create_source (cancellable);
				SourceFunc async_continue = write.callback;
				source.set_callback ((stream) => { async_continue (); return false; });
				source.attach (MainContext.default ());
				yield;
				source = null;
			}
		}
	}

	/**
	 * Fork a TMux binary and create a stream for it.
	 */
	public static TMuxStream? open (string session_name, string binary = "tmux") throws Error {
		Pid child_pid;
		int standard_input;
		int standard_output;
		/* Copy the environment, except TERM. */
		string[] environment = { @"TERM=$(TERM_TYPE)" };
		foreach (var variable in Environment.list_variables ()) {
			if (variable != "TERM") {
				environment += "%s=%s".printf (variable, Environment.get_variable (variable));
			}
		}
		/* Spawn, grabbing hold of stdin and stdout. */
		if (Process.spawn_async_with_pipes (null, { binary, "-u", "-C", "new", "-A", "-s", session_name }, environment, SpawnFlags.SEARCH_PATH, null, out child_pid, out standard_input, out standard_output)) {
			/* Write stdin and stdout to GLib streams. */
			var input = new UnixInputStream (standard_output, true);
			var output = new UnixOutputStream (standard_input, true);
			var stream = new TMuxLocalStream (session_name, binary, input, output);
			return stream;
		}
		return null;
	}
}
