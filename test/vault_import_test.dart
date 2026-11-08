import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/storage/vault_import.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;
import 'fixtures/image_fixtures.dart';

class _FailingStorage extends NativeStorage {
  _FailingStorage(super.root);
  int? failAt;
  int writes = 0;
  @override
  void putDocument(String vaultId, String noteId, String document) {
    super.putDocument(vaultId, noteId, document);
    if (++writes == failAt) throw StateError('Simulated disk failure');
  }
}

void main() {
  late Directory root, source;
  late MemoryKeys keys;
  late _FailingStorage storage;
  late Notebook repo;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('silique-import-test-');
    source = Directory('${root.path}/source')..createSync();
    keys = MemoryKeys();
    storage = _FailingStorage('${root.path}/store');
    repo = Notebook(storage: storage, keys: keys, crypto: TestCrypto());
    await repo.initialize();
    await repo.createVault('Local');
  });
  tearDown(() async {
    await repo.close();
    root.deleteSync(recursive: true);
  });

  void write(String path, String body) {
    final f = File('${source.path}/$path');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(body);
  }

  test(
    'last vault survives restart, including a locked protected vault',
    () async {
      final first = repo.vaults.single.id;
      await repo.createVault('Secret', password: 'import-test-passphrase');
      final last = repo.vaults.last.id;
      await repo.rememberVault(last);
      await repo.close();
      repo = Notebook(
        storage: NativeStorage('${root.path}/store'),
        keys: keys,
        crypto: TestCrypto(),
      );
      await repo.initialize();
      expect(repo.lastVaultId, last);
      expect(repo.unlocked.containsKey(last), false);
      await repo.rememberVault(first);
      await expectLater(repo.rememberVault('missing'), throwsStateError);
      expect(repo.lastVaultId, first);
      await keys.write('nova.lastVault', 'removed');
      await repo.close();
      repo = Notebook(
        storage: NativeStorage('${root.path}/store'),
        keys: keys,
        crypto: TestCrypto(),
      );
      await repo.initialize();
      expect(repo.lastVaultId, repo.vaults.first.id);
    },
  );

  test('imports hierarchy, empty folders, original titles, images and exact note links', () async {
    write(
      'Start.md',
      '# Different heading\n[child](A/Same.md)\n![[assets/photo.bmp]]',
    );
    write(
      'A/Same.md',
      '[[B/Same|Second]]\n![[B/Same|Embedded note]]\n![photo](../assets/photo.bmp)',
    );
    write('B/Same.md', 'Żółć 😀');
    write('Text.TXT', '\ufeffplain');
    write('.obsidian/ignored.md', 'settings');
    write('manual.pdf', 'unsupported');
    Directory('${source.path}/Empty/Nested').createSync(recursive: true);
    Directory('${source.path}/assets').createSync();
    final image = sampleBmp(width: 4, height: 4);
    File('${source.path}/assets/photo.bmp').writeAsBytesSync(image);
    final plan = await scanVaultImport(DirectoryImportSource(source.path));
    expect(plan.notes.length, 4);
    expect(plan.unsupported, ['manual.pdf']);
    final id = repo.vaults.single.id;
    final result = await repo.importVault(
      id,
      plan,
      destination: 'Imported/Vault',
    );
    final notes = result.notes;
    final first = notes.singleWhere((n) => n.title == 'Start');
    final child = notes.singleWhere((n) => n.folder.endsWith('/A'));
    final second = notes.singleWhere((n) => n.folder.endsWith('/B'));
    expect(first.body, contains('# Different heading'));
    expect(first.body, contains('(silique-note:${child.id})'));
    expect(child.body, contains('[Second](silique-note:${second.id})'));
    expect(child.body, contains('[Embedded note](silique-note:${second.id})'));
    expect(repo.allFolders(id), contains('Imported/Vault/Empty/Nested'));
    expect(notes.singleWhere((n) => n.title == 'Text').body, 'plain');
    final reference = imageReferencePattern.firstMatch(first.body)!.group(1)!;
    expect(await repo.imageBytes(id, reference), image);
    expect(storage.pending(id).length, 4);
    expect(
      File('${source.path}/Start.md').readAsStringSync(),
      contains('A/Same.md'),
    );
    await repo.close();
    repo = Notebook(
      storage: NativeStorage('${root.path}/store'),
      keys: keys,
      crypto: TestCrypto(),
    );
    await repo.initialize();
    expect(repo.notes[id]!.length, 4);
    expect(repo.allFolders(id), contains('Imported/Vault/Empty/Nested'));
    expect(await repo.imageBytes(id, reference), image);
  });

  test(
    'root and existing destination preserve old notes with duplicate titles',
    () async {
      final id = repo.vaults.single.id;
      final old = await repo.createNote(id);
      await repo.save(old.copyWith(title: 'Same', body: 'old'));
      write('Same.md', 'new');
      final plan = await scanVaultImport(DirectoryImportSource(source.path));
      final imported = await repo.importVault(id, plan);
      expect(imported.notes.single.folder, '');
      expect(repo.notes[id]![old.id]!.body, 'old');
      await repo.createFolder(repo.vaults.single, 'Existing');
      final next = await repo.importVault(id, plan, destination: 'Existing');
      expect(next.notes.single.folder, 'Existing');
      expect(repo.notes[id]!.values.where((n) => n.title == 'Same').length, 3);
    },
  );

  test(
    'unsupported Obsidian embeds stay in the text without blocking import',
    () async {
      const embeds = '''![[table.csv]]
![[View.base]]
![[page.mht]]
![document](<assets/Manual copy.PDF>)
''';
      write('Start.md', '$embeds\n![[photo.bmp]]\n![[Child.md]]');
      write('Child.md', 'child note');
      for (final path in [
        'table.csv',
        'View.base',
        'page.mht',
        'assets/Manual copy.PDF',
      ]) {
        write(path, 'unsupported attachment content');
      }
      final image = sampleBmp(width: 4, height: 4);
      File('${source.path}/photo.bmp').writeAsBytesSync(image);
      final plan = await scanVaultImport(DirectoryImportSource(source.path));
      expect(plan.unsupported, hasLength(4));
      final id = repo.vaults.single.id;
      final result = await repo.importVault(id, plan);
      final start = result.notes.singleWhere((n) => n.title == 'Start');
      final child = result.notes.singleWhere((n) => n.title == 'Child');
      expect(start.body, startsWith(embeds));
      expect(start.body, contains('(silique-note:${child.id})'));
      expect(result.imageCount, 1);
      final reference = imageReferencePattern.firstMatch(start.body)!.group(1)!;
      expect(await repo.imageBytes(id, reference), image);
      expect(
        storage.documents(id).values.join(),
        isNot(contains('unsupported attachment content')),
      );
      expect(
        File('${source.path}/table.csv').readAsStringSync(),
        'unsupported attachment content',
      );
      await repo.close();
      repo = Notebook(
        storage: NativeStorage('${root.path}/store'),
        keys: keys,
        crypto: TestCrypto(),
      );
      await repo.initialize();
      expect(repo.notes[id]![start.id]!.body, start.body);
      expect(await repo.imageBytes(id, reference), image);
    },
  );

  test('disk failure rolls back folders, notes, images and outbox without changing memory', () async {
    write('A/one.md', '![image](../photo.bmp)');
    write('A/two.md', 'two');
    File('${source.path}/photo.bmp')
        .writeAsBytesSync(sampleBmp(width: 4, height: 4));
    final id = repo.vaults.single.id;
    final metadata = repo.vaults.single.metadata;
    final plan = await scanVaultImport(DirectoryImportSource(source.path));
    storage.failAt = 2;
    await expectLater(
      repo.importVault(id, plan, destination: 'New'),
      throwsStateError,
    );
    expect(storage.documents(id), isEmpty);
    expect(storage.pending(id), isEmpty);
    expect(storage.pendingImages(id), isEmpty);
    expect(repo.allFolders(id), isEmpty);
    expect(repo.notes[id], isEmpty);
    expect(repo.vaults.single.metadata, metadata);
  });

  test('protected imports do not leak titles, folder names, content or images to SQLite/mirrors', () async {
    await repo.createVault('Private', password: 'import-test-passphrase');
    final id = repo.vaults.last.id;
    write('Sensitive/Original title.md', 'secret body ![](../photo.bmp)');
    File('${source.path}/photo.bmp')
        .writeAsBytesSync(sampleBmp(width: 4, height: 4));
    final plan = await scanVaultImport(DirectoryImportSource(source.path));
    final result = await repo.importVault(id, plan);
    // Verify encrypted documents, then exercise password reopening.
    expect(storage.documents(id).values.single, isNot(contains('secret body')));
    expect(Directory('${storage.root}/markdown/$id').existsSync(), false);
    repo.lock(id);
    await expectLater(repo.importVault(id, plan), throwsStateError);
    await repo.unlock(repo.vaults.last, password: 'import-test-passphrase');
    expect(repo.notes[id]![result.notes.single.id]!.title, 'Original title');
    expect(repo.allFolders(id), contains('Sensitive'));
  });

  test('bad input and missing images leave the target untouched', () async {
    write('Good.md', 'good');
    write('Bad.md', '![](../outside.bmp)');
    final plan = await scanVaultImport(DirectoryImportSource(source.path));
    final id = repo.vaults.single.id;
    await expectLater(repo.importVault(id, plan), throwsFormatException);
    expect(storage.documents(id), isEmpty);
    expect(repo.allFolders(id), isEmpty);
    File('${source.path}/invalid.txt').writeAsBytesSync([255, 1, 2]);
    await expectLater(
      scanVaultImport(DirectoryImportSource(source.path)),
      throwsFormatException,
    );
    File('${source.path}/invalid.txt').deleteSync();
    Link('${source.path}/escape.md').createSync('${root.path}/outside.md');
    await expectLater(
      scanVaultImport(DirectoryImportSource(source.path)),
      throwsFormatException,
    );
  });

  test('link parser keeps code samples and remote URLs and resolves relative names safely', () async {
    final original =
        '😀 `![[same.md]]`\n```md\n[[same]]\n```\n[[same|label]]\n[remote](https://example.com)';
    final result = await rewriteImportedBody(
      original,
      (target, label, image) async =>
          target.startsWith('https:') ? null : '[$label](converted:$target)',
    );
    expect(result, contains('`![[same.md]]`'));
    expect(result, contains('```md\n[[same]]\n```'));
    expect(result, contains('[label](converted:same)'));
    expect(result, contains('[remote](https://example.com)'));
    expect(
      resolveImportLink('A/note.md', '../../outside.md', {'outside.md'}),
      isNull,
    );
    expect(
      resolveImportLink('A/note.md', '../B/Other%20note.md', {
        'B/Other note.md',
      }),
      'B/Other note.md',
    );
    expect(
      resolveImportLink('A/note.md', 'Same', {'B/Same.md', 'C/Same.md'}),
      isNull,
    );
  });

  test('UTF-16 source is decoded and original file is unchanged', () async {
    final text = 'Żółć 😀';
    final bytes = [
      255,
      254,
      for (final unit in text.codeUnits) ...[unit & 255, unit >> 8],
    ];
    final file = File('${source.path}/Windows.txt')..writeAsBytesSync(bytes);
    final plan = await scanVaultImport(DirectoryImportSource(source.path));
    expect(plan.notes.single.body, text);
    expect(file.readAsBytesSync(), bytes);
    expect(utf8.encode(plan.notes.single.body), utf8.encode(text));
  });

  test(
    'resolves Unicode and literal percent filenames and encoded links safely',
    () {
      final files = {
        '100%.md',
        '100% ready.md',
        'Literal%20name.md',
        'Encoded note.md',
        'Invalid%FF.md',
        'assets/100%.bmp',
        'Żółć 😀.md',
        'Procent%20literal.md',
      };
      for (final path in files) {
        expect(resolveImportLink('Start.md', path, files), path);
        expect(
          resolveImportLink('Start.md', Uri.encodeComponent(path), files),
          path,
        );
      }
      expect(resolveImportLink('Start.md', '100%#heading', files), '100%.md');
      expect(
        resolveImportLink('Start.md', 'Żółć%20😀.md', {'Żółć 😀.md'}),
        'Żółć 😀.md',
      );
      expect(resolveImportLink('Start.md', 'Missing%.md', files), isNull);
      expect(resolveImportLink('Start.md', 'Missing%FF.md', files), isNull);
      expect(
        resolveImportLink('Start.md', '%2e%2e/outside.md', {'outside.md'}),
        isNull,
      );
    },
  );

  test(
    'imports and reopens Obsidian links with Unicode and percent signs',
    () async {
      const original = '''[[100%|Progress]]
[encoded](Encoded%20note.md)
[[Invalid%FF]]
[[Żółć 😀]]
![[assets/100%.bmp]]
![encoded image](assets/100%25.bmp)
![[assets/zdjęcie 😀.bmp]]
[remote](https://example.com/100%)
''';
      write('Start.md', original);
      write('100%.md', 'literal percent');
      write('Encoded note.md', 'encoded space');
      write('Invalid%FF.md', 'literal invalid UTF-8 escape');
      write('Żółć 😀.md', 'Unicode filename');
      final image = sampleBmp(width: 4, height: 4);
      File('${source.path}/assets/100%.bmp')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(image);
      File('${source.path}/assets/zdjęcie 😀.bmp').writeAsBytesSync(image);
      final id = repo.vaults.single.id;
      final plan = await scanVaultImport(DirectoryImportSource(source.path));
      final result = await repo.importVault(id, plan, destination: 'Obsidian');
      final start = result.notes.singleWhere((n) => n.title == 'Start');
      for (final title in ['100%', 'Encoded note', 'Invalid%FF', 'Żółć 😀']) {
        final note = result.notes.singleWhere((n) => n.title == title);
        expect(start.body, contains('(silique-note:${note.id})'));
      }
      expect(start.body, contains('[remote](https://example.com/100%)'));
      final references = imageReferencePattern.allMatches(start.body).toList();
      expect(references, hasLength(3));
      expect(references[0].group(1), references[1].group(1));
      expect(result.imageCount, 2);
      expect(File('${source.path}/Start.md').readAsStringSync(), original);
      await repo.close();
      repo = Notebook(
        storage: NativeStorage('${root.path}/store'),
        keys: keys,
        crypto: TestCrypto(),
      );
      await repo.initialize();
      expect(repo.notes[id]![start.id]!.body, start.body);
      expect(await repo.imageBytes(id, references.first.group(1)!), image);
    },
  );
}
