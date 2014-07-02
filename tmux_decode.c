#include <string.h>
#include "tmux_decode.h"

void tabbed_mux_decoder_init(
	struct tabbed_mux_decoder *self,
	char *str,
	gboolean command,
	gchar split) {
	self->str = str;
	self->split = split;
	if (command) {
		self->rest = index(str, self->split);
		if (self->rest != NULL) {
			*self->rest = '\0';
			self->rest++;
		}
	} else {
		self->rest = str;
	}
}

void tabbed_mux_decoder_destroy(
	struct tabbed_mux_decoder *self) {
	g_free(self->str);
}

void tabbed_mux_decoder_pop(
	struct tabbed_mux_decoder *self) {
	if (self->rest == NULL) {
		return;
	}
	for (; *self->rest != self->split; self->rest++) ;
	if (*self->rest == self->split) {
		self->rest++;
	}
}

int tabbed_mux_decoder_pop_id(
	struct tabbed_mux_decoder *self) {
	gchar *end;
	gint result;

	if (self->rest[0] == '@' || self->rest[0] == '%') {
		self->rest++;
	}
	result = strtol(self->rest, &end, 10);
	if (end == self->rest) {
		g_warning("Could not parse window ID from \"%s\".", self->rest);
	}
	if (*end == self->split) {
		end++;
	}
	self->rest = (*end == '\0') ? NULL : end;
	return result;
}

char *tabbed_mux_decoder_get_command(
	struct tabbed_mux_decoder *self) {
	return self->str;
}

char *tabbed_mux_decoder_get_remainder(
	struct tabbed_mux_decoder *self) {
	const gchar *num_start;
	gchar *dest;
	gchar *p = self->rest;
	gchar *q;
	gint it;

	if (self->rest == NULL) {
		return NULL;
	}

	q = dest = g_malloc(strlen(self->rest) + 1);

	while (*p != '\0') {
		if (*p == '\\') {
			p++;
			switch (*p) {
			case '\0':
				*q++ = '\\';
				break;
			case '0':
			case '1':
			case '2':
			case '3':
			case '4':
			case '5':
			case '6':
			case '7':
				*q = 0;
				num_start = p;
				while ((p < num_start + 3) && (*p >= '0') && (*p <= '7')) {
					*q = (*q * 8) + (*p - '0');
					p++;
				}
				if (*q >= ' ' && *q != '\\') {
					*q++ = '\\';
					*q++ = p[-3];
					*q++ = p[-2];
					*q++ = p[-1];
				} else {
					q++;
				}
				break;
			default:
				g_warning("unrecognised escape sequence: %c", *p);
			}
		} else {
			*q++ = *p++;
		}
	}
	*q = '\0';
	return dest;
}
