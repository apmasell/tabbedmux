#include <glib.h>
#include <gio/gio.h>
#include <string.h>

gchar *tabbed_mux_strip(
	const gchar *input) {
	gchar *copy = g_strdup(input);
	return g_strstrip(copy);
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
