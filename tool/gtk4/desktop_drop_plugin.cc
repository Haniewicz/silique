// GTK4 adapter for desktop_drop's existing Dart channel.
// Upstream API/license: desktop_drop 0.8.4 (MIT).
#include "include/desktop_drop/desktop_drop_plugin.h"
#include <gtk/gtk.h>

struct _DesktopDropPlugin { GObject parent_instance; };
G_DEFINE_TYPE(DesktopDropPlugin, desktop_drop_plugin, G_TYPE_OBJECT)
static void desktop_drop_plugin_class_init(DesktopDropPluginClass*) {}
static void desktop_drop_plugin_init(DesktopDropPlugin*) {}

static GdkDragAction motion(GtkDropTarget*, double x, double y, gpointer data) {
  double point[] = {x, y};
  g_autoptr(FlValue) args = fl_value_new_float_list(point, 2);
  fl_method_channel_invoke_method(FL_METHOD_CHANNEL(data), "updated", args,
                                nullptr, nullptr, nullptr);
  return GDK_ACTION_COPY;
}

static void leave(GtkDropTarget*, gpointer data) {
  fl_method_channel_invoke_method(FL_METHOD_CHANNEL(data), "exited", nullptr,
                                nullptr, nullptr, nullptr);
}

static gboolean drop(GtkDropTarget*, const GValue* value, double x, double y,
                     gpointer data) {
  if (!G_VALUE_HOLDS(value, GDK_TYPE_FILE_LIST)) return FALSE;
  auto* files = static_cast<GdkFileList*>(g_value_get_boxed(value));
  g_autoptr(GString) uris = g_string_new(nullptr);
  for (GSList* item = gdk_file_list_get_files(files); item; item = item->next) {
    g_autofree gchar* uri = g_file_get_uri(G_FILE(item->data));
    g_string_append(uris, uri);
    g_string_append(uris, "\r\n");
  }
  if (uris->len == 0) return FALSE;
  double point[] = {x, y};
  g_autoptr(FlValue) args = fl_value_new_list();
  fl_value_append_take(args, fl_value_new_string(uris->str));
  fl_value_append_take(args, fl_value_new_float_list(point, 2));
  fl_method_channel_invoke_method(FL_METHOD_CHANNEL(data), "performOperation_linux",
                                args, nullptr, nullptr, nullptr);
  return TRUE;
}

void desktop_drop_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  GtkWidget* view = GTK_WIDGET(fl_plugin_registrar_get_view(registrar));
  if (!view) return;
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "desktop_drop",
      FL_METHOD_CODEC(codec));
  GtkDropTarget* target = gtk_drop_target_new(GDK_TYPE_FILE_LIST, GDK_ACTION_COPY);
  g_object_set_data_full(G_OBJECT(target), "silique-drop-channel", channel, g_object_unref);
  g_signal_connect(target, "enter", G_CALLBACK(motion), channel);
  g_signal_connect(target, "motion", G_CALLBACK(motion), channel);
  g_signal_connect(target, "leave", G_CALLBACK(leave), channel);
  g_signal_connect(target, "drop", G_CALLBACK(drop), channel);
  gtk_widget_add_controller(view, GTK_EVENT_CONTROLLER(target));
}
