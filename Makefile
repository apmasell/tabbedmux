sshmux: sshmux.vala
	valac --save-temps --pkg gtk+-3.0 --pkg gee-0.8 --pkg gio-unix-2.0 --pkg vte-2.90 $< -o $@
