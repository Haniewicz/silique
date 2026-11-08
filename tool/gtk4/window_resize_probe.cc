// GTK4 probe: verify window resize behaviour using GTK4 APIs.
// Compile: g++ -std=c++17 -Wall -Wextra -Werror $(pkg-config --cflags --libs gtk4) -o window_resize_probe window_resize_probe.cc
// Run: xvfb-run -a -s '-screen 0 1024x768x24' ./window_resize_probe /tmp/resize-probe-result.json
#include <cstdio>
#include <gtk/gtk.h>

static const char* report_path;
static GMainLoop* loop;

static gboolean deadline_cb(gpointer) {
  g_main_loop_quit(loop);
  return G_SOURCE_REMOVE;
}

static void write_report(bool passed, const char* checks) {
  g_autofree gchar* json = g_strdup_printf(
      "{\"passed\":%s,\"checks\":\"%s\"}\n",
      passed ? "true" : "false", checks ? checks : "");
  g_file_set_contents(report_path, json, -1, nullptr);
  g_print("%s", json);
}

static gboolean run_checks(gpointer data) {
  GtkWindow* window = GTK_WINDOW(data);
  g_autoptr(GString) results = g_string_new("");

  // Check 1: default resizable state (GTK default is TRUE)
  gboolean resizable = gtk_window_get_resizable(window);
  g_string_append_printf(results, "default_resizable=%s;", resizable ? "TRUE" : "FALSE");

  // Check 2: explicit set_resizable(TRUE) persists
  gtk_window_set_resizable(window, TRUE);
  gboolean after_set = gtk_window_get_resizable(window);
  g_string_append_printf(results, "after_set_resizable=%s;", after_set ? "TRUE" : "FALSE");

  // Check 3: get the default size that was set before show
  int def_w = 0, def_h = 0;
  gtk_window_get_default_size(window, &def_w, &def_h);
  g_string_append_printf(results, "default_size=%dx%d;", def_w, def_h);

  // Check 4: get the actual allocated size after show
  int alloc_w = gtk_widget_get_width(GTK_WIDGET(window));
  int alloc_h = gtk_widget_get_height(GTK_WIDGET(window));
  g_string_append_printf(results, "allocated=%dx%d;", alloc_w, alloc_h);

  // Check 5: set a new default size (this would apply if the window were re-shown)
  gtk_window_set_default_size(window, 980, 640);
  gtk_window_get_default_size(window, &def_w, &def_h);
  g_string_append_printf(results, "after_set_default=%dx%d;", def_w, def_h);

  // Check 6: GdkToplevel size limits — query the surface
  GdkSurface* surface = gtk_native_get_surface(GTK_NATIVE(window));
  gboolean has_toplevel = (surface != nullptr && GDK_IS_TOPLEVEL(surface));
  g_string_append_printf(results, "has_toplevel_surface=%s;", has_toplevel ? "TRUE" : "FALSE");

  // Assertions
  bool ok = resizable && after_set && alloc_w > 0 && alloc_h > 0 && has_toplevel;
  write_report(ok, results->str);
  g_main_loop_quit(loop);
  return G_SOURCE_REMOVE;
}

int main(int argc, char** argv) {
  if (argc != 2) {
    g_printerr("Usage: %s <result-json-path>\n", argv[0]);
    return 2;
  }
  report_path = argv[1];
  gtk_init();

  GtkWidget* window = gtk_window_new();
  gtk_window_set_title(GTK_WINDOW(window), "Silique window resize probe");
  gtk_window_set_default_size(GTK_WINDOW(window), 600, 400);

  // Add a header bar (matches my_application.cc)
  GtkWidget* header = gtk_header_bar_new();
  gtk_window_set_titlebar(GTK_WINDOW(window), header);

  gtk_widget_set_visible(window, TRUE);

  loop = g_main_loop_new(nullptr, FALSE);
  g_idle_add(run_checks, window);
  const guint timer = g_timeout_add_seconds(10, deadline_cb, nullptr);
  g_main_loop_run(loop);
  g_source_remove(timer);

  gtk_window_destroy(GTK_WINDOW(window));
  g_main_loop_unref(loop);
  return 0;
}