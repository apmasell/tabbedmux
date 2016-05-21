NULL = 
PREFIX ?= /usr
DESTDIR ?= 
G_SCHEMA_COMPILER ?= glib-compile-schemas

SOURCES = \
	application.vala \
	contextmenu.vala \
	keyboard_interactive.vala \
	misc.c \
	open.vala \
	password_adapter.c \
	resources.c \
	saved_sessions.vala \
	tabbedmux.vala \
	terminal.vala \
	tmux_decode.c \
	tmux_decode.vapi \
	tmux_local.vala \
	tmux_manager.vala \
	tmux_ssh.vala \
	util.vala \
	window.vala \
	version.vapi \
	$(NULL)

VALA_PKGS = \
	--pkg gee-0.8 \
	--pkg gio-unix-2.0 \
	--pkg gtk+-3.0 \
	--pkg libnotify \
	--pkg libssh2 \
	--pkg tcpmisc \
	--pkg vte-2.91 \
	$(NULL)

tabbedmux: $(SOURCES) version.h
	valac \
		--debug \
		--gresources resources.xml \
		--save-temps \
		--target-glib=2.38 \
		--vapidir vapis \
		--vapidir . \
		$(VALA_PKGS) $^ -o $@

GLIB_COMPILE_RESOURCES=glib-compile-resources

resources.c: resources.xml $(shell $(GLIB_COMPILE_RESOURCES) --generate-dependencies resources.xml)
	$(GLIB_COMPILE_RESOURCES) --target=$@  --generate-source $<

ifeq (,$(wildcard .git))
version.h: debian/control
	dpkg-parsechangelog | awk -F':|~' '/Version/ { print "#define TABBED_MUX_VERSION \"" $$2 "\"" }' > $@
else
version.h: $(wildcard .git/refs/tags/*)
	git for-each-ref refs/tags --sort=-authordate --format='#define TABBED_MUX_VERSION "%(refname:short)"' --count=1 > $@
endif

clean:
	rm -f $(patsubst %.vala, %.c, $(filter %.vala, $(SOURCES))) resources.c tabbedmux

install:
	install -D tabbedmux $(DESTDIR)$(PREFIX)/bin/tabbedmux
	install -d $(DESTDIR)$(PREFIX)/share/applications
	install tabbedmux.desktop $(DESTDIR)$(PREFIX)/share/applications
	install -d $(DESTDIR)$(PREFIX)/share/glib-2.0/schemas
	install name.masella.tabbedmux.gschema.xml $(DESTDIR)$(PREFIX)/share/glib-2.0/schemas
	$(G_SCHEMA_COMPILER) $(DESTDIR)$(PREFIX)/share/glib-2.0/schemas

.PHONY: clean  install
