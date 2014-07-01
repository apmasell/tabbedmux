#ifndef TMUX_DECODE_H
#        define TMUX_DECODE_H
#        include <glib.h>

struct tabbed_mux_decoder {
	char *str;
	char *rest;
	char split;
};

void tabbed_mux_decoder_init(
	struct tabbed_mux_decoder *self,
	char *str,
	gboolean command,
	gchar split);
void tabbed_mux_decoder_destroy(
	struct tabbed_mux_decoder *self);

void tabbed_mux_decoder_pop(
	struct tabbed_mux_decoder *self);

int tabbed_mux_decoder_pop_id(
	struct tabbed_mux_decoder *self);

char *tabbed_mux_decoder_get_command(
	struct tabbed_mux_decoder *self);

char *tabbed_mux_decoder_get_remainder(
	struct tabbed_mux_decoder *self);

#endif
