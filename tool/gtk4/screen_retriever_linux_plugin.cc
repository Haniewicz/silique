// GTK4 adapter for screen_retriever_linux's existing Dart protocol.
#include "include/screen_retriever_linux/screen_retriever_linux_plugin.h"
#include <gtk/gtk.h>
#include <cstring>
#include <initializer_list>
#ifdef GDK_WINDOWING_X11
#include <gdk/x11/gdkx.h>
#include <X11/Xlib.h>
#endif

struct _ScreenRetrieverLinuxPlugin { GObject parent_instance; };
G_DEFINE_TYPE(ScreenRetrieverLinuxPlugin, screen_retriever_linux_plugin, G_TYPE_OBJECT)
static void screen_retriever_linux_plugin_class_init(ScreenRetrieverLinuxPluginClass*) {}
static void screen_retriever_linux_plugin_init(ScreenRetrieverLinuxPlugin*) {}

static FlValue* display_value(GdkMonitor* monitor, guint index) {
  GdkRectangle geometry, workarea;
  gdk_monitor_get_geometry(monitor, &geometry);
  workarea = geometry;
#ifdef GDK_WINDOWING_X11
  if (GDK_IS_X11_MONITOR(monitor)) gdk_x11_monitor_get_workarea(monitor, &workarea);
#endif
  FlValue* size = fl_value_new_map();
  fl_value_set_string_take(size, "width", fl_value_new_float(geometry.width));
  fl_value_set_string_take(size, "height", fl_value_new_float(geometry.height));
  FlValue* visible = fl_value_new_map();
  fl_value_set_string_take(visible, "width", fl_value_new_float(workarea.width));
  fl_value_set_string_take(visible, "height", fl_value_new_float(workarea.height));
  FlValue* position = fl_value_new_map();
  fl_value_set_string_take(position, "dx", fl_value_new_float(workarea.x));
  fl_value_set_string_take(position, "dy", fl_value_new_float(workarea.y));
  FlValue* value = fl_value_new_map();
  const char* model = gdk_monitor_get_model(monitor);
  g_autofree char* id = g_strdup_printf("%u", index);
  fl_value_set_string_take(value, "id", fl_value_new_string(id));
  fl_value_set_string_take(value, "name", fl_value_new_string(model ? model : ""));
  fl_value_set_string_take(value, "size", size);
  fl_value_set_string_take(value, "visibleSize", visible);
  fl_value_set_string_take(value, "visiblePosition", position);
#if GTK_CHECK_VERSION(4, 14, 0)
  fl_value_set_string_take(value, "scaleFactor", fl_value_new_float(gdk_monitor_get_scale(monitor)));
#else
  fl_value_set_string_take(value, "scaleFactor", fl_value_new_float(gdk_monitor_get_scale_factor(monitor)));
#endif
  return value;
}

static void method(FlMethodChannel*, FlMethodCall* call, gpointer) {
  GdkDisplay* display = gdk_display_get_default();
  if (!display) {
    fl_method_call_respond_error(call, "no_display", "No display is available.", nullptr, nullptr);
    return;
  }
  const char* name = fl_method_call_get_name(call);
  g_autoptr(FlValue) result = nullptr;
  GListModel* monitors = gdk_display_get_monitors(display);
  guint count = g_list_model_get_n_items(monitors);
  if (!strcmp(name, "getPrimaryDisplay")) {
    if (count == 0) {
      fl_method_call_respond_error(call, "no_monitor", "No monitor is available.", nullptr, nullptr);
      return;
    }
    g_autoptr(GdkMonitor) monitor = GDK_MONITOR(g_list_model_get_item(monitors, 0));
    result = display_value(monitor, 0);
  } else if (!strcmp(name, "getAllDisplays")) {
    FlValue* list = fl_value_new_list();
    for (guint i = 0; i < count; ++i) {
      g_autoptr(GdkMonitor) monitor = GDK_MONITOR(g_list_model_get_item(monitors, i));
      fl_value_append_take(list, display_value(monitor, i));
    }
    result = fl_value_new_map();
    fl_value_set_string_take(result, "displays", list);
  } else if (!strcmp(name, "getCursorScreenPoint")) {
#ifdef GDK_WINDOWING_X11
    if (GDK_IS_X11_DISPLAY(display)) {
      Display* xdisplay = gdk_x11_display_get_xdisplay(display);
      Window root, child; int root_x, root_y, x, y; unsigned int mask;
      if (XQueryPointer(xdisplay, DefaultRootWindow(xdisplay), &root, &child, &root_x, &root_y, &x, &y, &mask)) {
        result = fl_value_new_map();
        fl_value_set_string_take(result, "dx", fl_value_new_float(root_x));
        fl_value_set_string_take(result, "dy", fl_value_new_float(root_y));
      }
    }
#endif
    if (!result) {
      fl_method_call_respond_error(call, "wayland_restriction", "Wayland does not expose the global pointer position.", nullptr, nullptr);
      return;
    }
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  fl_method_call_respond_success(call, result, nullptr);
}

static void changed(GListModel*, guint, guint removed, guint added, FlEventChannel* channel) {
  for (const char* type : {removed ? "display-removed" : nullptr, added ? "display-added" : nullptr}) {
    if (!type) continue;
    g_autoptr(FlValue) value = fl_value_new_map();
    fl_value_set_string_take(value, "type", fl_value_new_string(type));
    fl_event_channel_send(channel, value, nullptr, nullptr);
  }
}

void screen_retriever_linux_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "dev.leanflutter.plugins/screen_retriever", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method, nullptr, nullptr);
  g_autoptr(FlEventChannel) events = fl_event_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "dev.leanflutter.plugins/screen_retriever_event", FL_METHOD_CODEC(codec));
  GdkDisplay* display = gdk_display_get_default();
  if (display) {
    GListModel* monitors = gdk_display_get_monitors(display);
    // The model owns the channel as long as monitor-change callbacks can run.
    g_object_set_data_full(G_OBJECT(monitors), "silique-screen-events", g_object_ref(events), g_object_unref);
    g_signal_connect_object(monitors, "items-changed", G_CALLBACK(changed), events, G_CONNECT_DEFAULT);
  }
}
