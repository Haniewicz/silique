import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

const _server = 'https://example.invalid';

Future<Notebook> _repo(
  Directory dir, {
  MemoryKeys? keys,
  TestCrypto? crypto,
}) async {
  final repo = Notebook(
    storage: NativeStorage(dir.path),
    keys: keys ?? MemoryKeys(),
    crypto: crypto ?? TestCrypto(),
  );
  await repo.initialize();
  repo.session = Session(
    server: _server,
    token: 'test',
    userId: 'current-user',
    email: 'a@example.invalid',
  );
  repo.accountKey = repo.crypto.randomKey();
  return repo;
}

void _enableSync(Notebook repo, String vaultId) {
  final vault = repo.vaults.firstWhere((v) => v.id == vaultId);
  vault.owner = 'current-user';
  vault.syncEnabled = true;
  repo.storage.putVault(vault);
}

void main() {
  test('journal round-trips through storage', () async {
    final dir = Directory.systemTemp.createTempSync('silique-journal-');
    final repo = await _repo(dir);
    addTearDown(() async {
      await repo.close();
      dir.deleteSync(recursive: true);
    });

    final op = SyncOperation(
      id: 'op-1',
      kind: SyncOperation.kindPull,
      vaultId: 'vault-id',
      data: 'payload',
      startedAt: DateTime.utc(2026, 1, 1, 12, 0, 0),
      status: SyncOperation.statusRunning,
    );
    await repo.storage.startOperation(op);

    final loaded = repo.storage.loadOperations();
    expect(loaded.single.kind, SyncOperation.kindPull);
    expect(loaded.single.id, 'op-1');
    expect(loaded.single.vaultId, 'vault-id');
    expect(loaded.single.data, 'payload');
    expect(loaded.single.startedAt, DateTime.utc(2026, 1, 1, 12, 0, 0));
    expect(loaded.single.status, SyncOperation.statusRunning);

    await repo.storage.settleOperation('op-1', SyncOperation.statusDone);
    expect(
      repo.storage.loadOperations().single.status,
      SyncOperation.statusDone,
    );

    // Settling a settled row is a no-op (done must not regress to failed).
    await repo.storage.settleOperation('op-1', SyncOperation.statusFailed);
    expect(
      repo.storage.loadOperations().single.status,
      SyncOperation.statusDone,
    );

    // A round-trip through JSON preserves every field.
    final decoded = SyncOperation.fromJson(
      jsonDecode(jsonEncode(op.toJson())) as Json,
    );
    expect(decoded.kind, op.kind);
    expect(decoded.id, op.id);
    expect(decoded.resumable, isTrue);
    expect(
      SyncOperation(id: 'x', kind: SyncOperation.kindAdopt, startedAt: DateTime.utc(2020), status: 'running').resumable,
      isFalse,
    );
  });

  test('a leftover running row becomes interrupted on a fresh Notebook', () async {
    final dir = Directory.systemTemp.createTempSync('silique-interrupted-');
    final storage = NativeStorage(dir.path);
    await storage.startOperation(
      SyncOperation(
        id: 'op-pull',
        kind: SyncOperation.kindPull,
        vaultId: 'some-vault',
        startedAt: DateTime.now().toUtc(),
        status: SyncOperation.statusRunning,
      ),
    );
    await storage.close();

    // A fresh Notebook over the same directory marks the row interrupted.
    final repo = await _repo(dir);
    addTearDown(() async {
      await repo.close();
      dir.deleteSync(recursive: true);
    });
    final loaded = repo.storage.loadOperations();
    expect(loaded.single.id, 'op-pull');
    expect(loaded.single.status, SyncOperation.statusInterrupted);
  });

  test('markInterruptedOperations only touches running rows', () async {
    final dir = Directory.systemTemp.createTempSync('silique-mark-');
    final repo = await _repo(dir);
    addTearDown(() async {
      await repo.close();
      dir.deleteSync(recursive: true);
    });
    await repo.storage.startOperation(
      SyncOperation(
        id: 'a',
        kind: SyncOperation.kindPull,
        startedAt: DateTime.utc(2026),
        status: SyncOperation.statusRunning,
      ),
    );
    await repo.storage.startOperation(
      SyncOperation(
        id: 'b',
        kind: SyncOperation.kindFlush,
        startedAt: DateTime.utc(2026),
        status: SyncOperation.statusDone,
      ),
    );
    await repo.storage.startOperation(
      SyncOperation(
        id: 'c',
        kind: SyncOperation.kindReset,
        startedAt: DateTime.utc(2026),
        status: SyncOperation.statusFailed,
      ),
    );

    await repo.storage.markInterruptedOperations();
    final byId = {for (final o in repo.storage.loadOperations()) o.id: o};
    expect(byId['a']!.status, SyncOperation.statusInterrupted);
    expect(byId['b']!.status, SyncOperation.statusDone);
    expect(byId['c']!.status, SyncOperation.statusFailed);
  });

  test('eraseVault clears the journal rows for that vault', () async {
    final dir = Directory.systemTemp.createTempSync('silique-journal-erase-');
    final repo = await _repo(dir);
    addTearDown(() async {
      await repo.close();
      dir.deleteSync(recursive: true);
    });
    await repo.createVault('Osobiste');
    final vault = repo.vaults.single;
    await repo.storage.startOperation(
      SyncOperation(
        id: 'op-keep',
        kind: SyncOperation.kindPull,
        vaultId: vault.id,
        startedAt: DateTime.utc(2026),
        status: SyncOperation.statusDone,
      ),
    );
    await repo.storage.startOperation(
      SyncOperation(
        id: 'op-other',
        kind: SyncOperation.kindFlush,
        vaultId: 'unrelated',
        startedAt: DateTime.utc(2026),
        status: SyncOperation.statusDone,
      ),
    );

    await repo.storage.eraseVault(vault.id);
    final remaining = repo.storage.loadOperations().map((o) => o.id).toList();
    expect(remaining, isNot(contains('op-keep')));
    expect(remaining, contains('op-other'));
  });

  test('an interrupted full pull resumes automatically once unlocked and owned', () async {
    final dir = Directory.systemTemp.createTempSync('silique-resume-pull-');
    final keys = MemoryKeys();
    final crypto = TestCrypto();

    // First run: create a synced vault, then seed a running pull row and stop
    // without settling it (simulating a crash mid-operation).
    final first = await _repo(dir, keys: keys, crypto: crypto);
    await first.createVault('Osobiste');
    final vault = first.vaults.single;
    _enableSync(first, vault.id);
    await first.storage.startOperation(
      SyncOperation(
        id: 'op-pull',
        kind: SyncOperation.kindPull,
        vaultId: vault.id,
        startedAt: DateTime.utc(2026),
        status: SyncOperation.statusRunning,
      ),
    );
    await first.close();

    // Second run: a fresh Notebook over the same storage. initialize() turns
    // the running row into interrupted, but with no cached session it does not
    // auto-fire the resume. We then wire a real (mock) api and call the resume.
    var pullRequests = 0;
    final repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: keys,
      crypto: crypto,
    );
    addTearDown(() async {
      await repo.close();
      dir.deleteSync(recursive: true);
    });
    await repo.initialize();
    expect(
      repo.storage.loadOperations().single.status,
      SyncOperation.statusInterrupted,
      reason: 'the leftover running row must first become interrupted',
    );

    repo.session = Session(
      server: _server,
      token: 'test',
      userId: 'current-user',
      email: 'a@example.invalid',
    );
    repo.api = SiliqueApi(
      _server,
      token: 'test',
      client: MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' &&
            path.contains('/v1/vaults/${vault.id}/changes')) {
          pullRequests++;
        }
        return http.Response(
          jsonEncode({
            'purged': <Object>[],
            'revisions': <Object>[],
            'cursor': 0,
            'hasMore': false,
          }),
          200,
        );
      }),
    );

    await repo.resumeInterruptedOperations();

    expect(pullRequests, greaterThan(0));
    expect(
      repo.storage.loadOperations().single.status,
      SyncOperation.statusDone,
      reason: 'the resumed idempotent pull must settle the interrupted row',
    );
  });

  test('flush and reset are resumable; adopt is never resumed automatically', () async {
    bool resumable(String kind) => SyncOperation(
      id: 'x',
      kind: kind,
      startedAt: DateTime.utc(2026),
      status: SyncOperation.statusRunning,
    ).resumable;

    expect(resumable(SyncOperation.kindPull), isTrue);
    expect(resumable(SyncOperation.kindFlush), isTrue);
    expect(resumable(SyncOperation.kindReset), isTrue);
    expect(resumable(SyncOperation.kindAdopt), isFalse);
  });

  test('a journaled operation settles failed on error and done on success via storage', () async {
    final dir = Directory.systemTemp.createTempSync('silique-settle-');
    final repo = await _repo(dir);
    addTearDown(() async {
      await repo.close();
      dir.deleteSync(recursive: true);
    });
    // Settle failure: a running row -> failed.
    await repo.storage.startOperation(
      SyncOperation(
        id: 'op-fail',
        kind: SyncOperation.kindFlush,
        startedAt: DateTime.utc(2026),
        status: SyncOperation.statusRunning,
      ),
    );
    await repo.storage.settleOperation('op-fail', SyncOperation.statusFailed);
    expect(repo.storage.loadOperations().single.status, SyncOperation.statusFailed);

    // Settle success: a fresh running row -> done.
    await repo.storage.startOperation(
      SyncOperation(
        id: 'op-done',
        kind: SyncOperation.kindPull,
        startedAt: DateTime.utc(2026),
        status: SyncOperation.statusRunning,
      ),
    );
    await repo.storage.settleOperation('op-done', SyncOperation.statusDone);
    expect(
      repo.storage.loadOperations().firstWhere((o) => o.id == 'op-done').status,
      SyncOperation.statusDone,
    );
  });
}