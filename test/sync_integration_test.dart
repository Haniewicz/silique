import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:silique/services/notebook.dart';
import 'package:silique/services/sync_coordinator.dart';
import 'package:silique/services/api.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;
import 'fixtures/image_fixtures.dart';

class LostAcknowledgement extends http.BaseClient {
  final inner = http.Client();
  bool failed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner.send(request);
    if (!failed &&
        request.method == 'POST' &&
        request.url.path.endsWith('/batches')) {
      failed = true;
      await response.stream.drain<void>();
      throw http.ClientException(
        'Simulated connection loss AFTER server commit',
      );
    }
    return response;
  }

  @override
  void close() => inner.close();
}

class LostImageAcknowledgement extends http.BaseClient {
  final inner = http.Client();
  bool failed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner.send(request);
    if (!failed &&
        request.method == 'PUT' &&
        request.url.path.endsWith('/chunks/1')) {
      failed = true;
      await response.stream.drain<void>();
      throw http.ClientException('Image ACK lost after commit');
    }
    return response;
  }

  @override
  void close() => inner.close();
}

void main() {
  final server = Platform.environment['SILIQUE_TEST_SERVER'];
  test('foreground devices receive a new note in seconds without periodic full sync', () async {
    final dirs = List.generate(
      2,
      (_) => Directory.systemTemp.createTempSync('silique-live-'),
    );
    final clients = [
      for (final dir in dirs)
        Notebook(
          storage: NativeStorage(dir.path),
          keys: MemoryKeys(),
          crypto: TestCrypto(),
        ),
    ];
    final a = clients[0], b = clients[1];
    final coordinators = <SyncCoordinator>[];
    final subscriptions = <StreamSubscription<void>>[];
    addTearDown(() async {
      for (final c in coordinators) {
        c.stop();
      }
      for (final s in subscriptions) {
        await s.cancel();
      }
      // Drain cancellation before closing transports and temporary databases.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      for (final client in clients) {
        await client.close();
      }
      for (final dir in dirs) {
        dir.deleteSync(recursive: true);
      }
    });
    for (final client in clients) {
      await client.initialize();
    }
    final email = 'live-${DateTime.now().microsecondsSinceEpoch}@example.com';
    const password = 'foreground sync test password 12345';
    final recovery = await a.connect(server!, email, password, register: true);
    await a.createVault('Live');
    final vault = a.vaults.single;
    await a.enableSync(vault);
    await b.connect(server, email, password, recoveryKey: recovery);
    final counts = [0, 0];
    for (var i = 0; i < clients.length; i++) {
      final client = clients[i];
      final c = SyncCoordinator(
        api: () => client.api,
        synchronize: () async {
          counts[i]++;
          await client.sync();
          return true;
        },
      );
      coordinators.add(c);
      subscriptions.add(client.localChanges.listen((_) => c.localChanged()));
      c.start();
    }
    Future<void> until(bool Function() ready) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!ready()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Device did not receive change within 5 seconds');
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }

    await until(() => b.vaults.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final started = Stopwatch()..start();
    final note = await a.createNote(vault.id);
    await a.save(note.copyWith(title: 'New on A', body: '😀 new note'));
    await until(() => b.notes[vault.id]?[note.id]?.body == '😀 new note');
    final elapsed = started.elapsedMilliseconds;
    // Check both directions, including software-typed Unicode and an edit.
    await b.save(b.notes[vault.id]![note.id]!.copyWith(body: 'From B 👩‍💻'));
    await until(() => a.notes[vault.id]?[note.id]?.body == 'From B 👩‍💻');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await Future<void>.delayed(const Duration(seconds: 1));
    final idleCounts = List<int>.of(counts);
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(
      counts,
      idleCounts,
      reason: 'Idle listeners must not launch full synchronization',
    );
    // ignore: avoid_print
    print(
      'New note A -> B: $elapsed ms; idle full-sync counts unchanged: $counts',
    );
  }, skip: server == null ? 'Set SILIQUE_TEST_SERVER' : false);
  test(
    'two clients: account recovery, merge, encrypted conflict copies, deletions and lost acknowledgement after restart',
    () async {
      final dirs = [
        Directory.systemTemp.createTempSync('silique-a-'),
        Directory.systemTemp.createTempSync('silique-b-'),
      ];
      final keys = [MemoryKeys(), MemoryKeys()];
      Notebook make(int i) => Notebook(
        storage: NativeStorage(dirs[i].path),
        keys: keys[i],
        crypto: TestCrypto(),
      );
      var a = make(0);
      final b = make(1);
      await a.initialize();
      await b.initialize();
      final email =
              Platform.environment['SILIQUE_TEST_EMAIL'] ??
              'test-${DateTime.now().microsecondsSinceEpoch}@example.com',
          password =
              Platform.environment['SILIQUE_TEST_PASSWORD'] ??
              'integration test password 12345';
      final recovery = await a.connect(
        server!,
        email,
        password,
        register: Platform.environment['SILIQUE_TEST_EMAIL'] == null,
      );
      expect(recovery, isNotNull);
      await a.createVault('Sync test');
      final vault = a.vaults.single;
      await a.enableSync(vault);
      final note = await a.createNote(vault.id);
      await a.save(note.copyWith(title: 'Note', body: 'first\nsecond\nthird'));
      await a.sync();
      await b.connect(server, email, password, recoveryKey: recovery);
      await b.sync();
      expect(b.notes[vault.id]![note.id]!.body, 'first\nsecond\nthird');
      expect(b.notes[vault.id]![note.id]!.createdAt, note.createdAt);
      await a.save(
        a.notes[vault.id]![note.id]!.copyWith(body: 'FIRST\nsecond\nthird'),
      );
      await b.save(
        b.notes[vault.id]![note.id]!.copyWith(body: 'first\nsecond\nTHIRD'),
      );
      await a.sync();
      await b.sync();
      await a.sync();
      expect(a.notes[vault.id]![note.id]!.body, 'FIRST\nsecond\nTHIRD');
      expect(b.notes[vault.id]![note.id]!.body, 'FIRST\nsecond\nTHIRD');
      await a.save(a.notes[vault.id]![note.id]!.copyWith(body: 'version A'));
      await b.save(b.notes[vault.id]![note.id]!.copyWith(body: 'version B'));
      await a.sync();
      await b.sync();
      await a.sync();
      await b.sync();
      final aBodies = a.notes[vault.id]!.values
          .where((n) => !n.deleted)
          .map((n) => n.body)
          .toSet();
      expect(aBodies, containsAll(['version A', 'version B']));
      final bBodies = b.notes[vault.id]!.values
          .where((n) => !n.deleted)
          .map((n) => n.body)
          .toSet();
      expect(bBodies, aBodies);
      for (final client in [a, b]) {
        final copies = client.notes[vault.id]!.values.where((n) => n.conflict);
        expect(copies, isNotEmpty);
        for (final copy in copies) {
          expect(
            copy.createdAt,
            note.createdAt,
            reason: 'Conflict copies retain the original creation date',
          );
        }
      }
      await a.save(
        a.notes[vault.id]![note.id]!.copyWith(
          body: 'survives lost acknowledgement',
        ),
      );
      final fail = LostAcknowledgement();
      a.api = SiliqueApi(server, token: a.session!.token, client: fail);
      await expectLater(a.sync(), throwsA(isA<http.ClientException>()));
      final batch = a.storage.batch(vault.id);
      expect(batch, isNotNull);
      await a.close();
      a = make(0);
      await a.initialize();
      expect(a.notes[vault.id]![note.id]!.createdAt, note.createdAt);
      for (final copy in a.notes[vault.id]!.values.where((n) => n.conflict)) {
        expect(copy.createdAt, note.createdAt);
      }
      expect(a.storage.batch(vault.id)!['batchId'], batch!['batchId']);
      await a.sync();
      expect(a.storage.batch(vault.id), isNull);
      await b.sync();
      expect(
        b.notes[vault.id]![note.id]!.body,
        'survives lost acknowledgement',
      );
      await a.save(a.notes[vault.id]![note.id]!.copyWith(deleted: true));
      await b.save(
        b.notes[vault.id]![note.id]!.copyWith(body: 'edit beats deletion'),
      );
      await a.sync();
      await b.sync();
      await a.sync();
      expect(a.notes[vault.id]![note.id]!.deleted, false);
      expect(a.notes[vault.id]![note.id]!.body, 'edit beats deletion');
      final staleCopy = b.notes[vault.id]![note.id]!;
      await a.save(a.notes[vault.id]![note.id]!.copyWith(deleted: true));
      await a.purgeNote(a.notes[vault.id]![note.id]!);
      await b.save(staleCopy.copyWith(body: 'must never resurrect'));
      await b.sync();
      await a.sync();
      expect(a.notes[vault.id]!.containsKey(note.id), false);
      expect(b.notes[vault.id]!.containsKey(note.id), false);
      expect(b.storage.revisions(vault.id, noteId: note.id), isEmpty);

      await a.close();
      await b.close();
      for (final d in dirs) {
        d.deleteSync(recursive: true);
      }
    },
    skip: server == null
        ? 'Set SILIQUE_TEST_SERVER to a disposable public-registration Silique server'
        : false,
  );
  test('device pairing compares authenticated codes before transferring account keys', () async {
    final dirs = [
      Directory.systemTemp.createTempSync('silique-pair-a-'),
      Directory.systemTemp.createTempSync('silique-pair-b-'),
    ];
    final a = Notebook(
      storage: NativeStorage(dirs[0].path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    final b = Notebook(
      storage: NativeStorage(dirs[1].path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await a.initialize();
    await b.initialize();
    final email = 'pair-${DateTime.now().microsecondsSinceEpoch}@example.com',
        password = 'pairing test password 12345';
    await a.connect(server!, email, password, register: true);
    await a.createVault('Pairing');
    final vault = a.vaults.single;
    await a.enableSync(vault);
    final note = await a.createNote(vault.id);
    await a.save(note.copyWith(body: 'available only after pairing'));
    await a.sync();
    await b.connect(server, email, password);
    expect(b.accountKey, isNull);
    await b.sync();
    expect(b.vaults, isEmpty);
    final request = (await a.pairings()).single;
    final offered = await a.offerPairing(request);
    final incoming = (await b.pairings()).single;
    expect(
      (await a.pairingDetails(offered)).code,
      (await b.pairingDetails(incoming)).code,
    );
    await expectLater(
      b.pairingDetails({
        ...incoming,
        'requesterKey': a.deviceIdentity['public'],
      }),
      throwsFormatException,
    );
    expect(await b.finishPairing(incoming), false);
    await a.approvePairing(offered);
    expect(await b.finishPairing((await b.pairings()).single), true);
    await b.sync();
    expect(b.notes[vault.id]![note.id]!.body, 'available only after pairing');
    await a.close();
    await b.close();
    for (final d in dirs) {
      d.deleteSync(recursive: true);
    }
  }, skip: server == null ? 'Set SILIQUE_TEST_SERVER' : false);
  test('device name and folders are visible to a second client and survive restart', () async {
    final dirs = [
      Directory.systemTemp.createTempSync('silique-ws-a-'),
      Directory.systemTemp.createTempSync('silique-ws-b-'),
    ];
    final keysA = MemoryKeys();
    var a = Notebook(
      storage: NativeStorage(dirs[0].path),
      keys: keysA,
      crypto: TestCrypto(),
    );
    final b = Notebook(
      storage: NativeStorage(dirs[1].path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await a.initialize();
    await b.initialize();
    final email = 'ws-${DateTime.now().microsecondsSinceEpoch}@example.com';
    const password = 'workspace test password 12345';
    final recovery = await a.connect(server!, email, password, register: true);
    expect(recovery, isNotNull);
    await a.createVault('Workspace');
    final vault = a.vaults.single;
    await a.enableSync(vault);
    await a.createFolder(vault, 'Projekty/Mercaro');
    final note = await a.createNote(vault.id, folder: 'Projekty/Mercaro');
    await a.save(note.copyWith(body: 'folder sync'));
    expect(
      await a.renameDevice(a.deviceId, '  Laptop workspace  '),
      'Laptop workspace',
    );
    await a.sync();

    await b.connect(server, email, password, recoveryKey: recovery);
    await b.sync();
    expect(
      b.allFolders(vault.id),
      containsAll(['Projekty', 'Projekty/Mercaro']),
    );
    expect(b.notes[vault.id]![note.id]!.folder, 'Projekty/Mercaro');
    await b.refreshDevices();
    expect(
      b.devices!.firstWhere((device) => device['id'] == a.deviceId)['name'],
      'Laptop workspace',
    );

    await a.close();
    a = Notebook(
      storage: NativeStorage(dirs[0].path),
      keys: keysA,
      crypto: TestCrypto(),
    );
    await a.initialize();
    expect(await a.deviceName(), 'Laptop workspace');
    expect(a.foldersOf(vault.id), contains('Projekty/Mercaro'));
    await expectLater(a.renameDevice(a.deviceId, '   '), throwsFormatException);
    await a.close();
    await b.close();
    for (final dir in dirs) {
      dir.deleteSync(recursive: true);
    }
  }, skip: server == null ? 'Set SILIQUE_TEST_SERVER' : false);
  test('large image attachments resume after lost ACK, sync encrypted and remain available offline', () async {
    final dirs = [
      Directory.systemTemp.createTempSync('silique-image-a-'),
      Directory.systemTemp.createTempSync('silique-image-b-'),
    ];
    final keys = [MemoryKeys(), MemoryKeys()];
    Notebook make(int i) => Notebook(
      storage: NativeStorage(dirs[i].path),
      keys: keys[i],
      crypto: TestCrypto(),
    );
    var a = make(0);
    final b = make(1);
    await a.initialize();
    await b.initialize();
    final email =
        Platform.environment['SILIQUE_TEST_EMAIL'] ??
        'images-${DateTime.now().microsecondsSinceEpoch}@example.com';
    final password =
        Platform.environment['SILIQUE_TEST_PASSWORD'] ??
        'large image sync test password 12345';
    final recovery = await a.connect(
      server!,
      email,
      password,
      register: Platform.environment['SILIQUE_TEST_EMAIL'] == null,
    );
    expect(recovery, isNotNull);
    await a.createVault('Image test');
    final vault = a.vaults.single;
    await a.enableSync(vault);
    final note = await a.createNote(vault.id);
    final bytes = sampleBmp(width: 1536, height: 500);
    final reference = await a.addImage(vault.id, note.id, bytes, 'image/bmp');
    final id = reference.split(':').last;
    await a.save(note.copyWith(body: '![large]($reference)'));
    a.api!.close();
    a.api = SiliqueApi(
      server,
      token: a.session!.token,
      client: LostImageAcknowledgement(),
    );
    await expectLater(a.sync(), throwsA(isA<http.ClientException>()));
    expect(a.storage.pendingImages(vault.id), hasLength(1));
    await a.close();
    a = make(0);
    await a.initialize();
    await a.sync();
    expect(a.storage.pendingImages(vault.id), isEmpty);
    await b.connect(server, email, password, recoveryKey: recovery);
    await b.sync();
    expect(await b.imageBytes(vault.id, id), bytes);
    b.api!.close();
    b.api = null;
    expect(await b.imageBytes(vault.id, id), bytes);
    b.api = SiliqueApi(server, token: b.session!.token);
    await a.save(a.notes[vault.id]![note.id]!.copyWith(deleted: true));
    await a.purgeNote(a.notes[vault.id]![note.id]!);
    await b.sync();
    expect(b.storage.imageAsset(vault.id, id), isNull);
    await expectLater(b.imageBytes(vault.id, id), throwsA(anything));
    await a.close();
    await b.close();
    for (final dir in dirs) {
      dir.deleteSync(recursive: true);
    }
  }, skip: server == null ? 'Set SILIQUE_TEST_SERVER' : false);
}
