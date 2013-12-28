def get_user_pw (parent, message, default = '') :
	dialogWindow = Gtk.MessageDialog (parent,
					  Gtk.DialogFlags.MODAL | Gtk.DialogFlags.DESTROY_WITH_PARENT,
					  Gtk.MessageType.QUESTION,
					  Gtk.ButtonsType.OK_CANCEL,
					  message)

		       dialogBox = dialogWindow.get_content_area ()
				   userEntry = Gtk.Entry ()
					       userEntry.set_visibility (False)
					       userEntry.set_invisible_char ("*")
					       userEntry.set_size_request (250, 0)
					       userEntry.set_text ("Test")
					       dialogBox.pack_end (userEntry, False, False, 0)
					       # dialogWindow.vbox.pack_start (userEntry, False, False, 0)

					       response = dialogWindow.run ()
							  text = userEntry.get_text ()
								 dialogWindow.destroy ()
								 if response == Gtk.ResponseType.OK :
								 return text
									else :
										return None
