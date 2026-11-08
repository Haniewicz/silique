// Independent review: see docs/workspace-review-2026-10-20.md.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/services/api.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

class _Clients {
  _Clients(this.server, {this.protected = false}) {
    a = make(0);
    b = make(1);
  }
  final String server;
  final bool protected;
  final roots = [
    Directory.systemTemp.createTempSync('silique-review-sync-a-'),
    Directory.systemTemp.createTempSync('silique-review-sync-b-'),
  ];
  final keys = [MemoryKeys(), MemoryKeys()];
  static const password = 'workspace review password 12345';
  late Notebook a, b;
  late String vaultId;
  Notebook make(int i) => Notebook(
    storage: NativeStorage(roots[i].path),
    keys: keys[i],
    crypto: TestCrypto(),
  );
  Future<void> setup() async {
    await a.initialize();
    await b.initialize();
    final email = 'review-${DateTime.now().microsecondsSinceEpoch}@example.com';
    final recovery = await a.connect(server, email, password, register: true);
    await a.createVault('Review', password: protected ? password : null);
    final vault = a.vaults.single;
    vaultId = vault.id;
    await a.createFolder(vault, 'Initial');
    await a.enableSync(vault);
    await a.sync();
    await b.connect(server, email, password, recoveryKey: recovery);
    await b.sync();
    await unlockIfNeeded(b);
    expect(b.foldersOf(vaultId), contains('Initial'));
  }

  Future<void> unlockIfNeeded(Notebook repo) async {
    if (protected && !repo.unlocked.containsKey(vaultId)) {
      await repo.unlock(repo.vaults.single, password: password);
    }
  }

  Future<void> createOfflineAndRestart() async {
    a.api!.close();
    a.api = SiliqueApi(
      server,
      token: a.session!.token,
      client: MockClient(
        (_) async => http.Response('{"error":"offline"}', 503),
      ),
    );
    await a.createFolder(a.vaults.single, 'Offline local');
    await a.close();
    a = make(0);
    await a.initialize();
    await unlockIfNeeded(a);
    expect(a.foldersOf(vaultId), contains('Offline local'));
  }

  Future<void> close() async {
    await a.close();
    await b.close();
    for (final root in roots) {
      root.deleteSync(recursive: true);
    }
  }
}

void main() {
  final server = Platform.environment['SILIQUE_TEST_SERVER'];
  final skip = server == null
      ? 'Set SILIQUE_TEST_SERVER to a disposable local server'
      : false;
  Future<_Clients> clients({bool protected = false}) async {
    final value = _Clients(server!, protected: protected);
    addTearDown(value.close);
    await value.setup();
    return value;
  }

  test('review: offline folder metadata survives restart and merges with another client', () async {
    final c = await clients();
    await c.createOfflineAndRestart();
    await c.b.createFolder(c.b.vaults.single, 'Remote change');
    await c.a.sync();
    await c.b.sync();
    for (final repo in [c.a, c.b]) {
      expect(
        repo.foldersOf(c.vaultId),
        containsAll(['Initial', 'Offline local', 'Remote change']),
      );
    }
  }, skip: skip);
  test('review: offline folder uploads after restart with an unchanged server version', () async {
    final c = await clients();
    await c.createOfflineAndRestart();
    await c.a.sync();
    await c.b.sync();
    for (final repo in [c.a, c.b]) {
      expect(
        repo.foldersOf(c.vaultId),
        containsAll(['Initial', 'Offline local']),
      );
    }
  }, skip: skip);
  test(
    'review: a stale client must not resurrect a remotely renamed folder',
    () async {
      final c = await clients();
      await c.a.renameFolder(c.a.vaults.single, 'Initial', 'Renamed');
      await c.b.sync();
      await c.a.sync();
      for (final repo in [c.a, c.b]) {
        expect(repo.foldersOf(c.vaultId), contains('Renamed'));
        expect(repo.foldersOf(c.vaultId), isNot(contains('Initial')));
      }
    },
    skip: skip,
  );
  test('review: protected vault keeps offline folders when another client changes metadata', () async {
    final c = await clients(protected: true);
    await c.createOfflineAndRestart();
    await c.b.createFolder(c.b.vaults.single, 'Remote change');
    await c.a.sync();
    await c.unlockIfNeeded(c.a);
    await c.a.sync();
    await c.b.sync();
    await c.unlockIfNeeded(c.b);
    await c.b.sync();
    for (final repo in [c.a, c.b]) {
      expect(
        repo.foldersOf(c.vaultId),
        containsAll(['Initial', 'Offline local', 'Remote change']),
      );
    }
  }, skip: skip);
  test('review: locked protected vault adopts a new password wrap along with remote folder changes', () async {
    final c = await clients(protected: true);
    await c.b.sync(); // Establish the server-confirmed baseline before locking.
    c.b.lock(c.vaultId);
    await c.a.createFolder(c.a.vaults.single, 'Remote change');
    const changedPassword = 'changed protected password 67890';
    await c.a.changeVaultPassword(c.a.vaults.single, changedPassword);
    await c.b.sync();
    expect(c.b.vaults.single.keyWrap, c.a.vaults.single.keyWrap);
    await c.b.unlock(c.b.vaults.single, password: changedPassword);
    await c.b.sync();
    expect(c.b.foldersOf(c.vaultId), containsAll(['Initial', 'Remote change']));
  }, skip: skip);
}
