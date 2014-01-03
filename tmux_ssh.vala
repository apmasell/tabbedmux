namespace SshMux {
	internal class TMuxSshStream : TMuxStream {
		Socket socket;
		SSH2.Session session;
		SSH2.Channel channel;
		SocketSource? source = null;
		StringBuilder buffer = new StringBuilder ();
		internal TMuxSshStream (string name, string session_name, Socket socket, owned SSH2.Session session, owned SSH2.Channel channel) {
			base (name, session_name);
			this.session = (owned) session;
			this.channel = (owned) channel;
			this.socket = socket;
		}

		~TMuxSshStream () {
			channel = null;
			session = null;
		}

		protected override async string? read_line_async (Cancellable cancellable) throws Error {
			if (cancellable.is_cancelled ()) {
				return null;
			}
			uint8 data[1024];
			while (!("\n" in buffer.str)) {
				session.blocking = false;
				var result = channel.read (data);
				if (result > 0) {
					buffer.append_len ((string) data, result);
				} else if ((SSH2.Error)result == SSH2.Error.AGAIN || result == 0) {
					SourceFunc async_continue = read_line_async.callback;
					source = socket.create_source (IOCondition.IN, cancellable);
					source.set_callback ((socket, condition) => { async_continue (); return false; });
					source.attach (MainContext.default ());
					yield;
				} else if ((SSH2.Error)result == SSH2.Error.SOCKET_RECV) {
					critical ("%s:%s: %s", name, session_name, strerror (errno));
					return null;
				} else if (result < 0) {
					char[] error_message;
					session.get_last_error (out error_message);
					critical ("%s:%s: %zd %s", name, session_name, result, (string) error_message);
					if (channel.eof () != 0 && channel.wait_closed () != SSH2.Error.NONE) {
						throw new IOError.CLOSED (@"Remote TMux terminated with $(channel.exit_status).");
					}
					return null;
				}
			}
			var new_line = buffer.str.index_of_char ('\n');
			var str = buffer.str[0 : new_line];
			buffer.erase (0, new_line + 1);
			return str;
		}

		protected override void write (uint8[] data) throws IOError {
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

		private static bool do_public_key_auth (SSH2.Session connection, string username, string host, uint16 port) {
			var agent = connection.create_agent ();
			if (agent != null && agent.list_identities () != SSH2.Error.NONE) {
				unowned SSH2.AgentKey? key = null;
				while (agent.next (out key, key) == SSH2.Error.NONE) {
					if (agent.user_auth (username, key) == SSH2.Error.NONE) {
						message ("Authentication succeeded for %s@%s:%hu with %s.", username, host, port, key.comment);
						return true;
					} else {
						message ("Authentication failed for %s@%s:%hu with %s.", username, host, port, key.comment);
					}
				}
			} else {
				warning ("Failed to communicate with ssh-agent.");
			}
			return connection.auth_publickey_from_file (username, @"$(Environment.get_home_dir())/.ssh/id_rsa.pub", @"$(Environment.get_home_dir())/.ssh/id_rsa", null) == SSH2.Error.NONE;
		}

		public delegate void InteractiveAuthentication (string username, string instruction, SSH2.keyboard_prompt[] prompts, SSH2.keyboard_response[] responses);
		private static extern SSH2.Error password_adapter (SSH2.Session session, string username, InteractiveAuthentication handler);
		private static extern SSH2.Error password_simple (SSH2.Session session, string username, InteractiveAuthentication handler);

		public static TMuxStream? open (string session_name, string host, uint16 port, string username, InteractiveAuthentication? get_password) throws Error {
			var session = SSH2.Session.create<bool> ();

			var resolver = Resolver.get_default ();
			var addresses = resolver.lookup_by_name (host);
			if (addresses.length () == 0) {
				throw new IOError.HOST_NOT_FOUND ("Host not found.");
			}
			var address = addresses.data;
			var inetaddress = new InetSocketAddress (address, port);
			var socket = new Socket (address.family, SocketType.STREAM, SocketProtocol.TCP);
			socket.connect (inetaddress);
			if (session.handshake (socket.fd) != SSH2.Error.NONE) {
				char[] error_message;
				session.get_last_error (out error_message);
				throw new IOError.INVALID_DATA ((string) error_message);
			}
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
						 password_adapter (session, username, get_password);
					 }
					 break;

				 case "password" :
					 if (get_password != null) {
						 password_simple (session, username, get_password);
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
			var channel = session.open_channel ();
			if (channel == null) {
				char[] error_message;
				session.get_last_error (out error_message);
				throw new IOError.INVALID_DATA ((string) error_message);
			}
			var command = @"TERM=$(TERM_TYPE) tmux -C new -A -s $(Shell.quote(session_name))";
			message ("%s@%s:%d:%s: executing %s", username, host, port, session_name, command);
			if (channel.start_command (command) != SSH2.Error.NONE) {
				char[] error_message;
				session.get_last_error (out error_message);
				throw new IOError.INVALID_DATA ((string) error_message);
			}
			session.blocking = false;
			var name = port == 22 ? @"$(username)@$(host)" : @"$(username)@$(host):$(port)";
			return new TMuxSshStream (name, session_name, socket, (owned) session, (owned) channel);
		}
	}
}
