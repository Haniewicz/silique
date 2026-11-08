import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/services/sync_coordinator.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

class _Barrier {
  int arrived = 0;
  final done = Completer<void>();
  Future<void> wait() async {
    if (++arrived == 2) done.complete();
    await done.future;
  }
}

class _CountingClient extends http.BaseClient {
  final inner = http.Client();
  _Barrier? barrier;
  int requests = 0, batches = 0;
  Future<void> Function()? onBatch;
  bool rejectBatchOnce = false;
  final batchBodies = <String>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    if (request.url.path.endsWith('/batches')) {
      batches++;
      batchBodies.add((request as http.Request).body);
      if (rejectBatchOnce) {
        rejectBatchOnce = false;
        return http.StreamedResponse(
          Stream.value('{"error":"Parent revision missing"}'.codeUnits),
          409,
        );
      }
    }
    final response = await inner.send(request);
    if (request.url.path.endsWith('/batches')) await onBatch?.call();
    if (request.url.path.endsWith('/changes') && barrier != null) {
      // Buffer before the barrier so both clients see the same server snapshot.
      final bytes = await response.stream.toBytes();
      await barrier!.wait();
      return http.StreamedResponse(
        Stream.value(bytes),
        response.statusCode,
        headers: response.headers,
      );
    }
    return response;
  }

  @override
  void close() => inner.close();
}

void main() {
  final server = Platform.environment['SILIQUE_TEST_SERVER'];
  test(
    'one minute of continuous large-note typing stays below server request limits',
    () async {
      final dir = Directory.systemTemp.createTempSync('sync-stress-');
      final notebook = Notebook(
        storage: NativeStorage(dir.path),
        keys: MemoryKeys(),
        crypto: TestCrypto(),
      );
      final transport = _CountingClient();
      SyncCoordinator? scheduler;
      StreamSubscription<void>? subscription;
      addTearDown(() async {
        scheduler?.stop();
        await subscription?.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await notebook.close();
        dir.deleteSync(recursive: true);
      });
      await notebook.initialize();
      await notebook.connect(
        server!,
        'stress-${DateTime.now().microsecondsSinceEpoch}@example.com',
        'disposable stress password',
        register: true,
      );
      await notebook.createVault('stress');
      final vault = notebook.vaults.single;
      await notebook.enableSync(vault);
      final note = await notebook.createNote(vault.id);
      notebook.api!.close();
      notebook.api = SiliqueApi(
        server,
        token: notebook.session!.token,
        client: transport,
      );
      var syncs = 0, errors = 0;
      scheduler = SyncCoordinator(
        api: () => notebook.api,
        synchronize: () async {
          syncs++;
          try {
            await notebook.sync();
            return true;
          } catch (_) {
            errors++;
            rethrow;
          }
        },
      );
      subscription = notebook.localChanges.listen(
        (_) => scheduler!.localChanged(),
      );
      scheduler.start();
      final text = List.filled(20000, 'long text 👩‍💻 ').join();
      for (var i = 0; i < 75; i++) {
        await notebook.save(
          notebook.notes[vault.id]![note.id]!.copyWith(body: '$text$i'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      // Stop scheduling, then drain the finite remaining durable outbox explicitly.
      scheduler.stop();
      await subscription.cancel();
      subscription = null;
      await Future<void>.delayed(const Duration(seconds: 1));
      await notebook.sync();
      expect(errors, 0);
      expect(transport.requests, lessThan(200));
      expect(notebook.storage.pending(vault.id), isEmpty);
      expect(notebook.notes[vault.id]![note.id]!.body, '${text}74');
      // ignore: avoid_print
      print(
        'REAL HTTP STRESS: 75 large-note edits, syncs=$syncs, requests=${transport.requests}, batches=${transport.batches}, errors=$errors, pending=0',
      );
    },
    skip: server == null ? 'Set disposable SILIQUE_TEST_SERVER' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'writes arriving during upload cannot keep a sync pass draining forever',
    () async {
      final dir = Directory.systemTemp.createTempSync('sync-upload-');
      final notebook = Notebook(
        storage: NativeStorage(dir.path),
        keys: MemoryKeys(),
        crypto: TestCrypto(),
      );
      addTearDown(() async {
        await notebook.close();
        dir.deleteSync(recursive: true);
      });
      await notebook.initialize();
      await notebook.connect(
        server!,
        'upload-${DateTime.now().microsecondsSinceEpoch}@example.com',
        'disposable upload password',
        register: true,
      );
      await notebook.createVault('typing');
      final vault = notebook.vaults.single;
      await notebook.enableSync(vault);
      final note = await notebook.createNote(vault.id);
      final transport = _CountingClient();
      notebook.api!.close();
      notebook.api = SiliqueApi(
        server,
        token: notebook.session!.token,
        client: transport,
      );
      var edits = 0;
      transport.rejectBatchOnce = true;
      await expectLater(
        notebook.sync(),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 409)),
      );
      expect(notebook.storage.batch(vault.id), isNotNull);
      expect(notebook.storage.pending(vault.id), isNotEmpty);
      transport.batches = 0;
      transport.onBatch = () async {
        if (++edits <= 8) {
          await notebook.save(
            notebook.notes[vault.id]![note.id]!.copyWith(
              body: 'during upload $edits',
            ),
          );
        }
      };
      await notebook.sync();
      expect(
        transport.batches,
        lessThanOrEqualTo(2),
        reason: 'A sync pass must have a finite upload budget',
      );
      expect(
        transport.batchBodies[1],
        transport.batchBodies[0],
        reason: '409 retries preserve exact encrypted bytes and batch identity',
      );
      transport.onBatch = null;
      await notebook.sync();
      expect(notebook.storage.pending(vault.id), isEmpty);
      expect(notebook.notes[vault.id]![note.id]!.body, 'during upload $edits');
    },
    skip: server == null ? 'Set disposable SILIQUE_TEST_SERVER' : false,
  );

  test('simultaneous conflict reconciliation converges without rewrite ping-pong', () async {
    final dirs = List.generate(
      2,
      (_) => Directory.systemTemp.createTempSync('sync-converge-'),
    );
    final clients = [
      for (final d in dirs)
        Notebook(
          storage: NativeStorage(d.path),
          keys: MemoryKeys(),
          crypto: TestCrypto(),
        ),
    ];
    final transports = List.generate(2, (_) => _CountingClient());
    addTearDown(() async {
      for (final c in clients) {
        await c.close();
      }
      for (final d in dirs) {
        d.deleteSync(recursive: true);
      }
    });
    final a = clients[0], b = clients[1];
    for (final c in clients) {
      await c.initialize();
    }
    final email =
        'converge-${DateTime.now().microsecondsSinceEpoch}@example.com';
    const password = 'disposable conflict test password';
    final recovery = await a.connect(server!, email, password, register: true);
    await a.createVault('conflicts');
    final vault = a.vaults.single;
    await a.enableSync(vault);
    final note = await a.createNote(vault.id);
    await a.save(note.copyWith(body: 'base'));
    await a.sync();
    await b.connect(server, email, password, recoveryKey: recovery);
    await b.sync();
    for (var i = 0; i < 2; i++) {
      clients[i].api!.close();
      clients[i].api = SiliqueApi(
        server,
        token: clients[i].session!.token,
        client: transports[i],
      );
    }
    await a.save(a.notes[vault.id]![note.id]!.copyWith(body: 'left'));
    await b.save(b.notes[vault.id]![note.id]!.copyWith(body: 'right'));
    for (var round = 0; round < 5; round++) {
      final barrier = _Barrier();
      for (final t in transports) {
        t.barrier = barrier;
      }
      await Future.wait(clients.map((c) => c.sync()));
    }
    final before = transports.fold<int>(0, (n, t) => n + t.batches);
    final barrier = _Barrier();
    for (final t in transports) {
      t.barrier = barrier;
    }
    await Future.wait(clients.map((c) => c.sync()));
    final after = transports.fold<int>(0, (n, t) => n + t.batches);
    expect(
      after,
      before,
      reason: 'Equivalent concurrent merge heads must not generate more writes',
    );
    for (final c in clients) {
      expect(c.notes[vault.id]!.values.map((n) => n.body).toSet(), {
        'left',
        'right',
      });
      expect(c.storage.pending(vault.id), isEmpty);
      for (final n in c.notes[vault.id]!.values) {
        expect(n.createdAt, note.createdAt);
      }
    }
    // ignore: avoid_print
    print(
      'CONVERGENCE: requests=${transports.fold<int>(0, (n, t) => n + t.requests)}, batches=$after; final round batches=${after - before}',
    );
  }, skip: server == null ? 'Set disposable SILIQUE_TEST_SERVER' : false);
}
