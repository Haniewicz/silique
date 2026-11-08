import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/services/sync_coordinator.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

class _CountingWire extends http.BaseClient {
  final inner = http.Client();
  final statuses = <int, int>{};
  int requests = 0, batches = 0, events = 0;
  final clock = Stopwatch()..start();
  final timestamps = <int>[];
  int get peakMinute {
    var start = 0, peak = 0;
    for (var end = 0; end < timestamps.length; end++) {
      while (timestamps[end] - timestamps[start] >=
          const Duration(minutes: 1).inMicroseconds) {
        start++;
      }
      final count = end - start + 1;
      if (count > peak) peak = count;
    }
    return peak;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    timestamps.add(clock.elapsedMicroseconds);
    if (request.url.path.endsWith('/batches')) batches++;
    if (request.url.path == '/v1/events') events++;
    final response = await inner.send(request);
    statuses.update(response.statusCode, (n) => n + 1, ifAbsent: () => 1);
    return response;
  }

  @override
  void close() => inner.close();
}

void main() {
  final server = Platform.environment['SILIQUE_TEST_SERVER'];
  test(
    'post-setup typing with twelve synced vaults and self notifications cannot exhaust HTTP budget',
    () async {
      final dir = Directory.systemTemp.createTempSync('sync-budget-');
      final notebook = Notebook(
        storage: NativeStorage(dir.path),
        keys: MemoryKeys(),
        crypto: TestCrypto(),
      );
      final wire = _CountingWire();
      SyncCoordinator? scheduler;
      StreamSubscription<void>? subscription;
      Future<bool>? active;
      addTearDown(() async {
        scheduler?.stop();
        await subscription?.cancel();
        await active;
        await notebook.close();
        dir.deleteSync(recursive: true);
      });
      await notebook.initialize();
      await notebook.connect(
        server!,
        'budget-${DateTime.now().microsecondsSinceEpoch}@example.com',
        'disposable request budget password',
        register: true,
      );
      for (var i = 0; i < 12; i++) {
        await notebook.createVault('budget $i');
        await notebook.enableSync(notebook.vaults.last);
      }
      final vault = notebook.vaults.first;
      final note = await notebook.createNote(vault.id);
      await notebook.sync();
      notebook.api!.close();
      notebook.api = SiliqueApi(
        server,
        token: notebook.session!.token,
        client: wire,
      );
      final errors = <Object>[];
      var syncs = 0;
      scheduler = SyncCoordinator(
        api: () => notebook.api,
        synchronize: () {
          syncs++;
          return active = notebook.sync().then(
            (_) => true,
            onError: (Object error) {
              errors.add(error);
              return false;
            },
          );
        },
      );
      subscription = notebook.localChanges.listen(
        (_) => scheduler!.localChanged(),
      );
      final watch = Stopwatch()..start();
      scheduler.start();
      for (var i = 0; i < 75; i++) {
        await notebook.save(
          notebook.notes[vault.id]![note.id]!.copyWith(
            body: '${'text 👩‍💻 ' * 1000}$i',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      scheduler.stop();
      await subscription.cancel();
      subscription = null;
      await active;
      // ignore: avoid_print
      print(
        'TWELVE-VAULT HTTP PROOF: edits=75, elapsedMs=${watch.elapsedMilliseconds}, syncs=$syncs, requests=${wire.requests}, batches=${wire.batches}, events=${wire.events}, statuses=${wire.statuses}, errors=${errors.length}',
      );
      expect(
        errors,
        isEmpty,
        reason: 'Typing alone must not cause HTTP429/backoff on the default-limit server',
      );
      expect(wire.statuses[429] ?? 0, 0);
      await notebook.sync();
      for (final v in notebook.vaults) {
        expect(notebook.storage.pending(v.id), isEmpty);
      }
      expect(
        notebook.notes[vault.id]![note.id]!.body,
        '${'text 👩‍💻 ' * 1000}74',
      );
      expect(
        wire.peakMinute,
        lessThanOrEqualTo(185),
        reason: 'Measure all ordinary/event sends in EVERY sliding 60-second window',
      );
      expect(wire.statuses[429] ?? 0, 0);
      // ignore: avoid_print
      print(
        'DRAINED HTTP PROOF: requests=${wire.requests}, peakSliding60s=${wire.peakMinute}, HTTP429=${wire.statuses[429] ?? 0}, all12VaultOutboxesEmpty=true',
      );
    },
    skip: server == null ? 'Set disposable SILIQUE_TEST_SERVER' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
