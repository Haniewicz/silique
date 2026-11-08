import '../l10n/strings.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException;
import 'package:window_manager/window_manager.dart';

class NativeWindow with WindowListener {
  static final instance = NativeWindow();
  bool enabled = false;
  bool _closing = false;
  Future<void> Function()? beforeClose;

  static void installLifecycleHandler() {
    if (!Platform.isMacOS) return;
    const MethodChannel('silique.notes/lifecycle')
        .setMethodCallHandler((call) async {
          if (call.method != 'flushBeforeQuit') throw MissingPluginException();
          await instance.beforeClose?.call();
          return true;
        });
  }

  static Future<void> initialize() async {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return;
    if (instance.enabled) return;
    await windowManager.ensureInitialized();
    instance.enabled = true;
    // Wayland lets the compositor place windows; it does not expose the global
    // pointer position used by window_manager's centering implementation.
    final wayland =
        Platform.isLinux &&
        Platform.environment['GDK_BACKEND'] != 'x11' &&
        ((Platform.environment['WAYLAND_DISPLAY']?.isNotEmpty ?? false) ||
            Platform.environment['XDG_SESSION_TYPE'] == 'wayland');
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: const Size(1240, 860),
        minimumSize: const Size(760, 560),
        center: !wayland,
        title: 'Silique',
        titleBarStyle: TitleBarStyle.normal,
        windowButtonVisibility: true,
        backgroundColor: const Color(0xff101622),
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
    await windowManager.setResizable(true);
    await windowManager.setPreventClose(true);
    windowManager.addListener(instance);
  }

  @override
  void onWindowClose() async {
    // WM_CLOSE may repeat while encryption or disk I/O is still running. Never
    // start a second save/lock/checkpoint or race two native destroys.
    if (_closing) return;
    _closing = true;
    final elapsed = Stopwatch()..start();
    debugPrint('WINDOW_CLOSE phase=save_started');
    try {
      await beforeClose?.call();
      debugPrint(
        'WINDOW_CLOSE phase=save_complete elapsed_ms=${elapsed.elapsedMilliseconds}',
      );
      await windowManager.destroy();
      // This is method-channel acknowledgement, NOT measured process exit.
      debugPrint(
        'WINDOW_CLOSE phase=destroy_ack elapsed_ms=${elapsed.elapsedMilliseconds}',
      );
    } catch (error) {
      // No timeout or forced exit: a failed save must keep the window open and
      // clear the single-flight gate so a subsequent close can retry.
      debugPrint(
        'WINDOW_CLOSE phase=blocked elapsed_ms=${elapsed.elapsedMilliseconds} error_type=${error.runtimeType}',
      );
    } finally {
      _closing = false;
    }
  }

  static void close() {
    if (instance.enabled) windowManager.close();
  }

  /// Starts a detached copy of this executable, then closes the window through
  /// the normal close path so `beforeClose`/`onWindowClose` finish their saves.
  /// Never calls `exit()`: the process keeps running until the window's normal
  /// teardown completes. Throws [StateError] when the window subsystem is not
  /// enabled (for example in tests) so the caller can surface a fallback.
  static Future<void> restart() async {
    if (!instance.enabled) {
      throw StateError(tr('Brak okna aplikacji.', 'No app window available.'));
    }
    await Process.start(
      Platform.resolvedExecutable,
      const <String>[],
      mode: ProcessStartMode.detached,
    );
    await windowManager.destroy();
  }

  /// Called only after input/write admission is fenced and saves have drained.
  static Future<void> finishPreparedUpdate() async {
    if (!instance.enabled) {
      throw StateError(tr('Brak okna aplikacji.', 'No app window available.'));
    }
    await windowManager.destroy();
  }

  static void minimize() {
    if (instance.enabled) windowManager.minimize();
  }

  static Future<void> maximize() async {
    if (!instance.enabled) return;
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  static void drag() {
    if (instance.enabled) windowManager.startDragging();
  }
}
