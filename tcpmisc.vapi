[CCode (cheader_filename = "netinet/in.h")]
public const int IPPROTO_TCP;
[CCode (cheader_filename = "netinet/tcp.h")]
public const int TCP_NODELAY;

public ssize_t g_pollable_output_stream_write_nonblocking (GLib.PollableOutputStream stream, [CCode (array_length_cname = "count", array_length_pos = 2.1, array_length_type = "gsize")] uint8[] buffer, GLib.Cancellable? cancellable = null) throws GLib.Error;
