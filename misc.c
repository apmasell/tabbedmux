#include <glib.h>
#include <gio/gio.h>
#include <string.h>

/**
 * Const-safe wrapper around g_strstrip.
 */
gchar *tabbed_mux_strip(
	const gchar *input) {
	gchar *copy = g_strdup(input);
	return g_strstrip(copy);
}

/**
 * Find the offset of the first newline in a GString.
 */
gint tabbed_mux_search_buffer(
	GString *buffer) {
	void *end;

	end = memchr(buffer->str, '\n', buffer->len);
	if (end == NULL) {
		return -1;
	} else {
		return (gchar *) end - buffer->str;
	}
}

/**
 * Continue the current asynchronous task when idle.
 *
 * Since we can get blasted with data from the other end (e.g., cat
 * /dev/urandom), the GUI will freeze up. This causes the current async task to
 * wait until idle. That means the GUI can update and get events from the
 * underlying system.
 */
void tabbed_mux_wait_idle(
	GAsyncReadyCallback _callback_,
	gpointer _user_data_) {
	GSimpleAsyncResult *async;
	async = g_simple_async_result_new(NULL, _callback_, _user_data_, tabbed_mux_wait_idle);
	g_simple_async_result_complete_in_idle(async);
}

void tabbed_mux_wait_idle_finish(
	GAsyncResult *async) {
	g_object_unref(G_OBJECT(async));
}
