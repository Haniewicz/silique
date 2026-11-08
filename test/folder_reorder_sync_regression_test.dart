import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

void main() {
  final server = Platform.environment['SILIQUE_TEST_SERVER'];
  test(
    'two real SQLite clients retain offline order through locked sync and merge independent nested order',
    () async {
      final roots = List.generate(
        2,
        (_) =>
            Directory.systemTemp.createTempSync('silique-folder-order-sync-'),
      );
      final keys = [MemoryKeys(), MemoryKeys()];
      Notebook make(int i) => Notebook(
        storage: NativeStorage(roots[i].path),
        keys: keys[i],
        crypto: TestCrypto(),
      );
      var a = make(0);
      final b = make(1);
      addTearDown(() async {
        await a.close();
        await b.close();
        for (final root in roots) {
          root.deleteSync(recursive: true);
        }
      });
      await a.initialize();
      await b.initialize();
      const password = 'folder sync password 12345';
      final email =
          'folders-${DateTime.now().microsecondsSinceEpoch}@example.com';
      final recovery = await a.connect(
        server!,
        email,
        password,
        register: true,
      );
      await a.createVault('Folders', password: password);
      final id = a.vaults.single.id;
      for (final path in ['Alpha', 'Beta', 'Gamma/One', 'Gamma/Two']) {
        await a.createFolder(a.vaults.single, path);
      }
      await a.enableSync(a.vaults.single);
      await a.sync();
      await b.connect(server, email, password, recoveryKey: recovery);
      await b.sync();
      await b.unlock(b.vaults.single, password: password);
      await b.sync();
      a.api!.close();
      a.api = SiliqueApi(
        server,
        token: a.session!.token,
        client: MockClient(
          (_) async => http.Response('{"error":"offline"}', 503),
        ),
      );
      await a.reorderFolder(a.vaults.single, 'Gamma', 'Alpha', after: false);
      await a.close();
      a = make(0);
      await a.initialize();
      await b.reorderFolder(
        b.vaults.single,
        'Gamma/Two',
        'Gamma/One',
        after: false,
      );
      await b.createFolder(b.vaults.single, 'Remote');
      await b.renameVault(b.vaults.single, 'Remote renamed');
      final bv = b.vaults.single;
      final remoteMeta = jsonDecode(
        await b.crypto.open(
          b.unlocked[id]!,
          bv.metadata,
          'silique:2:vault-meta:$id',
        ),
      ) as Map<String, dynamic>;
      remoteMeta['futureField'] = {'sentinel': 'remote change'};
      bv.metadata = await b.crypto.seal(
        b.unlocked[id]!,
        jsonEncode(remoteMeta),
        'silique:2:vault-meta:$id',
      );
      final updated = await b.api!.request(
        'PUT',
        '/v1/vaults/$id',
        body: {
          'keyWrap': bv.keyWrap,
          'metadata': bv.metadata,
          'expectedVersion': bv.version,
        },
      );
      bv.version = updated['version'] as int;
      b.storage.putVault(bv);
      b.lock(id);
      await b.unlock(bv, password: password);
      await a
          .sync(); // Protected metadata must remain available for later merge.
      expect(a.unlocked, isNot(contains(id)));
      await a.unlock(a.vaults.single, password: password);
      await a.sync();
      await b.sync();
      await a.sync();
      final expected = [
        'Gamma',
        'Gamma/Two',
        'Gamma/One',
        'Alpha',
        'Beta',
        'Remote',
      ];
      for (final repo in [a, b]) {
        expect(repo.folderRowsOf(id).map((e) => e.path).toList(), expected);
        expect(repo.vaults.single.name, 'Remote renamed');
        final meta = jsonDecode(
          await repo.crypto.open(
            repo.unlocked[id]!,
            repo.vaults.single.metadata,
            'silique:2:vault-meta:$id',
          ),
        ) as Map;
        expect(
          meta['futureField'],
          remoteMeta['futureField'],
          reason:
              'locked offline reorder must preserve remote unknown metadata',
        );
      }
      final versions = [a.vaults.single.version, b.vaults.single.version];
      await a.sync();
      await b.sync();
      expect(
        [a.vaults.single.version, b.vaults.single.version],
        versions,
        reason: 'settled order must not produce a metadata write loop',
      );
      a.api!.close();
      a.api = SiliqueApi(
        server,
        token: a.session!.token,
        client: MockClient(
          (_) async => http.Response('{"error":"offline"}', 503),
        ),
      );
      await a.reorderFolder(a.vaults.single, 'Beta', 'Alpha', after: false);
      await b.reorderFolder(b.vaults.single, 'Alpha', 'Gamma', after: false);
      a.api!.close();
      a.api = SiliqueApi(server, token: a.session!.token);
      await a.sync();
      await b.sync();
      await a.sync();
      for (final repo in [a, b]) {
        expect(
          repo.folderRowsOf(id).map((e) => e.path).toList(),
          ['Alpha', 'Gamma', 'Gamma/Two', 'Gamma/One', 'Beta', 'Remote'],
          reason: 'concurrent same-parent reorders converge on the confirmed server order',
        );
      }
      a.api!.close();
      a.api = SiliqueApi(
        server,
        token: a.session!.token,
        client: MockClient(
          (_) async => http.Response('{"error":"offline"}', 503),
        ),
      );
      await a.reorderFolder(a.vaults.single, 'Remote', 'Alpha', after: false);
      await a.close();
      a = make(0);
      await a.initialize();
      await a.unlock(a.vaults.single, password: password);
      await a.sync();
      await b.sync();
      await a.sync();
      for (final repo in [a, b]) {
        expect(
          repo.folderRowsOf(id).first.path,
          'Remote',
          reason: 'offline order-only change uploads even when the server version did not change',
        );
      }
      await b.trashFolder(b.vaults.single, 'Gamma');
      await a.sync();
      await b.sync();
      for (final repo in [a, b]) {
        expect(repo.folderRowsOf(id).map((e) => e.path).toList(), [
          'Remote',
          'Alpha',
          'Beta',
        ]);
      }
      // A GET started before a successful reorder must not undo that newer PUT.
      await a.sync();
      await b.sync();
      await a.sync();
      a.api!.close();
      final transport = http.Client();
      addTearDown(transport.close);
      final captured = Completer<void>(), release = Completer<void>();
      final responses = <String>[];
      var held = false;
      a.api = SiliqueApi(
        server,
        token: a.session!.token,
        client: MockClient((request) async {
          final copy = http.Request(request.method, request.url)
            ..headers.addAll(request.headers)
            ..bodyBytes = request.bodyBytes;
          final response = await http.Response.fromStream(
            await transport.send(copy),
          );
          responses.add(
            '${request.method} ${request.url.path} ${response.statusCode}',
          );
          if (!held &&
              request.method == 'GET' &&
              request.url.path == '/v1/vaults') {
            held = true;
            captured.complete();
            await release.future;
          }
          return response;
        }),
      );
      final overlapping = a.sync();
      await captured.future;
      final beforeReorderVersion = a.vaults.single.version;
      await a.reorderFolder(a.vaults.single, 'Beta', 'Remote', after: false);
      expect(
        a.vaults.single.version,
        greaterThan(beforeReorderVersion),
        reason:
            'reorder PUT must be confirmed, not merely offline-tolerant: $responses',
      );
      release.complete();
      await overlapping;
      await b.sync();
      for (final repo in [a, b]) {
        expect(
          repo.folderRowsOf(id).first.path,
          'Beta',
          reason: 'stale GET cannot revert a confirmed newer order',
        );
      }
    },
    skip: server == null
        ? 'Set SILIQUE_TEST_SERVER to a disposable loopback server'
        : false,
  );
}
