/**
 * Access a TMux session via libssh2.
 */
internal class TabbedMux.TMuxSshStream : TMuxStream {
	Socket socket;
	SSH2.Session session;
	SSH2.Channel channel;
	SocketSource? source = null;
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
		/* To make libssh happy, the channel must be destroyed before the session. */
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
			/* Perform a non-blocking read using libssh2. */
			session.blocking = false;
			var result = channel.read (data);
			if (result > 0) {
				/* Stuff any data into our buffer. */
				buffer.append_len ((string) data, result);
			} else if ((SSH2.Error)result == SSH2.Error.AGAIN || result == 0 && channel.eof () != 1) {
				/* There is no data currently, so wait for the main loop to re-invoke us.

				   /* Perform an obligatory SSH keep-alive.  */
				int seconds_to_next;
				if (session.send_keep_alive (out seconds_to_next) < 0) {
					char[] error_message;
					session.get_last_error (out error_message);
					critical ("%s:%s: %zd %s", name, session_name, result, (string) error_message);
					if (channel.eof () != 0 && channel.wait_closed () != SSH2.Error.NONE) {
						throw new IOError.CLOSED (@"Remote TMux terminated with $(channel.exit_status).");
					}
					return null;
				}
				/*
				 * If there is either no data or reading would block,
				 * Take our current continuation and make it the callback for data being present in the underlying GIO socket (libssh2 isn't helpful here) and put it in the dispatch loop, then wait.
				 */
				if (source != null) {
					warning ("SSH somehow re-entered an active asynchronous callback.");
				}
				SourceFunc async_continue = read_line_async.callback;
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
				/* Once the socket has data, we will continue from this point. */
				if (cancellable.is_cancelled ()) {
					return null;
				}
			} else if ((SSH2.Error)result == SSH2.Error.SOCKET_RECV) {
				/* Some error in the underlying socket. */
				critical ("%s:%s: %s", name, session_name, strerror (errno));
				return null;
			} else if (result < 0) {
				/* Some other SSH error to complain about. */
				char[] error_message;
				session.get_last_error (out error_message);
				critical ("%s:%s: %zd %s", name, session_name, result, (string) error_message);
				if (channel.eof () != 0 && channel.wait_closed () != SSH2.Error.NONE) {
					throw new IOError.CLOSED (@"Remote TMux terminated with $(channel.exit_status).");
				}
				return null;
			} else if (channel.eof () == 1) {
				/* The channel is dead, probably because the remote process exited. */
				return null;
			} else {
				assert_not_reached ();
			}
		}
		/* Take the whole line from the buffer and return it. */
		var str = buffer.str[0 : new_line];
		buffer.erase (0, new_line + 1);
		return str;
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
	private static bool do_public_key_auth (SSH2.Session connection, string username, string host, uint16 port) {
		var agent = connection.create_agent ();
		if (agent != null && ((!)agent).list_identities () != SSH2.Error.NONE) {
			unowned SSH2.AgentKey? key = null;
			while (((!)agent).next (out key, key) == SSH2.Error.NONE) {
				if (((!)agent).user_auth (username, (!)key) == SSH2.Error.NONE) {
					message ("Authentication succeeded for %s@%s:%hu with %s.", username, host, port, ((!)key).comment ?? "unknown");
					return true;
				} else {
					message ("Authentication failed for %s@%s:%hu with %s.", username, host, port, ((!)key).comment ?? "unknown");
				}
			}
		} else {
			warning ("Failed to communicate with ssh-agent.");
		}
		return connection.auth_publickey_from_file (username, @"$(Environment.get_home_dir())/.ssh/id_rsa.pub", @"$(Environment.get_home_dir())/.ssh/id_rsa", null) == SSH2.Error.NONE;
	}

	/* see password_adapter.c */
	public delegate void InteractiveAuthentication (string username, string instruction, SSH2.keyboard_prompt[] prompts, SSH2.keyboard_response[] responses);
	private static extern SSH2.Error password_adapter (SSH2.Session session, string username, InteractiveAuthentication handler);
	private static extern SSH2.Error password_simple (SSH2.Session session, string username, InteractiveAuthentication handler);

	/**
	 * Attempt to open an SSH connection and talk to TMux on that host.
	 */
	public static TMuxStream? open (string session_name, string host, uint16 port, string username, string binary, InteractiveAuthentication? get_password) throws Error {
		var session = SSH2.Session.create<bool> ();

		/*
		 * Find the host.
		 */
		var resolver = Resolver.get_default ();
		var addresses = resolver.lookup_by_name (host);
		if (addresses.length () == 0) {
			throw new IOError.HOST_NOT_FOUND ("Host not found.");
		}
		var address = addresses.data;
		var inetaddress = new InetSocketAddress (address, port);
		/*
		 * Create a GIO socket for that host. We do this so we can use async methods on it.
		 */
		var socket = new Socket (address.family, SocketType.STREAM, SocketProtocol.TCP);
		socket.connect (inetaddress);

		/*
		 * Tell libssh2 to do the handshake. This is blocking in the Gtk+ event thread.
		 */
		if (session.handshake (socket.fd) != SSH2.Error.NONE) {
			char[] error_message;
			session.get_last_error (out error_message);
			throw new IOError.INVALID_DATA ((string) error_message);
		}
		/*
		 * Try to authenticate.
		 */
		foreach (var method in session.list_authentication (username.data).split (",")) {
			if (session.authenticated) {
				break;
			}
			switch (method) {
			 case "publickey" :
				 do_public_key_auth (session, username, host, port);
				 break;

			 case "keyboard-interactive" :
				 if (get_password != null) {
					 password_adapter (session, username, (!)get_password);
				 }
				 break;

			 case "password" :
				 if (get_password != null) {
					 password_simple (session, username, (!)get_password);
				 }
				 break;

			 default :
				 message ("Skipping unknown authentication method: %s", method);
				 break;
			}
		}
		if (!session.authenticated) {
			return null;
		}
		/*
		 * Try to exec tmux in a shell on the remote end.
		 */
		var channel = session.open_channel ();
		if (channel == null) {
			char[] error_message;
			session.get_last_error (out error_message);
			throw new IOError.INVALID_DATA ((string) error_message);
		}
		var command = @"TERM=$(TERM_TYPE) $(Shell.quote (binary)) -u -C new -A -s $(Shell.quote (session_name))";
		message ("%s@%s:%d:%s: executing %s", username, host, port, session_name, command);
		if (((!)channel).start_command (command) != SSH2.Error.NONE) {
			char[] error_message;
			session.get_last_error (out error_message);
			throw new IOError.INVALID_DATA ((string) error_message);
		}
		/*
		 * Create an Stream and return it.
		 */
		session.blocking = false;
		session.set_keep_alive (true, 10);
		return new TMuxSshStream (session_name, host, port, username, binary, socket, (!)(owned) session, (!)(owned) channel);
	}
}
namespace TabbedMux {
	private static extern int search_buffer (StringBuilder buffer);
}
