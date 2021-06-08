/**
 * Access a TMux session via libssh2.
 */
internal class TabbedMux.TMuxSshStream : TMuxStream {
	AsyncImpedanceMatcher matcher;
	SSH2.Channel channel;
	const int MAX_UNLOCK_ATTEMPTS = 3;

	public string host {
		get; private set;
	}
	public uint16 port {
		get; private set;
	}
	public string username {
		get; private set;
	}

	internal TMuxSshStream (string session_name, string host, uint16 port, string username, string binary, AsyncImpedanceMatcher matcher, owned SSH2.Channel channel) {
		base (port == 22 ? @"$(username)@$(host) $(binary)" : @"$(username)@$(host):$(port) $(binary)", session_name, binary);
		this.matcher = matcher;
		this.channel = (owned) channel;
		this.host = host;
		this.port = port;
		this.username = username;
		matcher.cancellable = cancellable;
	}

	~TMuxSshStream () {
		/* To make libssh happy, the channel must be destroyed before the session, synchronously. */
		matcher.session.blocking = true;
		channel = null;
	}

	/**
	 * Read from the remote TMux instance via a non-blocking libssh2 socket.
	 */
	protected override async ssize_t read (uint8[] buffer) throws Error {
		return yield matcher.invoke_ssize_t ((s, c) => c.read (buffer), channel);
	}

	protected override async ssize_t write (uint8[] data) throws Error {
		return yield matcher.invoke_ssize_t ((s, c) => c.write (data), channel);
	}

	/**
	 * Perform public key authentication using all the SSH keys in the agent and the file in the user's home directory.
	 */
	private static async void do_public_key_auth (AsyncImpedanceMatcher matcher, string username, string host, uint16 port, InteractiveAuthentication get_password) throws IOError {
		try {
			SSH2.Agent? agent = null;
			yield matcher.invoke_obj<unowned SSH2.Agent> ((s, c) => agent = s.create_agent ());
			yield matcher.invoke ((s, c) => ((!)agent).connect ());
			yield matcher.invoke ((s, c) => ((!)agent).list_identities ());
			unowned SSH2.AgentKey? key = null;
			while (((!)agent).next (out key, key) == SSH2.Error.NONE) {
				try {
					yield matcher.invoke ((s, c) => ((!)agent).user_auth (username, (!)key));
					message ("Authentication succeeded for %s@%s:%hu with public key %s.", username, host, port, ((!)key).comment ?? "unknown");
					return;
				} catch (IOError e) {
					message ("Authentication failed for %s@%s:%hu with public key %s: %s", username, host, port, ((!)key).comment ?? "unknown", e.message);
				}
			}
		} catch (IOError e) {
			warning ("Failed to communicate with agent: %s", e.message);
		}

		var attempts = 0;
		string? password = null;
		var private_key = @"$(Environment.get_home_dir())/.ssh/id_rsa";
		var public_key = private_key + ".pub";
		if (!FileUtils.test (public_key, FileTest.EXISTS) || !FileUtils.test (private_key, FileTest.EXISTS)) {
			return;
		}
		yield matcher.invoke ((s, c) => {
					      var result = s.auth_publickey_from_file (username, public_key, private_key, password);
					      if (result == SSH2.Error.PUBLICKEY_UNVERIFIED) {
						      if (attempts < MAX_UNLOCK_ATTEMPTS && get_password != null) {
							      attempts++;
							      password = password_simple (@"Unlock private key (attempt $(attempts) of $(MAX_UNLOCK_ATTEMPTS):", (!)get_password);
							      result = SSH2.Error.AGAIN;
						      } else {
							      result = SSH2.Error.AUTHENTICATION_FAILED;
						      }
					      }
					      return result;
				      }, null, SSH2.Error.AUTHENTICATION_FAILED);
		return;
	}

	/* see password_adapter.c */
	public delegate void InteractiveAuthentication (string instruction, SSH2.keyboard_prompt[] prompts, SSH2.keyboard_response[] responses);
	private static extern SSH2.Error password_adapter (SSH2.Session session, string username, InteractiveAuthentication handler);
	private static extern string? password_simple (string banner, InteractiveAuthentication handler);

	/**
	 * Attempt to open an SSH connection and talk to TMux on that host.
	 */
	public async static TMuxStream? open (string session_name, string host, uint16 port, string username, string binary, InteractiveAuthentication? get_password, BusyDialog busy_dialog) throws Error {
		/*
		 * Create a GIO socket for that host. We do this so we can use async methods on it.
		 */
		busy_dialog.message = @"Connecting to '$(session_name)' on $(username)@$(host):$(port)...";
		var client = new SocketClient ();
		var connection = yield client.connect_to_host_async (host, port, busy_dialog.cancellable);

		/*
		 * Try to set no delay.
		 */
		try {
			connection.socket.set_option (IPPROTO_TCP, TCP_NODELAY, 1);
		} catch (Error e) {
			warning (e.message);
		}

		var matcher = new AsyncImpedanceMatcher (connection.socket);
		matcher.cancellable = busy_dialog.cancellable;
		/*
		 * Tell libssh2 to do the handshake.
		 */
		busy_dialog.message = @"Handshaking '$(session_name)' on $(username)@$(host):$(port)...";
		yield matcher.invoke ((s, c) => s.handshake (connection.socket.fd));

		/* List the know hosts */
		SSH2.KnownHosts? known_hosts = null;
		yield matcher.invoke_obj<unowned SSH2.KnownHosts> ((s, c) => known_hosts = s.get_known_hosts ());

		var good_key = false;
		try {
			yield matcher.invoke_ssize_t ((s, c) => known_hosts.read_file (@"$(Environment.get_home_dir ())/.ssh/known_hosts_tabbed_mux"));
			SSH2.KeyType type;
			var key = matcher.session.get_host_key (out type);
			unowned SSH2.Host? known;
			switch (known_hosts.checkp (host, port, key,  SSH2.HostFormat.TYPE_PLAIN | SSH2.HostFormat.KEYENC_RAW | type.get_format (), out known)) {
			 case SSH2.CheckResult.MATCH :
				 good_key = true;
				 break;

			 case SSH2.CheckResult.MISMATCH :
				 good_key = run_host_key_dialog<weak TabbedMux.AsyncImpedanceMatcher> (busy_dialog, "KEY MISTMATCH!!! POSSIBLE ATTACK!!!", "Proceed Anyway", "Stop Immediately", matcher.session, host, port, null);
				 break;

			 case SSH2.CheckResult.NOTFOUND :
				 good_key = run_host_key_dialog<weak TabbedMux.AsyncImpedanceMatcher> (busy_dialog, "Unknown host.", "Accept Once", "Cancel", matcher.session, host, port, known_hosts);
				 break;

			 case SSH2.CheckResult.FAILURE :
				 good_key = run_host_key_dialog<weak TabbedMux.AsyncImpedanceMatcher> (busy_dialog, "Failed to check for public key.", "Accept Once", "Cancel", matcher.session, host, port, null);
				 break;
			}
		} catch (IOError e) {
			message ("Known hosts check: %s", e.message);
			good_key = run_host_key_dialog<weak TabbedMux.AsyncImpedanceMatcher> (busy_dialog, "No database of known hosts.", "Accept Once", "Cancel", matcher.session, host, port, known_hosts);
		}
		if (!good_key) {
			return null;
		}
		/*
		 * Try to authenticate.
		 */

		busy_dialog.message = @"Getting authentication methods for '$(session_name)' on $(username)@$(host):$(port)...";
		unowned string? authentication_methods = null;
		yield matcher.invoke_obj<unowned string> ((s, c) => authentication_methods = s.list_authentication (username.data));
		foreach (var method in authentication_methods.split (",")) {
			if (matcher.session.authenticated) {
				break;
			}
			switch (method) {
			 case "publickey" :
				 busy_dialog.message = @"Trying public key authentication for '$(session_name)' on $(username)@$(host):$(port)...";
				 yield do_public_key_auth (matcher, username, host, port, get_password);
				 break;

			 case "keyboard-interactive" :
				 if (get_password == null) {
					 break;
				 }
				 busy_dialog.message = @"Trying interactive authentication for '$(session_name)' on $(username)@$(host):$(port)...";
				 var attempts = 0;
				 while ((yield matcher.invoke ((s, c) => password_adapter (s, username, (!)get_password), null, SSH2.Error.AUTHENTICATION_FAILED)) && attempts < 3) {
					 attempts++;
				 }
				 break;

			 case "password" :
				 if (get_password == null) {
					 break;
				 }
				 busy_dialog.message = @"Trying password authentication for '$(session_name)' on $(username)@$(host):$(port)...";
				 var attempts = 0;
				 string? password = null;
				 do {
					 password = password_simple ("Enter password:", (!)get_password);
					 if (password == null) {
						 break;
					 }
					 attempts++;
				 } while ((yield matcher.invoke ((s, c) => s.auth_password (username, (!)password), null, SSH2.Error.AUTHENTICATION_FAILED)) && attempts < 3);
				 break;

			 default :
				 message ("%s@%s:%d:%s: Skipping unknown authentication method: %s", username, host, port, session_name, method);
				 break;
			}
		}
		if (!matcher.session.authenticated) {
			throw new IOError.PERMISSION_DENIED ("Could not authenticate.");
		}
		/*
		 * Try to exec tmux in a shell on the remote end.
		 */
		busy_dialog.message = @"Starting TMux on '$(session_name)' on $(username)@$(host):$(port)...";
		SSH2.Channel? channel = null;
		yield matcher.invoke_obj<unowned SSH2.Channel> ((s, c) => channel = s.open_channel (), null);
		var command = @"TERM=$(TERM_TYPE) $(Shell.quote (binary)) -u -C new -A -s $(Shell.quote (session_name))";
		message ("%s@%s:%d:%s: executing %s", username, host, port, session_name, command);
		yield matcher.invoke ((s, c) => ((!)c).start_command (command), channel);

		/*
		 * Create an Stream and return it.
		 */
		matcher.session.set_keep_alive (true, 10);
		return new TMuxSshStream (session_name, host, port, username, binary, matcher, (!)(owned) channel);
	}
	private static bool run_host_key_dialog<T> (Gtk.Window parent, string message, string yes, string no, SSH2.Session<T> session, string host, uint16 port, SSH2.KnownHosts? known_hosts) {
		Gtk.Dialog dialog;
		if (known_hosts == null) {
			dialog = new Gtk.Dialog.with_buttons ("SSH Host Key - TabbedMux", parent, Gtk.DialogFlags.MODAL, yes, Gtk.ResponseType.OK, no, Gtk.ResponseType.CANCEL);
		} else {
			dialog = new Gtk.Dialog.with_buttons ("SSH Host Key - TabbedMux", parent, Gtk.DialogFlags.MODAL, yes, Gtk.ResponseType.OK, "Store Permanently", Gtk.ResponseType.YES, no, Gtk.ResponseType.CANCEL);
		}
		dialog.resizable = false;
		var buffer = new StringBuilder ();
		buffer.append (message);
		buffer.append_printf ("\nThe host %s:%hu has the key ", host, port);
		unowned uint8[] hash = session.get_host_key_hash (SSH2.HashType.SHA1);
		for (var it = 0; it < hash.length; it++) {
			if (it > 0) {
				buffer.append_c (':');
			}
			buffer.append_printf ("%2x", hash[it]);
		}
		buffer.append (". Proceed anyway?");
		var label  = new Gtk.Label (buffer.str);
		label.set_line_wrap (true);
		dialog.border_width = 5;
		dialog.get_content_area ().pack_start (label, false, false);
		dialog.get_content_area ().border_width = 10;
		dialog.get_content_area ().spacing = 14;
		dialog.get_content_area ().show_all ();
		bool result;
		switch (dialog.run ()) {
		 case Gtk.ResponseType.CANCEL :
			 result = false;
			 break;

		 case Gtk.ResponseType.YES :
			 SSH2.KeyType key_type;
			 unowned uint8[] key = session.get_host_key (out key_type);
			 if (known_hosts.addc (@"[$(host)]:$(port)", null, key, null, SSH2.HostFormat.TYPE_PLAIN | SSH2.HostFormat.KEYENC_RAW | key_type.get_format (), null) != SSH2.Error.NONE || known_hosts.write_file (@"$(Environment.get_home_dir ())/.ssh/known_hosts_tabbed_mux") != SSH2.Error.NONE) {
				 warning ("Failed to add key for %s:%hu.", host, port);
			 }
			 result = true;
			 break;

		 default :
			 result = true;
			 break;
		}
		dialog.destroy ();
		return result;
	}
}
/**
 * Wrapper to control how libssh2 and GLib interact.
 */
public class TabbedMux.AsyncImpedanceMatcher {
	public delegate SSH2.Error Operation (SSH2.Session<unowned AsyncImpedanceMatcher> session, SSH2.Channel? channel);
	public delegate ssize_t OperationSsize_t (SSH2.Session<unowned AsyncImpedanceMatcher> session, SSH2.Channel? channel);
	public delegate unowned T? OperationObj<T> (SSH2.Session<unowned AsyncImpedanceMatcher> session, SSH2.Channel? channel);

	private SSH2.Disconnect disconnect_reason = 0;

	private static void disconnect_handler (SSH2.Session<unowned AsyncImpedanceMatcher> session, SSH2.Disconnect reason, uint8[] msg, uint8[] language, ref unowned AsyncImpedanceMatcher user_data) {
		message ("Disconnect: %s", (string) msg);
		user_data.disconnect_reason = reason;
		user_data.cancellable.cancel ();
	}
	public SSH2.Session<unowned AsyncImpedanceMatcher> session;
	public Socket socket;
	public Cancellable? cancellable;
	public AsyncImpedanceMatcher (Socket socket) {
		this.socket = socket;
		session = SSH2.Session.create<unowned AsyncImpedanceMatcher> (this);
		session.blocking = false;
		session.set_disconnect_handler (disconnect_handler);
	}
	/**
	 * Call a method that returns a ssize_t, which will be negative on error, or positive on success.
	 */
	public async ssize_t invoke_ssize_t (OperationSsize_t handler, SSH2.Channel? channel = null) throws IOError {
		ssize_t result = 0;
		yield invoke ((s, c) => (result = handler (s, c)) > 0 ? SSH2.Error.NONE : (SSH2.Error)result, channel);
		if (result == 0 && channel != null) {
			yield close_channel (channel);
		}
		return result;
	}
	/**
	 * Call a method that returns an object or a null reference on failure. If it
	 * fails, the error is automatically extracted.
	 */
	public async bool invoke_obj<T> (OperationObj<T> handler, SSH2.Channel? channel = null, SSH2.Error suppression = SSH2.Error.NONE) throws IOError {
		return yield invoke ((s, c) => handler (s, c) != null ? SSH2.Error.NONE : s.last_error, channel, suppression);
	}

	public async void close_channel (SSH2.Channel channel) throws IOError {
		if (channel.eof () == 0) {
		  yield invoke ((s, c) => c.send_eof (), channel);
		  yield invoke ((s, c) => c.wait_eof (), channel);
		}
		yield invoke ((s, c) => c.wait_closed (), channel);

		if (channel.exit_status > 0) {
			throw new IOError.CLOSED (@"Remote TMux terminated with $(channel.exit_status).");
		}
		char[]? error_message = null;
		char[]? signal_name = null;
		char[]? language_tag = null;
		if (channel.get_exit_signal (out signal_name, out error_message, out language_tag) == SSH2.Error.NONE && signal_name != null) {
			throw new IOError.CLOSED (@"Remote TMux caught signal $((string) signal_name).");
		}
		message ("%s:%s:%s", (string) error_message, (string) signal_name, (string) language_tag);
	}

	/**
	 * Glue libssh2 to GLib's event loop.
	 *
	 * If there is either no data or reading would block, Take our current
	 * continuation and make it the callback for data being present in the
	 * underlying GIO socket (libssh2 isn't helpful here) and put it in the
	 * dispatch loop, then wait.
	 * @param handler the operation that will be performed. It will be called as
	 * many times as needed to be successful.
	 * @param channel the channel that needs I/O, if any.
	 * @param suppression an error that will not cause an exception to be thrown.
	 * @return normally false, but true if the suppressed error is caught.
	 */
	public async bool invoke (Operation handler, SSH2.Channel? channel = null, SSH2.Error suppression = SSH2.Error.NONE) throws IOError {
		SSH2.Error result = SSH2.Error.NONE;
		SocketSource? source = null;

		while (!cancellable.is_cancelled () && (result = handler (session, channel)) == SSH2.Error.AGAIN) {
			if (source != null) {
				warning ("SSH somehow re-entered an active asynchronous callback.");
			}
			SourceFunc async_continue = invoke.callback;
			source = socket.create_source (session.block_directions.to_condition (), cancellable);
			((!)source).set_callback (() => { async_continue (); return Source.REMOVE; });

			/* Perform an obligatory SSH keep-alive. */
			int seconds_to_next;
			if ((result = session.send_keep_alive (out seconds_to_next)) != SSH2.Error.NONE) {
				warning ("SSH keep-alive failed!");
				break;
			}
			if (seconds_to_next > 0) {
				/* If we should send a keep alive, add a timer. */
				var timeout = new TimeoutSource.seconds (seconds_to_next);
				timeout.set_callback (() => false);
				((!)source).add_child_source (timeout);
			}
			((!)source).attach (MainContext.default ());
			yield;
			source = null;
		}
		if (result == suppression && suppression != SSH2.Error.NONE) {
			return true;
		}
		if (channel != null && result != SSH2.Error.NONE) {
			char[]? error_message = null;
			session.get_last_error (out error_message);
			if (error_message != null) {
				throw new IOError.FAILED ((string) error_message);
			}
		}

		if (result == SSH2.Error.SOCKET_RECV) {
			/* Some error in the underlying socket. */
			int no = errno;
			throw_errno (no);
		}
		if (disconnect_reason != 0) {
			throw new IOError.CLOSED ("Server disconnected.");
		}

		if (result != SSH2.Error.NONE) {
			char[] error_message;
			session.get_last_error (out error_message);
			throw new IOError.INVALID_DATA ((string) error_message);
		}
		if (cancellable != null && cancellable.is_cancelled ()) {
			throw new IOError.CANCELLED ("User cancelled.");
		}
		return false;
	}
}
namespace TabbedMux {
	private static extern int search_buffer (StringBuilder buffer);
	[NoReturn]
	private static extern void throw_errno (int err_number) throws IOError;
}
