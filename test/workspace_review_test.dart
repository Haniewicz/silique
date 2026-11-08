// Independent review: see docs/workspace-review-2026-10-20.md.
import 'dart:io';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/span_size.dart';
import 'package:silique/core/models.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/services/api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

void main() {
  test(
    'review: a recorded root with mirrors but no database requires recovery',
    () {
      final temp = Directory.systemTemp.createTempSync(
        'silique-review-missing-db-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final support = Directory('${temp.path}/support')..createSync();
      final root = Directory('${temp.path}/Vaults')..createSync();
      final mirror = File('${root.path}/markdown/vault/note.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('# Preserve me');
      NativeStorage.persistChosenRoot(support.path, root.path);
      expect(
        () => NativeStorage.existingRoot(support.path),
        throwsA(isA<StorageLocationUnavailable>()),
      );
      expect(mirror.readAsStringSync(), '# Preserve me');
      expect(File('${root.path}/silique.sqlite').existsSync(), false);
    },
  );
  test(
    'review: chosen storage location reopens with its existing Markdown files',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'silique-review-chosen-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final support = Directory('${temp.path}/support')..createSync();
      final root = Directory('${temp.path}/User chosen vaults')..createSync();
      final storage = NativeStorage(root.path);
      // Mirrors now require a live parent identity: a stale post-delete note
      // must not create an orphan Markdown directory.
      storage.putVault(
        Vault(
          id: 'vault',
          name: 'Test',
          mode: 'account',
          keyWrap: '',
          localWrap: '',
          metadata: '',
        ),
      );
      await storage.mirror(
        Note(
          id: 'note',
          vaultId: 'vault',
          title: 'Test',
          body: 'keep',
          updatedAt: DateTime.now(),
        ),
      );
      await storage.close();
      File('${support.path}/silique-location.txt').writeAsStringSync(root.path);
      expect(NativeStorage.resolveRoot(support.path), root.path);
      expect(
        File('${root.path}/markdown/vault/note.md').readAsStringSync(),
        contains('keep'),
      );
    },
  );
  test(
    'review: legacy nova database stays available before location selection',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'silique-review-legacy-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final support = Directory('${temp.path}/support')..createSync();
      final old = Directory('${support.path}/Nova Notes')..createSync();
      final storage = NativeStorage(old.path);
      await storage.close();
      File('${old.path}/silique.sqlite').renameSync('${old.path}/nova.sqlite');
      expect(
        NativeStorage.resolveRoot(support.path),
        '${support.path}/Silique',
      );
    },
  );
  test('review: formatting multiline keeps selection through final selected character', () {
    final formatted = applySpanFontSize(
      'one\ntwo',
      const TextSelection(baseOffset: 0, extentOffset: 7),
      20,
    )!;
    expect(
      formatted.text.substring(formatted.selection.end),
      closeSpanFontSizeTag,
    );
    final reformatted = applySpanFontSize(
      formatted.text,
      formatted.selection,
      30,
    )!;
    expect(RegExp('font-size:20px').hasMatch(reformatted.text), isFalse);
    expect(RegExp('font-size:30px').allMatches(reformatted.text).length, 2);
  });
  test(
    'review: inferred parent already exists and cannot be recreated',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'silique-review-folders-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final repo = Notebook(
        storage: NativeStorage(temp.path),
        keys: MemoryKeys(),
        crypto: TestCrypto(),
      );
      await repo.initialize();
      await repo.createVault('test');
      final v = repo.vaults.single;
      await repo.createNote(v.id, folder: 'A/B');
      addTearDown(repo.close);
      await expectLater(repo.createFolder(v, 'A'), throwsStateError);
    },
  );
  test(
    'review: reported metadata failure must not partially move folder notes',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'silique-review-failure-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final repo = Notebook(
        storage: NativeStorage(temp.path),
        keys: MemoryKeys(),
        crypto: TestCrypto(),
      );
      await repo.initialize();
      await repo.createVault('test');
      final v = repo.vaults.single;
      await repo.createFolder(v, 'A');
      final note = await repo.createNote(v.id, folder: 'A');
      v.owner = 'http://localhost|user';
      v.syncEnabled = true;
      repo.storage.putVault(v);
      repo.session = Session(
        server: 'http://localhost',
        token: 'test',
        userId: 'user',
        email: 'test@example.com',
      );
      repo.api = SiliqueApi(
        'http://localhost',
        token: 'test',
        client: MockClient(
          (_) async => http.Response('{"error":"unavailable"}', 503),
        ),
      );
      addTearDown(repo.close);
      var failed = false;
      try {
        await repo.renameFolder(v, 'A', 'B');
      } catch (_) {
        failed = true;
      }
      // Either commit the entire change locally and queue synchronization, or
      // report failure without changing the existing folder.
      expect(repo.notes[v.id]![note.id]!.folder, failed ? 'A' : 'B');
    },
  );
  test('review: synced vault creates folders offline and preserves them after restart', () async {
    final temp = Directory.systemTemp.createTempSync('silique-review-offline-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final keys = MemoryKeys();
    var repo = Notebook(
      storage: NativeStorage(temp.path),
      keys: keys,
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('test');
    final vault = repo.vaults.single;
    vault.owner = 'http://localhost|user';
    vault.syncEnabled = true;
    repo.storage.putVault(vault);
    repo.session = Session(
      server: 'http://localhost',
      token: 'test',
      userId: 'user',
      email: 'test@example.com',
    );
    repo.api = SiliqueApi(
      'http://localhost',
      token: 'test',
      client: MockClient(
        (_) async => http.Response('{"error":"offline"}', 503),
      ),
    );
    addTearDown(() => repo.close());
    await repo.createFolder(vault, 'Offline folder');
    expect(repo.foldersOf(vault.id), contains('Offline folder'));
    await repo.close();
    repo = Notebook(
      storage: NativeStorage(temp.path),
      keys: keys,
      crypto: TestCrypto(),
    );
    await repo.initialize();
    expect(repo.foldersOf(vault.id), contains('Offline folder'));
  });
  test('review: failed folder upload cannot report successful sync', () async {
    final temp = Directory.systemTemp.createTempSync(
      'silique-review-meta-sync-',
    );
    addTearDown(() => temp.deleteSync(recursive: true));
    final repo = Notebook(
      storage: NativeStorage(temp.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    addTearDown(repo.close);
    await repo.createVault('Protected', password: 'valid protected password');
    final vault = repo.vaults.single;
    await repo.createFolder(vault, 'Confirmed');
    final metadata = vault.metadata;
    vault.owner = 'http://localhost|user';
    vault.syncEnabled = true;
    vault.version = 1;
    repo.session = Session(
      server: 'http://localhost',
      token: 'test',
      userId: 'user',
      email: 'test@example.com',
    );
    repo.accountKey = Uint8List(32);
    repo.api = SiliqueApi(
      'http://localhost',
      token: 'test',
      client: MockClient((request) async {
        if (request.method == 'PUT') {
          return http.Response('{"error":"offline"}', 503);
        }
        if (request.url.path == '/v1/vaults') {
          return http.Response(
            jsonEncode({
              'vaults': [
                {
                  'id': vault.id,
                  'keyWrap': vault.keyWrap,
                  'metadata': metadata,
                  'version': 1,
                },
              ],
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/changes')) {
          return http.Response(
            '{"revisions":[],"cursor":0,"hasMore":false}',
            200,
          );
        }
        throw StateError(
          'Unexpected request: ${request.method} ${request.url.path}',
        );
      }),
    );
    await repo.createFolder(vault, 'Offline');
    await expectLater(repo.sync(), throwsStateError);
    expect(repo.foldersOf(vault.id), containsAll(['Confirmed', 'Offline']));
  });
}
