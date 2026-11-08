#!/usr/bin/env python3
"""Prepare isolated GTK4 native adapters without editing the shared pub cache."""
import json
from pathlib import Path
import re
import shutil
import urllib.parse

VERSIONS = {
    'desktop_drop': '0.8.4',
    'file_selector_linux': '0.9.4+1',
    'flutter_secure_storage_linux': '3.0.3',
    'screen_retriever_linux': '0.2.2',
    'url_launcher_linux': '3.2.3',
    'window_manager': '0.5.2',
}

FILE_CHOOSER_HELPERS = r'''
// GTK4 has asynchronous native dialogs and GFile selections. The existing
// Pigeon protocol is synchronous; a nested GLib loop keeps the UI responsive
// while returning the same response shape to Dart.
static gint silique_dialog_run(GtkNativeDialog* dialog) {
  struct State { GMainLoop* loop; gint response; bool done; };
  g_autoptr(GMainLoop) loop = g_main_loop_new(nullptr, FALSE);
  State state{loop, GTK_RESPONSE_CANCEL, false};
  gulong handler = g_signal_connect(dialog, "response", G_CALLBACK(+[](
      GtkNativeDialog*, gint response, gpointer data) {
    auto* state = static_cast<State*>(data);
    state->response = response;
    state->done = true;
    g_main_loop_quit(state->loop);
  }), &state);
  gtk_native_dialog_show(dialog);
  if (!state.done) g_main_loop_run(loop);
  g_signal_handler_disconnect(dialog, handler);
  gtk_native_dialog_hide(dialog);
  return state.response;
}
static void silique_set_current_folder(GtkFileChooser* chooser, const gchar* path) {
  g_autoptr(GFile) folder = g_file_new_for_path(path);
  gtk_file_chooser_set_current_folder(chooser, folder, nullptr);
}
static GSList* silique_file_names(GtkFileChooser* chooser) {
  g_autoptr(GListModel) files = gtk_file_chooser_get_files(chooser);
  GSList* names = nullptr;
  for (guint i = 0; i < g_list_model_get_n_items(files); ++i) {
    g_autoptr(GFile) file = G_FILE(g_list_model_get_item(files, i));
    gchar* path = g_file_get_path(file);
    if (path) names = g_slist_prepend(names, path);
  }
  return g_slist_reverse(names);
}
'''


def replace_once(text, before, after):
    if text.count(before) != 1:
        raise ValueError('Upstream native source changed; review the GTK4 adapter.')
    return text.replace(before, after)


def main():
    app = Path(__file__).resolve().parent.parent
    configuration = app / '.dart_tool/package_config.json'
    packages = {}
    for item in json.loads(configuration.read_text())['packages']:
        uri = item['rootUri']
        packages[item['name']] = Path(urllib.parse.urlparse(uri).path) if uri.startswith('file:') else (configuration.parent / uri).resolve()
    runner = app / 'linux-gtk4'
    output = runner / 'flutter/ephemeral/gtk4-plugins'
    output.mkdir(parents=True, exist_ok=True)
    for name, version in VERSIONS.items():
        source = packages[name]
        actual = re.search(r'^version:\s*[\'"]?([^\s\'"]+)', (source / 'pubspec.yaml').read_text(), re.M)
        if not actual or actual[1] != version:
            raise ValueError(f'{name}: review the GTK4 adapter for this package version.')
        destination = output / name
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(source / 'linux', destination / 'linux')
        shutil.copy2(source / 'LICENSE', destination / 'LICENSE')
        cmake = destination / 'linux/CMakeLists.txt'
        cmake.write_text(cmake.read_text().replace('gtk+-3.0', 'gtk4'))
        custom = app / 'tool/gtk4' / f'{name}_plugin.cc'
        if name == 'window_manager':
            custom = app / 'tool/gtk4/window_manager_plugin.cc'
        if custom.exists():
            shutil.copy2(custom, destination / 'linux' / custom.name)
        if name in ['window_manager', 'screen_retriever_linux']:
            with cmake.open('a') as file:
                file.write('\npkg_check_modules(SILIQUE_X11 REQUIRED IMPORTED_TARGET x11)\ntarget_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::SILIQUE_X11)\n')
    file = output / 'file_selector_linux/linux/file_selector_plugin.cc'
    text = file.read_text()
    text = replace_once(text, '#include "messages.g.h"', '#include "messages.g.h"\n' + FILE_CHOOSER_HELPERS)
    # Only replace the old call sites, not the new helper implementation.
    text = replace_once(text, 'gtk_file_chooser_set_current_folder(GTK_FILE_CHOOSER(dialog),', 'silique_set_current_folder(GTK_FILE_CHOOSER(dialog),')
    text = text.replace('gtk_widget_get_toplevel(GTK_WIDGET(view))', 'gtk_widget_get_root(GTK_WIDGET(view))')
    text = text.replace('gtk_native_dialog_run);', 'silique_dialog_run);')
    text = text.replace('gtk_file_chooser_get_filenames(', 'silique_file_names(')
    file.write_text(text)
    file = output / 'url_launcher_linux/linux/url_launcher_plugin.cc'
    text = file.read_text()
    start = text.index('  if (view != nullptr) {', text.index('static FulUrlLauncherApiLaunchUrlResponse* handle_launch_url'))
    end = text.index('  if (!launched)', start)
    text = text[:start] + '''  GdkDisplay* display = view ? gtk_widget_get_display(GTK_WIDGET(view)) : gdk_display_get_default();
  g_autoptr(GdkAppLaunchContext) context = display ? gdk_display_get_app_launch_context(display) : nullptr;
  launched = g_app_info_launch_default_for_uri(url, context ? G_APP_LAUNCH_CONTEXT(context) : nullptr, &error);
''' + text[end:]
    file.write_text(text)
    # Flutter recreates .plugin_symlinks. Point CMake at the independent copies
    # instead, while retaining its generated registration and FFI plugin lists.
    generated = (runner / 'flutter/generated_plugins.cmake')
    if not generated.exists():
        generated = app / 'linux/flutter/generated_plugins.cmake'
    text = generated.read_text()
    text = text.replace('add_subdirectory(flutter/ephemeral/.plugin_symlinks/${plugin}/linux plugins/${plugin})', '''if(plugin IN_LIST SILIQUE_GTK4_PATCHED)
    add_subdirectory(flutter/ephemeral/gtk4-plugins/${plugin}/linux plugins/${plugin})
  else()
    add_subdirectory(flutter/ephemeral/.plugin_symlinks/${plugin}/linux plugins/${plugin})
  endif()''', 1)
    text = 'set(SILIQUE_GTK4_PATCHED ' + ' '.join(VERSIONS) + ')\n' + text
    (runner / 'flutter/gtk4_plugins.cmake').write_text(text)
    print('Prepared pinned GTK4 native adapters; shared package cache was not changed.')


if __name__ == '__main__':
    main()
