import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

class _Observe extends http.BaseClient {
  final inner = http.Client();
  final writes = <String>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.method != 'GET') writes.add(request.url.path);
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}

void main() {
  final server = Platform.environment['SILIQUE_TEST_SERVER'];
  test(
    'two SQLite clients: whole-vault deletion retires hidden data and offline outbox before upload and survives reopen',
    () async {
      final dirs = List.generate(
        2,
        (_) => Directory.systemTemp.createTempSync('vault-delete-peer-'),
      );
      final keyStores = List.generate(2, (_) => MemoryKeys());
      final clients = [
        for (var i = 0; i < 2; i++)
          Notebook(
            storage: NativeStorage(dirs[i].path),
            keys: keyStores[i],
            crypto: TestCrypto(),
          ),
      ];
      addTearDown(() async {
        for (final client in clients) {
          await client.close();
        }
        for (final dir in dirs) {
          dir.deleteSync(recursive: true);
        }
      });
      final a = clients[0], b = clients[1];
      for (final client in clients) {
        await client.initialize();
      }
      final email =
          'vault-delete-${DateTime.now().microsecondsSinceEpoch}@example.com';
      const password = 'synthetic account password 0123456';
      final recovery = await a.connect(
        server!,
        email,
        password,
        register: true,
      );
      await a.createVault('Remote target');
      final target = a.vaults.single;
      await a.enableSync(target);
      final ordinary = await a.createNote(target.id);
      await a.setHiddenPassword('synthetic hidden password');
      final hidden = await a.createHiddenNote(target.id);
      await a.save(hidden.copyWith(body: 'HIDDEN_DELETE_SENTINEL'));
      await a.createVault('Keep');
      final keep = a.vaults.last;
      await a.enableSync(keep);
      final keepNote = await a.createNote(keep.id);
      await a.sync();
      await b.connect(server, email, password, recoveryKey: recovery);
      await b.sync();
      await b.unlockHidden('synthetic hidden password');
      final oldHidden = (await b.hiddenNotes(target.id)).single;
      await b.save(oldHidden.copyWith(body: 'pending hidden offline'));
      await b.save(
        b.notes[target.id]![ordinary.id]!.copyWith(
          body: 'pending ordinary offline',
        ),
      );
      await b.addImage(
        target.id,
        ordinary.id,
        Uint8List.fromList(List.filled(100, 3)),
        'image/png',
      );
      expect(b.storage.pending(target.id), isNotEmpty);
      expect(b.storage.pendingImages(target.id), isNotEmpty);
      final stale = b.vaults.firstWhere((v) => v.id == target.id);
      final current = a.vaults.firstWhere((v) => v.id == target.id);
      await a.deleteVault(current, confirmation: 'Remote target');
      final observer = _Observe();
      b.api!.close();
      b.api = SiliqueApi(server, token: b.session!.token, client: observer);
      b.accountKey = null;
      b.lock(target.id);
      await b.sync();
      expect(observer.writes, isEmpty);
      expect(b.storage.isVaultDeleted(target.id), isTrue);
      expect(b.storage.documents('hidden:${target.id}'), isEmpty);
      expect(b.storage.pending(target.id), isEmpty);
      expect(b.storage.pendingImages(target.id), isEmpty);
      expect(b.vaults.map((v) => v.id), [keep.id]);
      expect(b.notes[keep.id], contains(keepNote.id));
      await expectLater(
        b.api!.request(
          'PUT',
          '/v1/vaults/${target.id}',
          body: {
            'metadata': stale.metadata,
            'keyWrap': stale.keyWrap,
            'expectedVersion': 0,
          },
        ),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 410)),
      );
      final live = await a.api!.request('GET', '/v1/vaults');
      expect(live['deletedVaults'], contains(target.id));
      expect(jsonEncode(live['vaults']), isNot(contains(target.id)));
      await b.close();
      final reopened = Notebook(
        storage: NativeStorage(dirs[1].path),
        keys: keyStores[1],
        crypto: TestCrypto(),
      );
      clients[1] = reopened;
      await reopened.initialize();
      await reopened.sync();
      expect(reopened.vaults.map((v) => v.id), [keep.id]);
      expect(reopened.storage.documents(target.id), isEmpty);
    },
    skip: server == null
        ? 'Requires disposable loopback SILIQUE_TEST_SERVER'
        : false,
  );
}
