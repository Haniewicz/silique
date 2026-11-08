#!/usr/bin/env python3
"""Real GTK4 drag source for the isolated X11 integration probe."""
import sys
import gi

gi.require_version('Gtk', '4.0')
gi.require_version('Gdk', '4.0')
from gi.repository import Gdk, Gio, Gtk


def activate(app):
    window = Gtk.ApplicationWindow(application=app, title='Silique GTK4 drag source')
    window.set_default_size(280, 100)
    button = Gtk.Button(label='Drag test image')
    source = Gtk.DragSource(actions=Gdk.DragAction.COPY)
    files = Gdk.FileList.new_from_list([Gio.File.new_for_path(sys.argv[1])])
    source.connect('prepare', lambda _source, _x, _y: Gdk.ContentProvider.new_for_value(files))
    button.add_controller(source)
    window.set_child(button)
    window.present()


application = Gtk.Application(application_id='org.silique.IsolatedDragProbe')
application.connect('activate', activate)
application.run([])
