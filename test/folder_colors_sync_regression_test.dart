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
    'two real SQLite clients converge folder colors through offline, locked and stale sync',
    () async {
      final roots = List.generate(
        2,
        (_) =>
            Directory.systemTemp.createTempSync('silique-folder-colors-sync-'),
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
      const password = 'folder color sync password 12345';
      final email =
          'folder-colors-${DateTime.now().microsecondsSinceEpoch}@example.com';
      final recovery = await a.connect(
        server!,
        email,
        password,
        register: true,
      );
      await a.createVault('Colors', password: password);
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
      expect(a.folderColorsOf(id), isEmpty);
      expect(b.folderColorsOf(id), isEmpty);

      // A loses connectivity and changes a color offline; B confirms another
      // color, an unknown metadata field and a vault rename.
      a.api!.close();
      a.api = SiliqueApi(
        server,
        token: a.session!.token,
        client: MockClient(
          (_) async => http.Response('{"error":"offline"}', 503),
        ),
      );
      expect(
        await a.setFolderColor(a.vaults.single, 'Alpha', 0xFF0000FF),
        isFalse,
        reason: 'the offline color change stays local, unconfirmed',
      );
      await a.close();
      a = make(0);
      await a.initialize();
      expect(await b.setFolderColor(b.vaults.single, 'Beta', 0xFFFF0000), isTrue);
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

      // A locked sync must keep the offline color for the later merge.
      await a.sync();
      expect(a.unlocked, isNot(contains(id)));
      await a.unlock(a.vaults.single, password: password);
      await a.sync();
      await b.sync();
      await a.sync();
      for (final repo in [a, b]) {
        expect(
          repo.folderColorsOf(id),
          {'Alpha': 0xFF0000FF, 'Beta': 0xFFFF0000},
          reason: 'independent offline and remote color additions both survive',
        );
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
              'locked offline color change must preserve remote unknown metadata',
        );
      }
      final versions = [a.vaults.single.version, b.vaults.single.version];
      await a.sync();
      await b.sync();
      expect(
        [a.vaults.single.version, b.vaults.single.version],
        versions,
        reason: 'settled colors must not produce a metadata write loop',
      );

      // A stale local copy cannot keep a color the other device removed,
      // while an independent addition in the same offline window survives.
      a.api!.close();
      a.api = SiliqueApi(
        server,
        token: a.session!.token,
        client: MockClient(
          (_) async => http.Response('{"error":"offline"}', 503),
        ),
      );
      expect(
        await a.setFolderColor(a.vaults.single, 'Gamma/One', 0xFF00FF00),
        isFalse,
      );
      a.api!.close();
      a.api = SiliqueApi(server, token: a.session!.token);
      expect(await b.setFolderColor(b.vaults.single, 'Beta', null), isTrue);
      await a.sync();
      await b.sync();
      await a.sync();
      for (final repo in [a, b]) {
        expect(
          repo.folderColorsOf(id),
          {'Alpha': 0xFF0000FF, 'Gamma/One': 0xFF00FF00},
          reason:
              'a confirmed removal wins over the stale copy; the independent local addition survives',
        );
        expect(
          repo.allFolders(id),
          contains('Beta'),
          reason: 'clearing a color never removes the folder itself',
        );
      }

      // Concurrent edits of the same path converge on the confirmed server
      // color, exactly like concurrent same-parent reorders.
      a.api!.close();
      a.api = SiliqueApi(
        server,
        token: a.session!.token,
        client: MockClient(
          (_) async => http.Response('{"error":"offline"}', 503),
        ),
      );
      await a.setFolderColor(a.vaults.single, 'Alpha', 0xFF111111);
      a.api!.close();
      a.api = SiliqueApi(server, token: a.session!.token);
      await b.setFolderColor(b.vaults.single, 'Alpha', 0xFF222222);
      await a.sync();
      await b.sync();
      await a.sync();
      for (final repo in [a, b]) {
        expect(
          repo.folderColorsOf(id)['Alpha'],
          0xFF222222,
          reason: 'concurrent same-path edits use the confirmed server color',
        );
      }

      // A GET that was already in flight must not revert a newer confirmed
      // color written while the response was held.
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
      final beforeColorVersion = a.vaults.single.version;
      expect(
        await a.setFolderColor(a.vaults.single, 'Alpha', 0xFF333333),
        isTrue,
        reason: 'color PUT must be confirmed, not merely offline-tolerant: $responses',
      );
      expect(
        a.vaults.single.version,
        greaterThan(beforeColorVersion),
        reason: 'confirmed color write bumps the vault version: $responses',
      );
      release.complete();
      await overlapping;
      await b.sync();
      for (final repo in [a, b]) {
        expect(
          repo.folderColorsOf(id)['Alpha'],
          0xFF333333,
          reason: 'stale GET cannot revert a confirmed newer color',
        );
      }

      // Colors are presentation only: a stale color entry for a folder the
      // other device trashed must never recreate the folder (negative control).
      a.api!.close();
      a.api = SiliqueApi(
        server,
        token: a.session!.token,
        client: MockClient(
          (_) async => http.Response('{"error":"offline"}', 503),
        ),
      );
      await a.setFolderColor(a.vaults.single, 'Gamma', 0xFF444444);
      a.api!.close();
      a.api = SiliqueApi(server, token: a.session!.token);
      await b.trashFolder(b.vaults.single, 'Gamma');
      await a.sync();
      await b.sync();
      await a.sync();
      for (final repo in [a, b]) {
        expect(
          repo.allFolders(id),
          isNot(contains('Gamma')),
          reason: 'a stale color never recreates a trashed folder',
        );
        expect(repo.allFolders(id), isNot(contains('Gamma/One')));
        expect(
          repo.folderRowsOf(id).map((e) => e.path).toList(),
          ['Alpha', 'Beta'],
          reason: 'folder membership stays authoritative over color entries',
        );
      }
    },
    skip: server == null
        ? 'Set SILIQUE_TEST_SERVER to a disposable loopback server'
        : false,
  );
}
