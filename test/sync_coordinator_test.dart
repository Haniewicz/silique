import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/api.dart';
import 'package:silique/services/sync_coordinator.dart';

class _EventsApi extends SiliqueApi {
  _EventsApi() : super('http://127.0.0.1');
  Completer<String>? pending;
  int calls = 0;
  @override
  Future<String> waitForChanges(String? cursor) {
    calls++;
    return (pending = Completer<String>()).future;
  }

  @override
  void cancelChangeWait() {
    final value = pending;
    if (value != null && !value.isCompleted) {
      value.completeError(StateError('cancelled'));
    }
  }
}

void main() {
  testWidgets('continuous typing and server wakeups have a bounded sync rate', (
    tester,
  ) async {
    final api = _EventsApi();
    var calls = 0;
    final scheduler = SyncCoordinator(
      api: () => api,
      synchronize: () async {
        calls++;
        return true;
      },
    );
    scheduler.start();
    await tester.pump();
    for (var i = 0; i < 75; i++) {
      scheduler.localChanged();
      api.pending!.complete('change-$i');
      await tester.pump(const Duration(milliseconds: 800));
    }
    expect(
      calls,
      lessThanOrEqualTo(21),
      reason: 'At most one full sync per 3 seconds, including self wakeups',
    );
    // ignore: avoid_print
    print(
      'TYPING STRESS: 75 edits + 75 event signals / 60 seconds: $calls full syncs',
    );
    scheduler.stop();
    await tester.pump();
    api.close();
  });

  testWidgets('new requests cannot bypass a failed-sync backoff', (
    tester,
  ) async {
    final api = _EventsApi();
    var calls = 0;
    final scheduler = SyncCoordinator(
      api: () => api,
      synchronize: () async {
        calls++;
        return false;
      },
    );
    scheduler.start();
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      scheduler.request();
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(calls, 1);
    scheduler.stop();
    await tester.pump();
    api.close();
  });

  testWidgets(
    'idle waits do not sync, change signals wake immediately, uploads coalesce and background cancels',
    (tester) async {
      final api = _EventsApi();
      var syncs = 0;
      final scheduler = SyncCoordinator(
        api: () => api,
        synchronize: () async {
          syncs++;
          return true;
        },
      );
      scheduler.start();
      await tester.pump();
      api.pending!.complete('v0');
      await tester.pump();
      // Initial cursor catch-up is retained to close the initial sync/listen race.
      await tester.pump(const Duration(seconds: 3));
      final baseline = syncs;
      await tester.pump(const Duration(seconds: 14));
      expect(syncs, baseline);
      api.pending!.complete('v1');
      await tester.pump();
      expect(syncs, baseline + 1);
      for (var i = 0; i < 5; i++) {
        scheduler.localChanged();
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(syncs, baseline + 1);
      await tester.pump(const Duration(milliseconds: 650));
      expect(syncs, baseline + 1);
      await tester.pump(const Duration(seconds: 2));
      expect(syncs, baseline + 2);
      scheduler.stop();
      await tester.pump();
      final requests = api.calls;
      await tester.pump(const Duration(minutes: 2));
      expect(api.calls, requests);
      expect(syncs, baseline + 2);
      scheduler.start();
      await tester.pump();
      expect(syncs, baseline + 3);
      scheduler.stop();
      await tester.pump();
      api.close();
    },
  );

  testWidgets('ongoing uploads never overlap and failures back off', (
    tester,
  ) async {
    final api = _EventsApi();
    var calls = 0;
    final gate = Completer<bool>();
    final scheduler = SyncCoordinator(
      api: () => api,
      synchronize: () {
        calls++;
        return calls == 1 ? gate.future : Future.value(true);
      },
    );
    scheduler.start();
    scheduler.request();
    scheduler.request();
    await tester.pump();
    expect(calls, 1);
    gate.complete(false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 2);
    scheduler.stop();
    await tester.pump();
    api.close();
  });
}
