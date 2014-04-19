TabbedMux
=========

GNU Screen and TMux have become part of most users' work flow when using SSH to access remote systems as has tabbed terminal emulators. Unfortunately, this leads to the situation of have many tabs open: some for the local machine and some for TMux sessions to remote system. Two problems arise:

  1. It's easy to start programs in local windows, then loose the ability to access them remotely.

  2. Remote systems will often have many windows open, resulting in nested layers of windows (“windows” in tabs in windows).

TabbedMux connects to remote systems using SSH, starts TMux, and creates one tab in the GUI for each TMux window that exists in the remote system. All the tabs from all the systems are promoted to a single layer (i.e., no nesting).

BUGS
----

The TMux library has an issue that can cause multiple sessions to blend together. Since most users don't use this feature, it's not a big deal. http://sourceforge.net/p/tmux/tickets/94/

Occasionally, stuff comes back from no apparent session and TabbedMux will create a dead tab.
