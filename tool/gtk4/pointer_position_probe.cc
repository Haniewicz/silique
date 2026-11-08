// Native GTK4 regression for pointer coordinates inside a decorated window.
//
// The fixture mirrors the shipped runner: a GtkWindow with a GtkHeaderBar and a
// content widget inside it. A tiny target widget sits at a known position in
// the content. The probe asks the test driver to click the target's laid-out
// centre and then asserts that the position Flutter receives
// (fl_gtk_event_get_view_position) lands on that centre instead of being
// shifted by the CSD border or the header bar. Expectations come from the
// target's own laid-out geometry, so a wrong sign or a stale content offset
// fails instead of passing silently.
#include <cmath>
#include <cstdio>
#include <gtk/gtk.h>

#include "fl_gtk.h"

static GtkWidget* window;
static GtkWidget* content;
static GtkWidget* target;
static GMainLoop* loop;
static const char* report_path;
static const char* request_path;
static double expected_x = 0, expected_y = 0;
static bool awaiting_click = false;

static void write_report(bool ok, const char* detail, double mapped_x,
                         double mapped_y) {
  g_autofree gchar* result = g_strdup_printf(
      "{\"passed\":%s,\"detail\":\"%s\",\"mappedX\":%.2f,\"mappedY\":%.2f,"
      "\"expectedX\":%.2f,\"expectedY\":%.2f}\n",
      ok ? "true" : "false", detail, mapped_x, mapped_y, expected_x,
      expected_y);
  g_file_set_contents(report_path, result, -1, nullptr);
  g_print("%s", result);
}

// Publishes the click the driver must perform: the target centre expressed in
// surface coordinates, derived only from GTK's own layout APIs.
static void request_click() {
  GtkNative* native = gtk_widget_get_native(content);
  if (native == nullptr) {
    write_report(false, "native-unavailable", -1, -1);
    g_main_loop_quit(loop);
    return;
  }
  graphene_point_t origin = GRAPHENE_POINT_INIT(0, 0);
  graphene_point_t content_point, target_point;
  if (!gtk_widget_compute_point(content, GTK_WIDGET(native), &origin,
                                &content_point) ||
      !gtk_widget_compute_point(target, content, &origin, &target_point)) {
    write_report(false, "layout-unavailable", -1, -1);
    g_main_loop_quit(loop);
    return;
  }
  double transform_x = 0, transform_y = 0;
  gtk_native_get_surface_transform(native, &transform_x, &transform_y);
  expected_x = target_point.x;
  expected_y = target_point.y;
  const double surface_x = content_point.x + transform_x + expected_x;
  const double surface_y = content_point.y + transform_y + expected_y;
  g_autofree gchar* request =
      g_strdup_printf("{\"x\":%.2f,\"y\":%.2f}\n", surface_x, surface_y);
  g_file_set_contents(request_path, request, -1, nullptr);
  awaiting_click = true;
}

static gboolean start_cb(gpointer) {
  // Resize after the first frame: the content offset must survive it.
  gtk_window_set_default_size(GTK_WINDOW(window), 1000, 650);
  gtk_window_set_default_size(GTK_WINDOW(window), 1180, 700);
  FlGdkSurface* surface = fl_gtk_widget_get_surface(content);
  if (surface != nullptr) {
    fl_gtk_surface_update_content_offset(content, surface);
  }
  request_click();
  return G_SOURCE_REMOVE;
}

static gboolean event_cb(GtkEventControllerLegacy*, GdkEvent* event, gpointer) {
  if (!awaiting_click || gdk_event_get_event_type(event) != GDK_BUTTON_PRESS) {
    return FALSE;
  }
  awaiting_click = false;
  double x = 0, y = 0;
  if (!fl_gtk_event_get_view_position(event, &x, &y)) {
    write_report(false, "position-invalid", -1, -1);
    g_main_loop_quit(loop);
    return TRUE;
  }
  const bool hit =
      std::abs(x - expected_x) <= 1.0 && std::abs(y - expected_y) <= 1.0;
  write_report(hit, hit ? "target-hit" : "target-missed", x, y);
  g_main_loop_quit(loop);
  return TRUE;
}

static gboolean deadline(gpointer) {
  if (awaiting_click) {
    write_report(false, "click-timeout", -1, -1);
  }
  g_main_loop_quit(loop);
  return G_SOURCE_REMOVE;
}

int main(int argc, char** argv) {
  if (argc != 3) return 2;
  report_path = argv[1];
  request_path = argv[2];
  gtk_init();
  window = gtk_window_new();
  gtk_window_set_title(GTK_WINDOW(window),
                       "Silique pointer position regression");
  gtk_window_set_default_size(GTK_WINDOW(window), 1280, 720);
  GtkWidget* header = gtk_header_bar_new();
  gtk_window_set_titlebar(GTK_WINDOW(window), header);

  content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  target = gtk_label_new("target");
  gtk_widget_set_size_request(target, 10, 10);
  gtk_widget_set_halign(target, GTK_ALIGN_START);
  gtk_widget_set_valign(target, GTK_ALIGN_START);
  gtk_widget_set_margin_start(target, 137);
  gtk_widget_set_margin_top(target, 211);
  gtk_box_append(GTK_BOX(content), target);
  gtk_window_set_child(GTK_WINDOW(window), content);

  GtkEventController* controller = gtk_event_controller_legacy_new();
  gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE);
  g_signal_connect(controller, "event", G_CALLBACK(event_cb), nullptr);
  gtk_widget_add_controller(content, controller);

  gtk_window_present(GTK_WINDOW(window));
  loop = g_main_loop_new(nullptr, FALSE);
  g_timeout_add(1200, start_cb, nullptr);
  const guint timer = g_timeout_add_seconds(20, deadline, nullptr);
  g_main_loop_run(loop);
  g_source_remove(timer);
  gtk_window_destroy(GTK_WINDOW(window));
  g_main_loop_unref(loop);
  return 0;
}
