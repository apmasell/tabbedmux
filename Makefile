sshmux: sshmux.vala resources.c
	valac -v --save-temps --pkg gtk+-3.0 --pkg gee-0.8 --pkg gio-unix-2.0 --pkg vte-2.90 $^ --gresources resources.gresource -o $@

GLIB_COMPILE_RESOURCES=glib-compile-resources

resources.c: resources.xml $(shell $(GLIB_COMPILE_RESOURCES) --generate-dependencies resources.xml)
	$(GLIB_COMPILE_RESOURCES) --target=$@  --generate-source $<
