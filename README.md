TabbedMux
=========

GNU Screen and TMux have become part of most users' work flow when using SSH to access remote systems as have tabbed GUI terminal emulators. Unfortunately, this leads to the situation of have many tabs open: some for the local machine and some for TMux sessions to remote system. Two problems arise:

  1. It's easy to start programs in local windows, then loose the ability to access them remotely later.

  2. Remote systems will often have many windows open, resulting in nested layers of windows (“windows” in tabs in windows).

TabbedMux connects to remote systems using SSH, starts TMux, and creates one tab in a GUI window for each TMux window that exists in the remote system. All the tabs from all the systems are promoted to a single layer (i.e., no nesting).

Note: window means two different things to Gtk+ and TMux. It's confusing. Sorry.

INSTALLATION
------------

For Ubuntu 14.04 or later:

    sudo apt-add-repository ppa:apmasell/ppa
    sudo apt-get update
    sudo apt-get install tabbedmux

For everyone else:

  1. Install the Vala compiler 0.22 or later.
  2. Install development headers for Gtk+ 3.10, Gee 0.8, Vte 2.91, libnotify, and libssh2 1.4, or newer versions.
  3. `make && sudo make install`
  4. Install tmux 1.8 or later on the local system and any remote systems you wish to access.

BUGS
----

The TMux library has an issue that can cause multiple sessions to blend together. Since most users don't use this feature, it's not a big deal. It's fixed after 1.9.

TMux's model makes it rather difficult to have multiple Gtk+ windows because of the way resizing works. For now, everything is stuck in a single window.

OVERVIEW
--------

The program is pretty small and it does so by making heavy use of GLib and Gtk+ convenience systems, which are not obvious if you haven't worked with them. The program can be divided into two halves: the GUI and the TMux handler.

There is a single `GLib.MainLoop` that schedules events between the GUI and the TMux handler. Since they share a single thread, neither is permitted to block. As a convenience, there is no parellelism and so no locking. The glue that binds the two is GLib's signal mechanism: GUI components bind to signals in the TMux code, which triggers them when it receives appropriate data from the remote end.

The TMux handler consists of a `Stream`, which communicates with a TMux instance to scrape appropriate information. Some commands, like creating a window are issued to the stream. The stream also creates `TMuxWindow` objects, which are handles on each of the windows in the TMux session. GUI components are generally associated with a single window. There are some commands that can be issued directly to windows, including killing the window. A `Stream` needs to be able to communicate with a TMux process. Since reads will almost certainly block, the reading and writing are done using Vala's `async` method support, which uses GIO's asynchronous co-routine system. There are two implementations of this class: one for communicating with a local TMux instance and one for communicating with a TMux instance over SSH using libssh2. The local stream simply spawns a task and uses GIO's asynchronous file streams to communicate with it. SSH is more complicated.

libssh2 can work on top of a non-blocking socket. The class then creates a GIO wrapper around a socket, on which it can asynchronously wait, and then calls into libssh2 when data is available and passes it to the base implementation for processing. There also needs to be interaction between libssh2's authentication mechanism and Gtk+ to show password entry dialogs. This glue code is extremely ugly. In most libraries, the library manages the state of the IO operation in progress; libssh2 does not. So `AsyncImpedanceMatcher` takes a closure which performs the libssh2 operation requested. It will simply keep calling it until it returns something other than EAGAIN. It also converts libssh2 errors into GLib errors (which look like exceptions in Vala).

Inside the GUI, there are three components: the application, the window, and the terminal. The application is a Gtk+ framework for initialising applications. It has support for handling multiple windows that goes dreadfully unused. The application has a collection of all the active streams. The window creates various menus for all the streams that it knows about and creates terminals (tabs) when new TMux windows become available. Each terminal glue the output from TMux to a VTE terminal and sends the keystrokes back to TMux. The resizing is...complicated, since both Gtk+ and TMux have final authority on the size of the terminal, yet have to agree.

Vala and Gtk+ support “templates” which allow the GUI to be designed using Glade and then bound in compiled into Vala. Methods marked as `[GtkCallback]` in Vala are activated by some component in the GUI specified in the matching `.ui` file. There are also a number of dialog boxes, which are simpler. There is also the ugly `password_adapter.c` which allows libssh2 to make use of a Vala-style callback when dealing with authentication.

Resizing is complicated. Gtk+ and TMux each believe them to be authoritative over the size of a terminal, but they can't be. Gtk+ resizes widgets hierarchically and the solution is to break the hierarchy and, essentially, slip TMux into Gtk+'s resizing system. The `Gtk.Window` will resize and change the size of the `Gtk.Notebook` containing the active sessions. Each session is a `Gtk.Box` that holds a `Vte.Terminal`. Resizing the `Gtk.Box` _does not_ set the size of the `Vte.Terminal`. Instead, the `Gtk.Box` sends a message to TMux setting the client size. TMux then issues a `layout-change` event which sets the size of the `Vte.Terminal`. TMux will guarantee that the `Vte.Terminal` will be the no larger than the containing `Gtk.Box`, so no real effort is needed to ensure this. When multiple clients are connected to the same TMux session, the windows may be smaller than the client's size, if limited by a different client. This will cause the `Vte.Terminal` to be smaller than the `Gtk.Box`, resulting in a band of grey. Except that a `Gtk.Box` will always force widgets to fill in one direction, so really, there are two nested `Gtk.Box` widgets in perpendicular orientations.
