import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps an Android foreground service ("data sync") alive while a long sync
/// operation runs, so the operation survives the app being backgrounded.
///
/// No-op outside Android. Every entry point swallows its own failure: a missing
/// notification permission or an unsupported API level must never abort the
/// sync whose progress it only reports.
class NativeBackgroundTask {
  NativeBackgroundTask({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('silique.notes/background');

  final MethodChannel _channel;

  bool get _available =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Starts the foreground service with an ongoing low-importance notification.
  /// Title/message are shown verbatim by the platform. Returns immediately and
  /// never throws into the operation path.
  Future<void> start({
    required String title,
    required String message,
  }) async {
    if (!_available) return;
    try {
      await _channel.invokeMethod<void>('start', {
        'title': title,
        'message': message,
      });
    } catch (_) {
      // A refused notification (no POST_NOTIFICATIONS grant, a removed channel)
      // must not cancel the sync it was decorating.
    }
  }

  /// Stops the foreground service. Safe to call when nothing was started.
  Future<void> stop() async {
    if (!_available) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // Best effort: the service stops when the operation settles regardless.
    }
  }
}

/// Runs [operation], keeping an Android foreground service alive for its whole
/// lifetime (started before the first step, stopped in `finally`, on success,
/// on error and on cancellation).
///
/// The start/stop are deliberately fire-and-forget: the notification is a
/// progress marker, never a gate, so the operation must not block on (or fail
/// because of) the platform channel. Each call is still error-swallowed by the
/// [NativeBackgroundTask] methods themselves.
Future<T> withBackgroundTask<T>(
  Future<T> Function() operation, {
  required NativeBackgroundTask background,
  required String title,
  required String message,
}) async {
  unawaited(background.start(title: title, message: message));
  try {
    return await operation();
  } finally {
    unawaited(background.stop());
  }
}