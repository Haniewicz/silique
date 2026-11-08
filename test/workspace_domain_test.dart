import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show TextSelection;
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';
import 'package:silique/core/models.dart';
import 'package:silique/core/search.dart';
import 'package:silique/core/span_size.dart';
import 'package:silique/core/workspace.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

Future<Notebook> _notebook(
  Directory dir, {
  MemoryKeys? keys,
  NativeStorage? storage,
}) async {
  final repo = Notebook(
    storage: storage ?? NativeStorage(dir.path),
    keys: keys ?? MemoryKeys(),
    crypto: TestCrypto(),
  );
  await repo.initialize();
  return repo;
}

void main() {
  group('folder paths', () {
    test('accepts relative paths with Polish names and trims segments', () {
      expect(normalizeFolderPath(' Projekty / Mercaro '), 'Projekty/Mercaro');
      expect(normalizeFolderPath('Zażółć gęślą jaźń'), 'Zażółć gęślą jaźń');
      expect(normalizeFolderPath('A/B/C'), 'A/B/C');
    });

    test('rejects traversal, absolute, empty and invalid names', () {
      expect(normalizeFolderPath('../etc'), isNull);
      expect(normalizeFolderPath('A/../B'), isNull);
      expect(normalizeFolderPath('A/./B'), isNull);
      expect(normalizeFolderPath('/A'), isNull);
      expect(normalizeFolderPath('A//B'), isNull);
      expect(normalizeFolderPath('   '), isNull);
      expect(normalizeFolderPath('A\\B'), isNull);
      expect(normalizeFolderPath('A/\u0007B'), isNull);
      expect(normalizeFolderPath('A/${'x' * 65}'), isNull);
      expect(
        normalizeFolderPath(List.generate(14, (i) => 'f$i').join('/')),
        isNull,
      );
      expect(normalizeFolderPath('A '), 'A');
      expect(folderPathError('..'), contains('„..”'));
    });

    test('detects prefix relationships without false positives', () {
      expect(isDescendantPath('A/B', 'A'), true);
      expect(isDescendantPath('AB', 'A'), false);
      expect(isSameOrDescendantPath('A', 'A'), true);
      expect(replacePathPrefix('A/B/C', 'A/B', 'X'), 'X/C');
      expect(folderAncestors('A/B/C'), ['A', 'A/B']);
    });

    test(
      'case-insensitive collisions are rejected, ignoring the renamed tree',
      () {
        expect(folderPathCollides('Projekty', ['projekty']), true);
        expect(folderPathCollides('Projekty/B', ['Projekty/A']), false);
        expect(
          folderPathCollides('Projekty/B', ['Projekty/B'], ignore: 'Projekty'),
          false,
        );
      },
    );

    test(
      'tree implies missing parents, orders rows and hides collapsed subtrees',
      () {
        final rows = buildFolderTree(['B/z', 'A', 'A/B', 'B/a/c']);
        expect(rows.map((r) => r.path), [
          'A',
          'A/B',
          'B',
          'B/a',
          'B/a/c',
          'B/z',
        ]);
        expect(rows.firstWhere((r) => r.path == 'B/a/c').depth, 2);
        final collapsed = buildFolderTree(['A/B', 'A/C'], collapsed: {'A'});
        expect(collapsed.map((r) => r.path), ['A']);
        expect(collapsed.single.hasChildren, true);
      },
    );
  });

  group('search ranges', () {
    test('maps Polish text without shifting offsets', () {
      const text = 'Zażółć gęślą jaźń. Zażółć jeszcze raz.';
      final matches = findMatchRanges(text, 'zażółć');
      expect(matches, hasLength(2));
      for (final match in matches) {
        expect(text.substring(match.start, match.end), 'Zażółć');
      }
    });

    test('handles empty query, missing query and adjacent matches', () {
      expect(findMatchRanges('abc', ''), isEmpty);
      expect(findMatchRanges('', 'a'), isEmpty);
      expect(findMatchRanges('abc', 'x'), isEmpty);
      expect(findMatchRanges('aaaa', 'aa'), hasLength(2));
      expect(findMatchRanges('Łódź', 'ŁÓDŹ'), hasLength(1));
    });

    test('finds the active match around the caret', () {
      final matches = findMatchRanges('a-a-a', 'a');
      expect(activeMatchForOffset(matches, 0), 0);
      expect(activeMatchForOffset(matches, 6), -1);
    });
  });

  group('inline font size', () {
    test('wraps only the selection and keeps the rest untouched', () {
      const text = 'Ala ma kota, a kot ma Alę.';
      final result = applySpanFontSize(
        text,
        const TextSelection(baseOffset: 7, extentOffset: 11),
        24,
      )!;
      expect(
        result.text,
        'Ala ma <span style="font-size:24px">kota</span>, a kot ma Alę.',
      );
      expect(result.selection.textInside(result.text), 'kota');
      // Applying again rewrites the size instead of nesting a second span.
      final again = applySpanFontSize(result.text, result.selection, 32)!;
      expect(again.text, contains('font-size:32px'));
      expect('<span style'.allMatches(again.text), hasLength(1));
      expect(spanFontSizeAt(again.text, again.selection), 32);
    });

    test('wraps every line of a multi-line selection', () {
      const text = 'pierwsza\n\ndruga linia';
      final result = applySpanFontSize(
        text,
        const TextSelection(baseOffset: 0, extentOffset: text.length),
        18,
      )!;
      expect('<span'.allMatches(result.text), hasLength(2));
      expect(result.text, contains('font-size:18px">pierwsza</span>'));
      expect(result.text, contains('font-size:18px">druga linia</span>'));
      expect(result.text, contains('\n\n'));
    });

    test('never formats without a selection and clamps the range to 8–72', () {
      expect(
        applySpanFontSize('abc', const TextSelection.collapsed(offset: 1), 12),
        isNull,
      );
      final small = applySpanFontSize(
        'abc',
        const TextSelection(baseOffset: 0, extentOffset: 3),
        1,
      )!;
      expect(small.text, contains('font-size:8px'));
      final huge = applySpanFontSize(
        'abc',
        const TextSelection(baseOffset: 0, extentOffset: 3),
        400,
      )!;
      expect(huge.text, contains('font-size:72px'));
    });

    test('vendor parser and controller render the stored size and undo it', () {
      const source = 'Przed <span style="font-size:20px">środek</span> po';
      final tree = const MarkdownSyntaxParser().parse(source);
      final node = tree.lines.single.inlines
          .where((n) => n.kind == MarkdownInlineKind.fontSize)
          .single;
      expect(node.fontSize, 20);
      expect(
        source.substring(node.contentRange.start, node.contentRange.end),
        'środek',
      );

      final controller = LiveMarkdownController(
        text: 'Zaznaczony tekst',
        selection: const TextSelection(baseOffset: 0, extentOffset: 10),
      );
      final applied = applySpanFontSize(
        controller.text,
        controller.selection,
        28,
      )!;
      controller.setValue(
        TextEditingValue(text: applied.text, selection: applied.selection),
      );
      expect(controller.text, contains('font-size:28px'));
      controller.undo();
      expect(controller.text, 'Zaznaczony tekst');
      controller.redo();
      expect(controller.text, contains('font-size:28px'));
    });
  });

  group('notebook folders', () {
    test(
      'empty folders persist across restart without creating notes',
      () async {
        final dir = Directory.systemTemp.createTempSync('silique-folders-');
        final keys = MemoryKeys();
        var repo = await _notebook(dir, keys: keys);
        await repo.createVault('Local');
        final vault = repo.vaults.single;
        await repo.createFolder(vault, 'Projekty/Mercaro');
        expect(repo.notes[vault.id], isEmpty);
        await repo.close();

        repo = await _notebook(dir, keys: keys);
        expect(repo.allFolders(vault.id), {'Projekty/Mercaro', 'Projekty'});
        expect(
          repo.notes[vault.id]!.values.any((n) => n.folder.isNotEmpty),
          false,
        );
        expect(repo.foldersOf(vault.id), ['Projekty/Mercaro']);
        await repo.close();
        dir.deleteSync(recursive: true);
      },
    );

    test('rejects duplicates, case collisions and traversal', () async {
      final dir = Directory.systemTemp.createTempSync('silique-folders-');
      final repo = await _notebook(dir);
      await repo.createVault('Local');
      final vault = repo.vaults.single;
      await repo.createFolder(vault, 'Projekty');
      await expectLater(
        repo.createFolder(vault, 'Projekty'),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        repo.createFolder(vault, 'projekty'),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        repo.createFolder(vault, '../poza'),
        throwsA(isA<FormatException>()),
      );
      expect(repo.allFolders(vault.id), {'Projekty'});
      await repo.close();
      dir.deleteSync(recursive: true);
    });

    test('bulk note operations move, pin, trash and survive restart', () async {
      final dir = Directory.systemTemp.createTempSync('silique-bulk-');
      final keys = MemoryKeys();
      var repo = await _notebook(dir, keys: keys);
      await repo.createVault('Local');
      final vault = repo.vaults.single;
      final notes = <Note>[];
      for (var i = 0; i < 3; i++) {
        final note = await repo.createNote(vault.id);
        notes.add(note.copyWith(title: 'N$i', body: 'body $i'));
        await repo.save(notes.last);
      }
      expect(await repo.moveNotes(notes.take(2), 'Archiwum/2026'), 2);
      expect(repo.allFolders(vault.id), contains('Archiwum/2026'));
      expect(await repo.setFavoriteAll(notes.take(2), true), 2);
      expect(await repo.setFavoriteAll(notes.take(2), true), 0);
      expect(await repo.setDeletedAll(notes.take(1), true), 1);
      await repo.close();

      repo = await _notebook(dir, keys: keys);
      final reloaded = repo.notes[vault.id]!;
      expect(reloaded[notes[0].id]!.folder, 'Archiwum/2026');
      expect(reloaded[notes[0].id]!.deleted, true);
      expect(reloaded[notes[0].id]!.favorite, true);
      expect(reloaded[notes[1].id]!.folder, 'Archiwum/2026');
      expect(reloaded[notes[2].id]!.folder, '');
      expect(repo.foldersOf(vault.id), contains('Archiwum/2026'));
      await repo.close();
      dir.deleteSync(recursive: true);
    });

    test('folder rename moves the whole subtree and refuses cycles', () async {
      final dir = Directory.systemTemp.createTempSync('silique-folders-');
      final repo = await _notebook(dir);
      await repo.createVault('Local');
      final vault = repo.vaults.single;
      Future<Note> noteIn(String folder) async {
        final note = await repo.createNote(vault.id, folder: folder);
        final updated = note.copyWith(body: folder);
        await repo.save(updated);
        return updated;
      }

      await noteIn('Projekty');
      await noteIn('Projekty/Mercaro');
      await noteIn('Projekty/Mercaro/2026');
      await noteIn('Inne');
      await repo.createFolder(vault, 'Projekty/Puste');

      expect(await repo.renameFolder(vault, 'Projekty', 'Praca'), 3);
      expect(
        repo.notes[vault.id]!.values
            .where((n) => isSameOrDescendantPath(n.folder, 'Praca'))
            .length,
        3,
      );
      expect(repo.allFolders(vault.id), containsAll(['Praca', 'Praca/Puste']));
      expect(
        repo.allFolders(vault.id).any((f) => f.startsWith('Projekty')),
        false,
      );

      await expectLater(
        repo.renameFolder(vault, 'Praca', 'Praca/Mercaro/2026/Praca'),
        throwsA(isA<StateError>()),
      );
      await repo.createFolder(vault, 'Inne/2026');
      await expectLater(
        repo.renameFolder(vault, 'Praca', 'Inne/2026'),
        throwsA(isA<StateError>()),
      );
      expect(await repo.trashFolder(vault, 'Praca'), 3);
      expect(repo.notes[vault.id]!.values.where((n) => n.deleted).length, 3);
      expect(
        repo.allFolders(vault.id).any((f) => f.startsWith('Praca')),
        false,
      );
      await repo.close();
      dir.deleteSync(recursive: true);
    });
  });

  group('user-chosen vault location', () {
    test('a chosen directory becomes a persistent Silique Vaults root', () {
      final root = Directory.systemTemp.createTempSync('silique-loc-');
      final support = Directory('${root.path}/support')..createSync();
      final chosen = Directory('${root.path}/Moje notatki')..createSync();
      final resolved = NativeStorage.prepareChosenRoot(chosen.path);
      expect(resolved, '${chosen.path}/${NativeStorage.vaultsFolderName}');
      expect(Directory(resolved).existsSync(), true);
      NativeStorage.persistChosenRoot(support.path, resolved);
      NativeStorage(resolved).close();
      // A restart reuses the recorded location and its database.
      expect(NativeStorage.existingRoot(support.path), resolved);
      expect(NativeStorage.resolveRoot(support.path), resolved);
      root.deleteSync(recursive: true);
    });

    test('nothing is created when the user cancels the picker', () {
      final root = Directory.systemTemp.createTempSync('silique-loc-');
      final support = Directory('${root.path}/support')..createSync();
      expect(NativeStorage.existingRoot(support.path), isNull);
      expect(
        () => NativeStorage.resolveRoot(support.path),
        throwsA(isA<StateError>()),
      );
      expect(
        Directory('${support.path}/Silique').existsSync(),
        false,
        reason: 'no fallback database is created silently',
      );
      expect(File('${support.path}/silique-location.txt').existsSync(), false);
      root.deleteSync(recursive: true);
    });

    test('an unwritable chosen directory is rejected without a store', () {
      final root = Directory.systemTemp.createTempSync('silique-loc-');
      final support = Directory('${root.path}/support')..createSync();
      final readOnly = Directory('${root.path}/readonly')..createSync();
      File('${readOnly.path}/keep.txt').writeAsStringSync('x');
      // Remove write permission from the directory itself (not from this user's
      // ability to chmod it back in the tear-down).
      final mode = readOnly.statSync().mode;
      Process.runSync('chmod', ['500', readOnly.path]);
      addTearDown(() => Process.runSync('chmod', ['$mode', readOnly.path]));
      expect(
        () => NativeStorage.prepareChosenRoot(readOnly.path),
        throwsA(anything),
      );
      expect(
        Directory('${readOnly.path}/${NativeStorage.vaultsFolderName}')
            .existsSync(),
        false,
      );
      expect(NativeStorage.existingRoot(support.path), isNull);
      Process.runSync('chmod', ['700', readOnly.path]);
      root.deleteSync(recursive: true);
    });

    test(
      'existing application data is reused without a location prompt',
      () async {
        final root = Directory.systemTemp.createTempSync('silique-loc-');
        final support = Directory('${root.path}/support')..createSync();
        final chosen = Directory('${root.path}/Nowe')..createSync();
        final existing = Directory('${support.path}/Silique')..createSync();
        final repo = Notebook(
          storage: NativeStorage(existing.path),
          keys: MemoryKeys(),
          crypto: TestCrypto(),
        );
        await repo.initialize();
        await repo.createVault('Stary');
        await repo.close();
        expect(NativeStorage.existingRoot(support.path), existing.path);
        expect(NativeStorage.resolveRoot(support.path), existing.path);
        expect(
          Directory('${chosen.path}/${NativeStorage.vaultsFolderName}')
              .existsSync(),
          false,
        );
        root.deleteSync(recursive: true);
      },
    );

    test('foreign files in Silique Vaults are never overwritten', () {
      final root = Directory.systemTemp.createTempSync('silique-loc-');
      final chosen = Directory('${root.path}/Dokumenty')..createSync();
      final target = Directory(
        '${chosen.path}/${NativeStorage.vaultsFolderName}',
      )..createSync();
      File('${target.path}/rachunki.pdf').writeAsStringSync('cudze dane');
      expect(
        () => NativeStorage.prepareChosenRoot(chosen.path),
        throwsA(isA<StateError>()),
      );
      expect(
        File('${target.path}/rachunki.pdf').readAsStringSync(),
        'cudze dane',
      );
      root.deleteSync(recursive: true);
    });

    test(
      'missing or foreign recorded locations are recoverable, not empty stores',
      () {
        final root = Directory.systemTemp.createTempSync('silique-loc-');
        final support = Directory('${root.path}/support')..createSync();
        // 1. The recorded directory disappeared (moved disk, revoked access).
        NativeStorage.persistChosenRoot(support.path, '${root.path}/zniknal');
        expect(
          () => NativeStorage.existingRoot(support.path),
          throwsA(isA<StorageLocationUnavailable>()),
        );
        // 2. It exists but holds foreign files instead of a Silique store.
        final foreign = Directory('${root.path}/obcy')..createSync();
        File('${foreign.path}/raport.pdf').writeAsStringSync('x');
        NativeStorage.persistChosenRoot(support.path, foreign.path);
        expect(
          () => NativeStorage.existingRoot(support.path),
          throwsA(isA<StorageLocationUnavailable>()),
        );
        expect(File('${foreign.path}/raport.pdf').readAsStringSync(), 'x');
        // 3. Recovery adopts the directory that still has the database, and the
        //    next start opens it again from the pointer.
        final moved = Directory(
          '${root.path}/przeniesione/${NativeStorage.vaultsFolderName}',
        )..createSync(recursive: true);
        File('${moved.path}/silique.sqlite').writeAsStringSync('db');
        expect(
          NativeStorage.adoptExistingRoot('${root.path}/przeniesione'),
          moved.path,
        );
        expect(NativeStorage.adoptExistingRoot(moved.path), moved.path);
        NativeStorage.persistChosenRoot(support.path, moved.path);
        expect(NativeStorage.existingRoot(support.path), moved.path);
        root.deleteSync(recursive: true);
      },
    );

    test(
      'a legacy application-support directory is migrated instead of prompting',
      () async {
        final root = Directory.systemTemp.createTempSync('silique-loc-');
        final support = Directory('${root.path}/support')..createSync();
        final legacy = Directory('${support.path}/Nova Notes')..createSync();
        final repo = Notebook(
          storage: NativeStorage(legacy.path),
          keys: MemoryKeys(),
          crypto: TestCrypto(),
        );
        await repo.initialize();
        await repo.createVault('Silique');
        await repo.close();
        File('${legacy.path}/silique.sqlite')
            .renameSync('${legacy.path}/nova.sqlite');
        expect(
          NativeStorage.existingRoot(support.path),
          '${support.path}/Silique',
        );
        expect(File('${support.path}/Silique/nova.sqlite').existsSync(), true);
        root.deleteSync(recursive: true);
      },
    );
  });

  group('vault metadata compatibility', () {
    test(
      'folders survive a vault rename and keep the encrypted name',
      () async {
        final dir = Directory.systemTemp.createTempSync('silique-meta-');
        final repo = await _notebook(dir);
        await repo.createVault('Osobiste');
        final vault = repo.vaults.single;
        await repo.createFolder(vault, 'A/B');
        await repo.renameVault(vault, 'Prywatne');
        final decoded = jsonDecode(
          await (repo.crypto).open(
            repo.unlocked[vault.id]!,
            vault.metadata,
            'silique:2:vault-meta:${vault.id}',
          ),
        ) as Map<String, dynamic>;
        expect(decoded['name'], 'Prywatne');
        expect(decoded['folders'], ['A/B']);
        await repo.close();
        dir.deleteSync(recursive: true);
      },
    );
  });
}
