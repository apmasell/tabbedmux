#include <glib.h>
#include <string.h>
#include <stdio.h>

gchar *tabbed_mux_strip(
	const gchar *input) {
	gchar *copy = g_strdup(input);
	return g_strstrip(copy);
}
