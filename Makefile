NULL = 
PREFIX ?= /usr
DESTDIR ?= 

SOURCES = \
	application.vala \
	keyboard_interactive.vala \
	misc.c \
	open.vala \
	password_adapter.c \
	resources.c \
	saved_sessions.vala \
	tabbedmux.vala \
	terminal.vala \
	tmux_local.vala \
	tmux_manager.vala \
	tmux_ssh.vala \
	util.vala \
	window.vala \
	$(NULL)

tabbedmux: $(SOURCES)
	valac -v --debug --target-glib=2.38 --save-temps --vapidir vapis --pkg libssh2 --pkg gtk+-3.0 --pkg gee-0.8 --pkg gio-unix-2.0 --pkg libnotify --pkg vte-2.90 $^ --gresources resources.xml -o $@

GLIB_COMPILE_RESOURCES=glib-compile-resources

resources.c: resources.xml $(shell $(GLIB_COMPILE_RESOURCES) --generate-dependencies resources.xml)
	$(GLIB_COMPILE_RESOURCES) --target=$@  --generate-source $<

clean:
	rm -f $(patsubst %.vala, %.c, $(filter %.vala, $(SOURCES))) resources.c tabbedmux

install:
	install -D tabbedmux $(DESTDIR)$(PREFIX)/bin/tabbedmux
	install -d $(DESTDIR)$(PREFIX)/share/applications
	install tabbedmux.desktop $(DESTDIR)$(PREFIX)/share/applications
	install -d $(DESTDIR)$(PREFIX)/share/glib-2.0/schemas
	install name.masella.tabbedmux.gschema.xml $(DESTDIR)$(PREFIX)/share/glib-2.0/schemas
	glib-compile-schemas $(DESTDIR)$(PREFIX)/share/glib-2.0/schemas

.PHONY: clean  install
