namespace TabbedMux {
	[CCode (cname = "struct tabbed_mux_decoder", destroy_function = "tabbed_mux_decoder_destroy", cheader_filename = "tmux_decode.h")]
	public struct Decoder {
		[CCode (cname = "tabbed_mux_decoder_init")]
		public Decoder (owned string str, bool command = true, char split = ' ');

		[CCode (cname = "tabbed_mux_decoder_pop")]
		public void pop ();
		[CCode (cname = "tabbed_mux_decoder_pop_id")]
		public int pop_id ();

		public string? command {
			[CCode (cname = "tabbed_mux_decoder_get_command")]
			get;
		}

		[CCode (cname = "tabbed_mux_decoder_get_remainder")]
		public string? get_remainder ();
	}
}
