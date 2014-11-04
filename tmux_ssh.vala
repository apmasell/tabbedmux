/**
 * Access a TMux session via libssh2.
 */
internal class TabbedMux.TMuxSshStream : TMuxStream {
	Socket socket;
	SSH2.Session session;
	SSH2.Channel channel;
	StringBuilder buffer = new StringBuilder ();

	public string host {
		get; private set;
	}
	public uint16 port {
		get; private set;
	}
	public string username {
		get; private set;
	}

	internal TMuxSshStream (string session_name, string host, uint16 port, string username, string binary, Socket socket, owned SSH2.Session session, owned SSH2.Channel channel) {
		base (port == 22 ? @"$(username)@$(host) $(binary)" : @"$(username)@$(host):$(port) $(binary)", session_name, binary);
		this.session = (owned) session;
		this.channel = (owned) channel;
		this.socket = socket;
		this.host = host;
		this.port = port;
		this.username = username;
	}

	~TMuxSshStream () {
		/* To make libssh happy, the channel must be destroyed before the session, synchronously. */
		session.blocking = true;
		channel = null;
		session = null;
	}

	/**
	 * Read from the remote TMux instance via a non-blocking libssh2 socket.
	 */
	protected override async string? read_line_async (Cancellable cancellable) throws Error {
		/* If we've been told to stop, stop. */
		if (cancellable.is_cancelled ()) {
			return null;
		}
		uint8 data[1024];
		int new_line;
		/* Read and append to a StringBuilder until we have a line. */
		while ((new_line = search_buffer (buffer)) < 0) {

			/* Perform an obligatory SSH keep-alive.  */
			int seconds_to_next;
			if (session.send_keep_alive (out seconds_to_next) != SSH2.Error.NONE) {
				return throw_channel_error (true);
			}
			ssize_t result = 0;
			var err = yield ssh_wait_glue<bool> (session, socket, () => { result = channel.read (data); return result > 0 ? SSH2.Error.NONE : (SSH2.Error)result; }, cancellable, seconds_to_next);
			if (cancellable.is_cancelled ()) {
				return null;
			}

			switch (err) {
			 case SSH2.Error.NONE :
				 /* Stuff any data into our buffer. */
				 buffer.append_len ((string) data, result);
				 break;

			 case SSH2.Error.SOCKET_RECV:
				 /* Some error in the underlying socket. */
				 int no = errno;
				 critical ("%s:%s: %s", name, session_name, strerror (no));
				 throw_errno (no);

			 default:
				 /* Some other SSH error to complain about. */
				 return throw_channel_error (result < 0);
			}
		}
		/* Take the whole line from the buffer and return it. */
		var str = buffer.str[0 : new_line];
		buffer.erase (0, new_line + 1);
		return str;
	}

	private string? throw_channel_error (bool check_message = false) throws IOError {
		char[]? error_message = null;
		if (check_message) {
			session.get_last_error (out error_message);
			critical ("%s:%s: %s", name, session_name, (string) error_message);
		}
		if (channel.eof () != 0 && channel.wait_closed () != SSH2.Error.NONE) {
			throw new IOError.CLOSED (@"Unable to close channel.");
		}
		if (error_message != null) {
			throw new IOError.FAILED ((string) error_message);
		}
		if (channel.exit_status > 0) {
			throw new IOError.CLOSED (@"Remote TMux terminated with $(channel.exit_status).");
		}
		char[]? signal_name;
		char[]? language_tag;
		if (channel.get_exit_signal (out signal_name, out error_message, out language_tag) == SSH2.Error.NONE && signal_name != null) {
			throw new IOError.CLOSED (@"Remote TMux caught signal $((string) signal_name).");
		}
		return null;
	}

	protected override void write (uint8[] data) throws IOError {
		/* To make life remote sane, writes are blocking while reads are non-blocking. In theory, we shouldn't block in the Gtk+ thread, but we write sufficiently little data that the writes complete immediately and this simplifies the code. */
		session.blocking = true;
		var result = channel.write (data);
		session.blocking = false;
		if (result != data.length) {
			char[] error_message;
			session.get_last_error (out error_message);
			critical ("%s:%s: %s", name, session_name, (string) error_message);
			throw new IOError.FAILED ((string) error_message);
		}
	}

	/**
	 * Perform public key authentication using all the SSH keys in the agent and the file in the user's home directory.
	 */
	private static async bool do_public_key_auth<T> (Socket socket, SSH2.Session session, string username, string host, uint16 port, Cancellable cancellable, InteractiveAuthentication get_password) {
		var agent = session.create_agent ();
		if (agent != null && (yield ssh_wait_glue<T> (session, socket, () => ((!)agent).connect (), cancellable)) == SSH2.Error.NONE && (yield ssh_wait_glue<T> (session, socket, () => ((!)agent).list_identities (), cancellable)) == SSH2.Error.NONE) {
			unowned SSH2.AgentKey? key = null;
			while (((!)agent).next (out key, key) == SSH2.Error.NONE) {
				if ((yield ssh_wait_glue<T> (session, socket, () => ((!)agent).user_auth (username, (!)key), cancellable)) == SSH2.Error.NONE) {
					message ("Authentication succeeded for %s@%s:%hu with public key %s.", username, host, port, ((!)key).comment ?? "unknown");
					return true;
				} else {
					message ("Authentication failed for %s@%s:%hu with public key %s.", username, host, port, ((!)key).comment ?? "unknown");
				}
			}
		} else {
			char[] error_message;
			session.get_last_error (out error_message);
			warning ("Failed to communicate with ssh-agent: %s", (string) error_message);
		}
		var attempts = 0;
		string password = null;
		SSH2.Error result;
		while ((result = yield ssh_wait_glue<T> (session, socket, () => session.auth_publickey_from_file (username, @"$(Environment.get_home_dir())/.ssh/id_rsa.pub", @"$(Environment.get_home_dir())/.ssh/id_rsa", null), cancellable)) == SSH2.Error.PUBLICKEY_UNVERIFIED && attempts <= 3 && get_password != null) {
			password = password_simple ("Unlock private key:", (!)get_password);
			attempts++;
		}
		return result == SSH2.Error.NONE;
	}

	/* see password_adapter.c */
	public delegate void InteractiveAuthentication (string instruction, SSH2.keyboard_prompt[] prompts, SSH2.keyboard_response[] responses);
	private static extern SSH2.Error password_adapter (SSH2.Session session, string username, InteractiveAuthentication handler);
	private static extern string? password_simple (string banner, InteractiveAuthentication handler);

	/**
	 * Attempt to open an SSH connection and talk to TMux on that host.
	 */
	public async static TMuxStream? open (string session_name, string host, uint16 port, string username, string binary, InteractiveAuthentication? get_password, BusyDialog busy_dialog) throws Error {
		var session = SSH2.Session.create<bool> ();

		session.set_disconnect_handler ((session, reason, msg, language, ref user_data) => message ("Disconnect: %s", (string) msg));

		/*
		 * Create a GIO socket for that host. We do this so we can use async methods on it.
		 */
		busy_dialog.message = @"Connecting to '$(session_name) on $(username)@$(host):$(port)...";
		var client = new SocketClient ();
		var connection = yield client.connect_to_host_async (host, port);

		/*
		 * Tell libssh2 to do the handshake.
		 */
		busy_dialog.message = @"Handshaking '$(session_name) on $(username)@$(host):$(port)...";
		if ((yield ssh_wait_glue<bool> (session, connection.socket, () => session.handshake (connection.socket.fd), busy_dialog.cancellable)) != SSH2.Error.NONE) {
			char[] error_message;
			session.get_last_error (out error_message);
			throw new IOError.INVALID_DATA ((string) error_message);
		}

		/* List the know hosts */
		var known_hosts = session.get_known_hosts ();
		if (known_hosts == null) {
			throw_session_error<bool> (session);
		}
		switch (known_hosts.read_file (@"$(Environment.get_home_dir ())/.ssh/known_hosts")) {
		 case SSH2.Error.NONE :
			 SSH2.KeyType type;
			 var key = session.get_host_key (out type);
			 unowned SSH2.Host? known;
			 switch (known_hosts.checkp (host, port, key,  SSH2.HostFormat.TYPE_PLAIN | SSH2.HostFormat.KEYENC_RAW, out known)) {
			  case SSH2.CheckResult.MATCH :
				  break;

			  case SSH2.CheckResult.MISMATCH :
				  var mismatch_dialog = new Gtk.Dialog.with_buttons ("SSH Host Key - TabbedMux", busy_dialog, Gtk.DialogFlags.MODAL, "Proceed Anyway", Gtk.ButtonsType.OK, "Stop Immediately", Gtk.ButtonsType.CANCEL);
				  if (!run_host_key_dialog<bool> (mismatch_dialog, "KEY MISTMATCH!!! POSSIBLE ATTACK!!!", session, host, port)) {
					  return null;
				  }
				  mismatch_dialog.destroy ();
				  break;

			  case SSH2.CheckResult.NOTFOUND :
				  //TODO allow add
				  var unknown_dialog = new Gtk.Dialog.with_buttons ("SSH Host Key - TabbedMux", busy_dialog, Gtk.DialogFlags.MODAL, "Accept Once", Gtk.ButtonsType.OK, "Cancel", Gtk.ButtonsType.CANCEL);
				  if (!run_host_key_dialog<bool> (unknown_dialog, "Unknown host.", session, host, port)) {
					  return null;
				  }
				  break;

			  case SSH2.CheckResult.FAILURE :
				  var fail_dialog = new Gtk.Dialog.with_buttons ("SSH Host Key - TabbedMux", busy_dialog, Gtk.DialogFlags.MODAL, "Accept Once", Gtk.ButtonsType.OK, "Cancel", Gtk.ButtonsType.CANCEL);
				  if (!run_host_key_dialog<bool> (fail_dialog, "Failed to check for public key.", session, host, port)) {
					  return null;
				  }
				  break;
			 }
			 break;

		 case SSH2.Error.FILE :
		 case SSH2.Error.METHOD_NOT_SUPPORTED :
		 case SSH2.Error.KNOWN_HOSTS :
			 //TODO allow add
			 var no_file_dialog = new Gtk.Dialog.with_buttons ("SSH Host Key - TabbedMux", busy_dialog, Gtk.DialogFlags.MODAL, "Accept Once", Gtk.ButtonsType.OK, "Cancel", Gtk.ButtonsType.CANCEL);
			 if (!run_host_key_dialog<bool> (no_file_dialog, "No database of known hosts.", session, host, port)) {
				 return null;
			 }
			 break;

		 default :
			 throw_session_error<bool> (session);
			 break;
		}
		/*
		 * Try to authenticate.
		 */
		unowned string? auth_methods = null;

		busy_dialog.message = @"Getting authentication methods for '$(session_name) on $(username)@$(host):$(port)...";
		if ((yield ssh_wait_glue<bool> (session, connection.socket, () => {
							auth_methods = session.list_authentication (username.data);
							return auth_methods == null ? session.last_error : SSH2.Error.NONE;
						}, busy_dialog.cancellable)) != SSH2.Error.NONE) {
			throw_session_error<bool> (session);
		}
		if (auth_methods == null) {
			throw new IOError.PERMISSION_DENIED ("No authentication mechanism provided.");
		}
		foreach (var method in auth_methods.split (",")) {
			if (session.authenticated) {
				break;
			}
			switch (method) {
			 case "publickey" :
				 busy_dialog.message = @"Trying public key authentication for '$(session_name) on $(username)@$(host):$(port)...";
				 yield do_public_key_auth<bool> (connection.socket, session, username, host, port, busy_dialog.cancellable, get_password);
				 break;

			 case "keyboard-interactive" :
				 if (get_password == null) {
					 break;
				 }
				 busy_dialog.message = @"Trying interactive authentication for '$(session_name) on $(username)@$(host):$(port)...";
				 switch (yield ssh_wait_glue<bool> (session, connection.socket, () => password_adapter (session, username, (!)get_password), busy_dialog.cancellable)) {
				  case SSH2.Error.NONE :
				  case SSH2.Error.AUTHENTICATION_FAILED :
					  break;

				  default :
					  throw_session_error<bool> (session);
					  break;
				 }
				 break;

			 case "password":
				 if (get_password == null) {
					 break;
				 }
				 busy_dialog.message = @"Trying password authentication for '$(session_name) on $(username)@$(host):$(port)...";
				 var password = password_simple ("Enter password:", (!)get_password);
				 if (password == null) {
					 break;
				 }
				 switch (yield ssh_wait_glue<bool> (session, connection.socket, () => session.auth_password (username, (!)password), busy_dialog.cancellable)) {
				  case SSH2.Error.NONE:
					  message ("%s@%s:%d:%s: Password succeeded.", username, host, port, session_name);
					  break;

				  case SSH2.Error.AUTHENTICATION_FAILED:
					  message ("%s@%s:%d:%s: Password failed.", username, host, port, session_name);
					  break;

				  default:
					  throw_session_error<bool> (session);
					  break;
				 }
				 break;

			 default:
				 message ("%s@%s:%d:%s: Skipping unknown authentication method: %s", username, host, port, session_name, method);
				 break;
			}
		}
		if (!session.authenticated) {
			throw new IOError.PERMISSION_DENIED ("Could not authenticate.");
		}
		/*
		 * Try to exec tmux in a shell on the remote end.
		 */
		busy_dialog.message = @"Starting TMux on '$(session_name) on $(username)@$(host):$(port)...";
		SSH2.Channel? channel = null;
		if ((yield ssh_wait_glue<bool> (session, connection.socket, () => { channel = session.open_channel (); return channel == null ? session.last_error : SSH2.Error.NONE; }, busy_dialog.cancellable)) != SSH2.Error.NONE) {
			throw_session_error<bool> (session);
		}
		var command = @"TERM=$(TERM_TYPE) $(Shell.quote (binary)) -u -C new -A -s $(Shell.quote (session_name))";
		message ("%s@%s:%d:%s: executing %s", username, host, port, session_name, command);
		if ((yield ssh_wait_glue<bool> (session, connection.socket, () => ((!)channel).start_command (command), busy_dialog.cancellable)) != SSH2.Error.NONE) {
			throw_session_error<bool> (session);
		}
		/*
		 * Create an Stream and return it.
		 */
		session.set_keep_alive (true, 10);
		return new TMuxSshStream (session_name, host, port, username, binary, connection.socket, (!)(owned) session, (!)(owned) channel);
	}
	private delegate SSH2.Error SshEventHandler ();
	/**
	 * Glue libssh2 to GLib's event loop.
	 *
	 * If there is either no data or reading would block,
	 * Take our current continuation and make it the callback for data being
	 * present in the underlying GIO socket (libssh2 isn't helpful here) and put
	 * it in the dispatch loop, then wait.
	 */
	private static async SSH2.Error ssh_wait_glue<T> (SSH2.Session<T> session, Socket socket, SshEventHandler handler, Cancellable? cancellable = null, int seconds_to_next = 0) {
		SSH2.Error result;
		SocketSource? source = null;
		/* Perform a non-blocking read-ish operation using libssh2. */
		session.blocking = false;
		while ((result = handler ()) == SSH2.Error.AGAIN) {
			if (source != null) {
				warning ("SSH somehow re-entered an active asynchronous callback.");
			}
			SourceFunc async_continue = ssh_wait_glue.callback;
			source = socket.create_source (IOCondition.IN, cancellable);
			((!)source).set_callback ((socket, condition) => { async_continue (); return false; });
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
		return result;
	}
	private static void throw_session_error<T> (SSH2.Session<T> session) throws IOError {
		char[] error_message;
		session.get_last_error (out error_message);
		throw new IOError.INVALID_DATA ((string) error_message);
	}
	private static bool run_host_key_dialog<T> (Gtk.Dialog dialog, string message, SSH2.Session<T> session, string host, uint16 port) {
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
		var result = dialog.run () != Gtk.ButtonsType.CANCEL;
		dialog.destroy ();
		return result;
	}
}
namespace TabbedMux {
	private static extern int search_buffer (StringBuilder buffer);
	[NoReturn]
	private static extern void throw_errno (int err_number) throws IOError;
}
