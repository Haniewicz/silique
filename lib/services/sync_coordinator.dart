import 'dart:async';

import 'api.dart';

/// One cancellable foreground listener, coalesced uploads and bounded retries.
class SyncCoordinator {
  SyncCoordinator({required this.api, required this.synchronize});
  final SiliqueApi? Function() api;
  final Future<bool> Function() synchronize;
  Timer? _upload, _maximumDelay, _maintenance, _retry, _listenRetry, _spacing;
  bool _active = false, _running = false, _requested = false;
  int _generation = 0, _failures = 0;
  SiliqueApi? _listeningApi;

  void start() {
    if (_active) return;
    _active = true;
    final generation = ++_generation;
    request();
    _maintenance = Timer.periodic(
      const Duration(seconds: 60),
      (_) => request(),
    );
    unawaited(_listen(generation));
  }

  void localChanged() {
    if (!_active) return;
    _upload?.cancel();
    _upload = Timer(const Duration(milliseconds: 650), request);
    _maximumDelay ??= Timer(const Duration(seconds: 3), request);
  }

  void request() {
    if (!_active) return;
    _upload?.cancel();
    _maximumDelay?.cancel();
    _maximumDelay = null;
    _requested = true;
    if (!_running && _retry?.isActive != true && _spacing?.isActive != true) {
      unawaited(_drain());
    }
  }

  Future<void> _drain() async {
    _running = true;
    final generation = _generation;
    _requested = false;
    try {
      final transport = api();
      if (transport == null) return;
      bool success;
      Duration cooldown = transport.retryAfter;
      if (cooldown > Duration.zero) {
        success = false;
      } else {
        try {
          success = await synchronize();
        } catch (error) {
          success = false;
          if (error is ApiException) {
            cooldown = error.retryAfter ?? Duration.zero;
          }
        }
      }
      if (!_active || generation != _generation) return;
      if (success) {
        _failures = 0;
        _spacing = Timer(const Duration(seconds: 3), () {
          if (_requested) request();
        });
      } else {
        final seconds = (2 << _failures.clamp(0, 5)).clamp(2, 60);
        _failures++;
        final retry = Duration(seconds: seconds);
        final serverDelay = transport.retryAfter;
        if (serverDelay > cooldown) cooldown = serverDelay;
        _retry = Timer(cooldown > retry ? cooldown : retry, request);
      }
    } finally {
      _running = false;
      if (_active && generation != _generation && _requested) request();
    }
  }

  Future<void> _listen(int generation) async {
    String? cursor;
    SiliqueApi? previous;
    int failures = 0;
    Future<void> delay(Duration duration) {
      final done = Completer<void>();
      _finishListenDelay = () {
        if (!done.isCompleted) done.complete();
      };
      _listenRetry = Timer(duration, _finishListenDelay!);
      return done.future;
    }

    while (_active && generation == _generation) {
      final transport = api();
      if (transport == null) {
        await delay(const Duration(seconds: 2));
        continue;
      }
      if (!identical(transport, previous)) {
        cursor = null;
        previous = transport;
      }
      _listeningApi = transport;
      try {
        final next = await transport.waitForChanges(cursor);
        if (!_active || generation != _generation) break;
        if (next != cursor) {
          cursor = next;
          request();
        }
        failures = 0;
      } catch (error) {
        if (!_active || generation != _generation) break;
        // Existing servers keep their old polling interval until upgraded.
        final unsupported = error is ApiException && error.status == 404;
        if (unsupported) request();
        final seconds = unsupported
            ? 25
            : (2 << failures.clamp(0, 5)).clamp(2, 60);
        failures++;
        final backoff = Duration(seconds: seconds);
        final cooldown = transport.retryAfter;
        await delay(cooldown > backoff ? cooldown : backoff);
      }
    }
  }

  void Function()? _finishListenDelay;
  void stop() {
    _active = false;
    _generation++;
    for (final timer in [
      _upload,
      _maximumDelay,
      _maintenance,
      _retry,
      _listenRetry,
      _spacing,
    ]) {
      timer?.cancel();
    }
    _maximumDelay = null;
    _finishListenDelay?.call();
    _listeningApi?.cancelChangeWait();
    _requested = false;
  }
}
