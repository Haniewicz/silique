// GTK4 implementation of the window_manager channel used by Silique.
// Window placement on Wayland is controlled by the compositor.
#include "include/window_manager/window_manager_plugin.h"
#include <gtk/gtk.h>
#include <cstring>
#ifdef GDK_WINDOWING_X11
#include <gdk/x11/gdkx.h>
#include <X11/Xlib.h>
#endif

struct _WindowManagerPlugin {
  GObject parent_instance;
  GtkWindow* window;
  FlMethodChannel* channel;
  GdkEvent* press;
  gboolean prevent_close;
};
G_DEFINE_TYPE(WindowManagerPlugin, window_manager_plugin, G_TYPE_OBJECT)

static FlValue* field(FlValue* args, const char* name) {
  return args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
      ? fl_value_lookup_string(args, name) : nullptr;
}
static double number(FlValue* args, const char* name, double fallback = 0) {
  FlValue* value = field(args, name);
  if (!value) return fallback;
  if (fl_value_get_type(value) == FL_VALUE_TYPE_INT) return fl_value_get_int(value);
  if (fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT) return fl_value_get_float(value);
  return fallback;
}
static bool boolean(FlValue* args, const char* name) {
  FlValue* value = field(args, name);
  return value && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(value);
}
static const char* text(FlValue* args, const char* name) {
  FlValue* value = field(args, name);
  return value && fl_value_get_type(value) == FL_VALUE_TYPE_STRING ? fl_value_get_string(value) : "";
}
static GdkSurface* surface(WindowManagerPlugin* self) {
  return self->window ? gtk_native_get_surface(GTK_NATIVE(self->window)) : nullptr;
}
static void event(WindowManagerPlugin* self, const char* name) {
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "eventName", fl_value_new_string(name));
  fl_method_channel_invoke_method(self->channel, "onEvent", args, nullptr, nullptr, nullptr);
}
static gboolean closing(GtkWindow*, WindowManagerPlugin* self) {
  if (!self->prevent_close) return FALSE;
  event(self, "close");
  return TRUE;
}
static gboolean pointer_event(GtkEventControllerLegacy*, GdkEvent* value, WindowManagerPlugin* self) {
  if (gdk_event_get_event_type(value) == GDK_BUTTON_PRESS) {
    g_clear_pointer(&self->press, gdk_event_unref);
    self->press = gdk_event_ref(value);
  }
  return FALSE;
}
static void focused(GtkWindow* window, GParamSpec*, WindowManagerPlugin* self) {
  event(self, gtk_window_is_active(window) ? "focus" : "blur");
}
static void maximized(GtkWindow* window, GParamSpec*, WindowManagerPlugin* self) {
  event(self, gtk_window_is_maximized(window) ? "maximize" : "unmaximize");
}

static void method(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto* self = static_cast<WindowManagerPlugin*>(data);
  if (!self->window) {
    fl_method_call_respond_error(call, "window_closed", "Window has closed.", nullptr, nullptr);
    return;
  }
  const char* name = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  g_autoptr(FlValue) result = nullptr;
  GtkWidget* widget = GTK_WIDGET(self->window);
  if (!strcmp(name, "ensureInitialized") || !strcmp(name, "waitUntilReadyToShow")) {
    result = fl_value_new_null();
  } else if (!strcmp(name, "setPreventClose")) {
    self->prevent_close = boolean(args, "isPreventClose");
  } else if (!strcmp(name, "isPreventClose")) {
    result = fl_value_new_bool(self->prevent_close);
  } else if (!strcmp(name, "destroy")) {
    self->prevent_close = FALSE;
    gtk_window_destroy(self->window);
  } else if (!strcmp(name, "close")) {
    gtk_window_close(self->window);
  } else if (!strcmp(name, "show") || !strcmp(name, "focus") || !strcmp(name, "restore")) {
    gtk_window_present(self->window);
  } else if (!strcmp(name, "hide")) {
    gtk_widget_set_visible(widget, FALSE);
  } else if (!strcmp(name, "isVisible")) {
    result = fl_value_new_bool(gtk_widget_get_visible(widget));
  } else if (!strcmp(name, "isFocused")) {
    result = fl_value_new_bool(gtk_window_is_active(self->window));
  } else if (!strcmp(name, "maximize")) {
    gtk_window_maximize(self->window);
  } else if (!strcmp(name, "unmaximize")) {
    gtk_window_unmaximize(self->window);
  } else if (!strcmp(name, "isMaximized")) {
    result = fl_value_new_bool(gtk_window_is_maximized(self->window));
  } else if (!strcmp(name, "minimize")) {
    gtk_window_minimize(self->window);
  } else if (!strcmp(name, "isMinimized")) {
    auto* s = surface(self);
    result = fl_value_new_bool(s && GDK_IS_TOPLEVEL(s) &&
        (gdk_toplevel_get_state(GDK_TOPLEVEL(s)) & GDK_TOPLEVEL_STATE_MINIMIZED));
  } else if (!strcmp(name, "isFullScreen")) {
    result = fl_value_new_bool(gtk_window_is_fullscreen(self->window));
  } else if (!strcmp(name, "setFullScreen")) {
    if (boolean(args, "isFullScreen")) gtk_window_fullscreen(self->window);
    else gtk_window_unfullscreen(self->window);
  } else if (!strcmp(name, "setTitleBarStyle") || !strcmp(name, "setAsFrameless")) {
    bool normal = !strcmp(name, "setTitleBarStyle") && !strcmp(text(args, "titleBarStyle"), "normal");
    GtkWidget* header = gtk_window_get_titlebar(self->window);
    if (header) gtk_widget_set_visible(header, normal);
    gtk_window_set_decorated(self->window, normal);
  } else if (!strcmp(name, "getTitleBarHeight")) {
    GtkWidget* header = gtk_window_get_titlebar(self->window);
    result = fl_value_new_int(header && gtk_widget_get_visible(header)
        ? gtk_widget_get_height(header) : 0);
  } else if (!strcmp(name, "setTitle")) {
    gtk_window_set_title(self->window, text(args, "title"));
  } else if (!strcmp(name, "getTitle")) {
    const char* title = gtk_window_get_title(self->window);
    result = fl_value_new_string(title ? title : "");
  } else if (!strcmp(name, "setMinimumSize")) {
    gtk_widget_set_size_request(widget, number(args, "width"), number(args, "height"));
  } else if (!strcmp(name, "setBounds")) {
    if (field(args, "width") || field(args, "height")) {
      int width, height;
      gtk_window_get_default_size(self->window, &width, &height);
      gtk_window_set_default_size(self->window, number(args, "width", width), number(args, "height", height));
    }
#ifdef GDK_WINDOWING_X11
    GdkSurface* s = surface(self);
    if (s && GDK_IS_X11_SURFACE(s) && field(args, "x") && field(args, "y")) {
      XMoveWindow(gdk_x11_display_get_xdisplay(gdk_surface_get_display(s)),
                  gdk_x11_surface_get_xid(s), number(args, "x"), number(args, "y"));
    }
#endif
  } else if (!strcmp(name, "getBounds")) {
    int width = gtk_widget_get_width(widget), height = gtk_widget_get_height(widget);
    if (width < 1 || height < 1) gtk_window_get_default_size(self->window, &width, &height);
    double x = 0, y = 0;
#ifdef GDK_WINDOWING_X11
    GdkSurface* s = surface(self);
    if (s && GDK_IS_X11_SURFACE(s)) {
      Display* display = gdk_x11_display_get_xdisplay(gdk_surface_get_display(s));
      int root_x, root_y; Window child;
      if (XTranslateCoordinates(display, gdk_x11_surface_get_xid(s), DefaultRootWindow(display), 0, 0, &root_x, &root_y, &child)) {
        x = root_x; y = root_y;
      }
    }
#endif
    result = fl_value_new_map();
    fl_value_set_string_take(result, "x", fl_value_new_float(x));
    fl_value_set_string_take(result, "y", fl_value_new_float(y));
    fl_value_set_string_take(result, "width", fl_value_new_float(width));
    fl_value_set_string_take(result, "height", fl_value_new_float(height));
  } else if (!strcmp(name, "setResizable")) {
    gtk_window_set_resizable(self->window, boolean(args, "isResizable"));
  } else if (!strcmp(name, "isResizable")) {
    result = fl_value_new_bool(gtk_window_get_resizable(self->window));
  } else if (!strcmp(name, "setBackgroundColor")) {
    g_autoptr(GtkCssProvider) css = gtk_css_provider_new();
    g_autofree char* style = g_strdup_printf("window { background-color: rgba(%d,%d,%d,%g); }",
        static_cast<int>(number(args, "backgroundColorR")), static_cast<int>(number(args, "backgroundColorG")),
        static_cast<int>(number(args, "backgroundColorB")), number(args, "backgroundColorA") / 255.0);
    gtk_css_provider_load_from_data(css, style, -1);
    gtk_style_context_add_provider_for_display(gtk_widget_get_display(widget), GTK_STYLE_PROVIDER(css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  } else if (!strcmp(name, "startDragging")) {
    GdkSurface* s = surface(self);
    if (s && GDK_IS_TOPLEVEL(s) && self->press) {
      double x, y;
      gdk_event_get_position(self->press, &x, &y);
      gdk_toplevel_begin_move(GDK_TOPLEVEL(s), gdk_event_get_device(self->press),
          gdk_button_event_get_button(self->press), x, y, gdk_event_get_time(self->press));
    }
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  fl_method_call_respond_success(call, result, nullptr);
}

static void dispose(GObject* object) {
  auto* self = reinterpret_cast<WindowManagerPlugin*>(object);
  if (self->window && g_object_get_data(G_OBJECT(self->window), "flutter-linux-native-close-handler") == self)
    g_object_set_data(G_OBJECT(self->window), "flutter-linux-native-close-handler", nullptr);
  if (self->window) g_object_remove_weak_pointer(G_OBJECT(self->window), reinterpret_cast<gpointer*>(&self->window));
  if (self->channel) fl_method_channel_set_method_call_handler(self->channel, nullptr, nullptr, nullptr);
  g_clear_object(&self->channel);
  g_clear_pointer(&self->press, gdk_event_unref);
  G_OBJECT_CLASS(window_manager_plugin_parent_class)->dispose(object);
}
static void window_manager_plugin_class_init(WindowManagerPluginClass* klass) { G_OBJECT_CLASS(klass)->dispose = dispose; }
static void window_manager_plugin_init(WindowManagerPlugin*) {}

void window_manager_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  GtkWidget* view = GTK_WIDGET(fl_plugin_registrar_get_view(registrar));
  if (!view) return;
  auto* self = reinterpret_cast<WindowManagerPlugin*>(g_object_new(window_manager_plugin_get_type(), nullptr));
  self->window = GTK_WINDOW(gtk_widget_get_root(view));
  g_object_set_data(G_OBJECT(self->window), "flutter-linux-native-close-handler", self);
  g_object_add_weak_pointer(G_OBJECT(self->window), reinterpret_cast<gpointer*>(&self->window));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar), "window_manager", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->channel, method, self, nullptr);
  g_object_set_data_full(G_OBJECT(view), "silique-gtk4-window-manager", self, g_object_unref);
  g_signal_connect_object(self->window, "close-request", G_CALLBACK(closing), self, G_CONNECT_DEFAULT);
  g_signal_connect_object(self->window, "notify::is-active", G_CALLBACK(focused), self, G_CONNECT_DEFAULT);
  g_signal_connect_object(self->window, "notify::maximized", G_CALLBACK(maximized), self, G_CONNECT_DEFAULT);
  GtkEventController* pointer = gtk_event_controller_legacy_new();
  gtk_event_controller_set_propagation_phase(pointer, GTK_PHASE_CAPTURE);
  g_signal_connect_object(pointer, "event", G_CALLBACK(pointer_event), self, G_CONNECT_DEFAULT);
  gtk_widget_add_controller(GTK_WIDGET(self->window), pointer);
}
