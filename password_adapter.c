#include<glib.h>
#include<libssh2.h>
#include<string.h>

typedef void (
	*TabbedMuxTMuxSshStreamInteractiveAuthentication) (
	const gchar * username,
	const gchar * instruction,
	const LIBSSH2_USERAUTH_KBDINT_PROMPT * prompts,
	int prompts_length,
	LIBSSH2_USERAUTH_KBDINT_RESPONSE * responses,
	int responses_length,
	void *user_data);

struct delegate_data {
	TabbedMuxTMuxSshStreamInteractiveAuthentication handler;
	void *handler_target;
	void *original_abstract;
};

void response_callback(
	const char *name,
	int name_len,
	const char *instruction,
	int instruction_len,
	int num_prompts,
	const LIBSSH2_USERAUTH_KBDINT_PROMPT * prompts,
	LIBSSH2_USERAUTH_KBDINT_RESPONSE * responses,
	void **abstract) {

	struct delegate_data *data = *abstract;

	*abstract = data->original_abstract;
	data->handler(name, instruction, prompts, num_prompts, responses, num_prompts, data->handler_target);
	*abstract = data;
}

/*
 * libssh's interface only allows passing data through the abstract pointer attached to a session and GLib expects to be able to pass a context with the function pointer. This function mediates between the two by taking the context from Vala, shoving it into the session's abstract, has libssh do the above callback, when it rips the data back out of abstract and call the Vala handler.
 */
int tabbed_mux_tmux_ssh_stream_password_adapter(
	LIBSSH2_SESSION * session,
	const gchar * username,
	TabbedMuxTMuxSshStreamInteractiveAuthentication handler,
	void *handler_target) {
	void **abstract;
	int result;
	struct delegate_data data;

	abstract = libssh2_session_abstract(session);

	data.original_abstract = *abstract;
	*abstract = &data;
	data.handler = handler;
	data.handler_target = handler_target;

	result = libssh2_userauth_keyboard_interactive(session, username, response_callback);
	*abstract = data.original_abstract;
	return result;
}

/*
 * Since we've already got a thing for keyboard interactive, make simple passwords just call the keyboard interactive handler.
 */
int tabbed_mux_tmux_ssh_stream_password_simple(
	LIBSSH2_SESSION * session,
	const gchar * username,
	TabbedMuxTMuxSshStreamInteractiveAuthentication handler,
	void *handler_target) {

	LIBSSH2_USERAUTH_KBDINT_PROMPT prompt;
	LIBSSH2_USERAUTH_KBDINT_RESPONSE response;
	int result;

	prompt.text = "Password:";
	prompt.length = strlen(prompt.text);
	prompt.echo = 0;
	response.text = NULL;
	response.length = 0;

	handler(username, "Enter password.", &prompt, 1, &response, 1, handler_target);

	result = libssh2_userauth_password(session, username, response.text == NULL ? "" : response.text);
	g_free(response.text);
	return result;
}
