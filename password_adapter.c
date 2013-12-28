#include<glib.h>
#include<libssh2.h>
#include<string.h>

typedef gchar **(
	*SshMuxTMuxSshStreamInteractiveAuthentication) (
	const gchar * username,
	const gchar * instruction,
	gchar ** prompts,
	int prompts_length1,
	int *result_length1,
	void *user_data);

struct delegate_data {
	SshMuxTMuxSshStreamInteractiveAuthentication handler;
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
	gchar **str_responses;
	int response_length;
	gchar **str_prompts;
	int it;

	str_prompts = g_new(char *,
		name_len);
	for (it = 0; it < num_prompts; it++) {
		str_prompts[it] = prompts[it].text;
	}
	*abstract = data->original_abstract;
	str_responses = data->handler(name, instruction, str_prompts, num_prompts, &response_length, data->handler_target);
	*abstract = data;
	for (it = 0; it < response_length; it++) {
		responses[it].text = str_responses[it];
		responses[it].length = strlen(str_responses[it]);
	}
	for (it = response_length; it < num_prompts; it++) {
		responses[it].text = NULL;
		responses[it].length = 0;
	}
	g_free(str_prompts);
	g_free(str_responses);
}

int ssh_mux_tmux_ssh_stream_password_adapter(
	LIBSSH2_SESSION * session,
	const gchar * username,
	SshMuxTMuxSshStreamInteractiveAuthentication handler,
	void *handler_target) {
	void **abstract;
	int result;
	struct delegate_data data;
	data.original_abstract = *abstract;
	*abstract = &data;
	data.handler = handler;
	data.handler_target = handler_target;

	result = libssh2_userauth_keyboard_interactive(session, username, response_callback);
	*abstract = data.original_abstract;
}
