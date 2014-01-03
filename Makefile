NULL = 

SOURCES = \
	application.vala \
	keyboard_interactive.vala \
	open.vala \
	password_adapter.c \
	resources.c \
	sshmux.vala \
	open.vala \
	terminal.vala \
	tmux_local.vala \
	tmux_manager.vala \
	tmux_ssh.vala \
	window.vala \
	$(NULL)

sshmux: $(SOURCES)
	valac -v --debug --target-glib=2.38 --save-temps --vapidir vapi --pkg libssh2 --pkg gtk+-3.0 --pkg gee-0.8 --pkg gio-unix-2.0 --pkg libnotify --pkg vte-2.90 $^ --gresources resources.xml -o $@

GLIB_COMPILE_RESOURCES=glib-compile-resources

resources.c: resources.xml $(shell $(GLIB_COMPILE_RESOURCES) --generate-dependencies resources.xml)
	$(GLIB_COMPILE_RESOURCES) --target=$@  --generate-source $<
