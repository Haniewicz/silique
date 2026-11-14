import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/l10n/strings.dart';
import 'package:silique/storage/vault_export.dart';

void main() {
  setUpAll(() {
    currentLanguageCode = 'en';
  });

  group('sanitizeExportSegment', () {
    test('keeps letters, digits, spaces, underscores and hyphens', () {
      expect(sanitizeExportSegment('Ala ma kota 2'), 'Ala ma kota 2');
      expect(sanitizeExportSegment('raport_2026-11'), 'raport_2026-11');
    });

    test('replaces special characters including slash and dots with _', () {
      expect(sanitizeExportSegment('a/b'), 'a_b');
      expect(sanitizeExportSegment('a..b'), 'a__b');
      expect(sanitizeExportSegment('a.txt'), 'a_txt');
      expect(sanitizeExportSegment('żółć😀?'), 'żółć__');
    });

    test('trims and strips trailing dots/spaces and leading dots', () {
      expect(sanitizeExportSegment('  Ala  '), 'Ala');
      expect(sanitizeExportSegment('Ala...'), 'Ala');
      expect(sanitizeExportSegment('.hidden'), 'hidden');
      expect(sanitizeExportSegment('...'), tr('Bez tytułu', 'Untitled'));
    });

    test('falls back to Untitled for an empty name', () {
      expect(sanitizeExportSegment(''), tr('Bez tytułu', 'Untitled'));
      expect(sanitizeExportSegment('   '), tr('Bez tytułu', 'Untitled'));
      expect(sanitizeExportSegment('...'), tr('Bez tytułu', 'Untitled'));
    });
  });

  group('ExportPathAllocator', () {
    test('dedup ["Ala","Ala","Ala (1)"]', () {
      final a = ExportPathAllocator();
      expect(a.reserve('Ala'), 'Ala');
      expect(a.reserve('Ala'), 'Ala (1)');
      expect(a.reserve('Ala (1)'), 'Ala (1) (1)');
    });

    test('dedup is case-insensitive: ["Note","NOTE"]', () {
      final a = ExportPathAllocator();
      expect(a.reserve('Note'), 'Note');
      expect(a.reserve('NOTE'), 'NOTE (1)');
    });
  });

  group('buildVaultExportPlan', () {
    ExportNote note(String id, String title, {String folder = '', String body = ''}) =>
        ExportNote(id: id, title: title, body: body, folder: folder);

    test('sorts notes deterministically by lowercase title then id', () {
      final plan = buildVaultExportPlan([
        note('b', 'beta'),
        note('a-1', 'Ala'),
        note('a-2', 'ala'),
      ]);
      expect(plan.notes.map((n) => n.title).toList(), ['Ala', 'ala', 'beta']);
      expect(plan.notes.map((n) => n.noteId).toList(), ['a-1', 'a-2', 'b']);
    });

    test('dedups duplicate titles in the same directory', () {
      final plan = buildVaultExportPlan([
        note('1', 'Ala'),
        note('2', 'Ala'),
        note('3', 'Ala (1)'),
      ]);
      // Suffix goes before the extension; the title "Ala (1)" sanitizes to
      // base "Ala _1_" (parentheses are not in the allowed set), so it does not
      // collide with the dedup suffixes of "Ala".
      expect(
        plan.notes.map((n) => n.fileName).toList(),
        ['Ala.md', 'Ala (1).md', 'Ala _1_.md'],
      );
    });

    test('mirrors folders, deduplicating case-only differences', () {
      final plan = buildVaultExportPlan(
        [
          note('1', 'One', folder: 'Projekty/Ala'),
          note('2', 'Two', folder: 'projekty/Ala'),
        ],
      );
      // Same folder name differing only in case -> two sibling dirs.
      final dirs = plan.notes.map((n) => n.relativeDir).toList();
      expect(dirs[0].split('/').first, 'Projekty');
      expect(dirs[1].split('/').first, 'projekty (1)');
      // Both notes still under an "Ala" subfolder.
      expect(dirs[0], 'Projekty/Ala');
      expect(dirs[1], 'projekty (1)/Ala');
    });

    test('skips trash (deleted notes are not passed in)', () {
      // The plan builder has no `deleted` field: trash is dropped by the
      // service. Here we assert a note with no folder lands in root.
      final plan = buildVaultExportPlan([note('1', 'Root note')]);
      expect(plan.notes.single.relativeDir, '');
    });

    test('hidden notes are excluded by default and placed in _hidden when included', () {
      final visible = buildVaultExportPlan([note('1', 'A', body: '')]);
      expect(visible.hiddenCount, 0);

      final withHidden = buildVaultExportPlan([
        ExportNote(id: '1', title: 'A', body: '', folder: ''),
        ExportNote(id: '2', title: 'Hidden', body: '', folder: 'Secret', hidden: true),
      ]);
      expect(withHidden.hiddenCount, 1);
      final hidden = withHidden.notes.singleWhere((n) => n.hidden);
      expect(hidden.relativeDir, '_hidden');
    });

    test('a folder named _hidden gets _hidden (1) when hidden notes are included', () {
      final plan = buildVaultExportPlan([
        ExportNote(id: '1', title: 'A', body: '', folder: '_hidden'),
        ExportNote(id: '2', title: 'H', body: '', folder: '', hidden: true),
      ]);
      final ordinary = plan.notes.singleWhere((n) => !n.hidden);
      final hidden = plan.notes.singleWhere((n) => n.hidden);
      expect(ordinary.relativeDir, '_hidden (1)');
      expect(hidden.relativeDir, '_hidden');
    });

    test('a folder named _images gets _images (1)', () {
      final plan = buildVaultExportPlan([
        ExportNote(id: '1', title: 'A', body: '', folder: '_images'),
      ]);
      expect(plan.notes.single.relativeDir, '_images (1)');
    });

    test('rewrites image references to relative paths, deeper notes get ../', () {
      const id = 'aaaaaaaa-0000-0000-0000-000000000001';
      final image = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3]);
      final plan = buildVaultExportPlan(
        [
          ExportNote(id: '1', title: 'Root', body: '![](silique-image:$id)', folder: ''),
          ExportNote(
            id: '2',
            title: 'Deep',
            body: '![x](silique-image:$id)',
            folder: 'A/B',
          ),
        ],
        images: {id: image},
      );
      final root = plan.notes.singleWhere((n) => n.title == 'Root');
      final deep = plan.notes.singleWhere((n) => n.title == 'Deep');
      expect(root.body, contains('_images/'));
      expect(root.body, isNot(contains('silique-image:')));
      expect(deep.body, contains('../../_images/'));
      expect(deep.body, isNot(contains('silique-image:')));
      expect(plan.images.single.fileName, endsWith('.png'));
    });

    test('a missing image keeps the original reference and counts as skipped', () {
      const id = 'bbbbbbbb-0000-0000-0000-000000000002';
      final plan = buildVaultExportPlan([
        ExportNote(id: '1', title: 'A', body: '![](silique-image:$id)'),
      ]);
      expect(plan.images, isEmpty);
      expect(plan.skippedImageCount, 1);
      expect(plan.notes.single.body, contains('silique-image:$id'));
    });

    test('dedups folders at the second level: A/B vs A/b', () {
      final plan = buildVaultExportPlan([
        note('1', 'One', folder: 'A/B'),
        note('2', 'Two', folder: 'A/b'),
      ]);
      // Same second-level name differing only in case -> sibling dirs under a
      // shared, case-insensitively collapsed first-level "A".
      final dirs = plan.notes.map((n) => n.relativeDir).toList();
      expect(dirs, ['A/B', 'A/b (1)']);
    });

    test('dedups titles inside a common subfolder', () {
      final plan = buildVaultExportPlan([
        note('1', 'X', folder: 'F'),
        note('2', 'X', folder: 'F'),
      ]);
      expect(
        plan.notes.map((n) => n.relativePath).toList(),
        ['F/X.md', 'F/X (1).md'],
      );
    });

    test('empty folders are mirrored into the plan directories', () {
      final plan = buildVaultExportPlan(
        [note('1', 'One', folder: 'A/B')],
        folders: ['Pusty', 'A/C', 'Pusty/Nested'],
      );
      expect(plan.folders, containsAll(['Pusty', 'Pusty/Nested']));
      expect(plan.folders, contains('A'));
      expect(plan.folders, contains('A/B'));
      expect(plan.folders, contains('A/C'));
      // Empty folders only produce directories, never note entries.
      expect(plan.notes.single.relativeDir, 'A/B');
    });

    test('empty folders share the same directory as identical note folders', () {
      final plan = buildVaultExportPlan(
        [note('1', 'One', folder: 'Pusty')],
        folders: ['Pusty'],
      );
      // An empty folder and a note folder with the SAME name reuse one directory.
      expect(plan.notes.single.relativeDir, 'Pusty');
      expect(
        plan.folders.where((d) => d.toLowerCase() == 'pusty'),
        hasLength(1),
      );
    });

    test('empty folders dedup case-insensitively against note folders', () {
      final plan = buildVaultExportPlan(
        [note('1', 'One', folder: 'Pusty')],
        folders: ['pusty'],
      );
      // Differing only in case: the empty folder claims "pusty", the note folder
      // gets the dedup suffix "Pusty (1)" — never two bare case-variant dirs.
      expect(plan.notes.single.relativeDir, 'Pusty (1)');
      expect(plan.folders, ['pusty', 'Pusty (1)']);
    });
  });

  group('folder mirror helper', () {
    test('does not escape the export root via .. segments', () {
      expect(
        () => buildVaultExportPlan([
          ExportNote(id: '1', title: 'A', body: '', folder: '../escape'),
        ]),
        returnsNormally,
      );
      // The segment "../escape" is sanitized: `.` is dropped to `_`, so it
      // cannot traverse out. Verify the resulting directory has no `..`.
      final plan = buildVaultExportPlan([
        ExportNote(id: '1', title: 'A', body: '', folder: '../escape'),
      ]);
      expect(plan.notes.single.relativeDir, isNot(contains('..')));
    });
  });

  group('writer and zip', () {
    test('writes files to a temp directory with images and rewritten refs', () async {
      final root = Directory.systemTemp.createTempSync('vault-export-write-');
      final image = Uint8List.fromList([255, 216, 255, 1, 2, 3]);
      const id = 'cccccccc-0000-0000-0000-000000000003';
      final plan = buildVaultExportPlan(
        [
          ExportNote(id: '1', title: 'Ala', body: '![p](silique-image:$id)'),
          ExportNote(id: '2', title: 'Ala', body: 'dupe'),
        ],
        images: {id: image},
      );
      final writer = ExportVaultWriter(root);
      final stats = await writer.write(plan);
      expect(stats.notes, 2);
      expect(stats.images, 1);
      expect(File('${root.path}/Ala.md').existsSync(), true);
      expect(File('${root.path}/Ala (1).md').existsSync(), true);
      expect(File('${root.path}/_images/${plan.images.single.fileName}').existsSync(), true);
      final first = File('${root.path}/Ala.md').readAsStringSync();
      expect(first, contains('# Ala'));
      // A root note links the image with a relative path (no leading slash).
      expect(first, contains('_images/'));
      root.deleteSync(recursive: true);
    });

    test('zip contains the expected entries without a wrapper directory', () {
      const id = 'dddddddd-0000-0000-0000-000000000004';
      final image = Uint8List.fromList([71, 73, 70, 56, 9, 9, 9]);
      final plan = buildVaultExportPlan(
        [
          ExportNote(id: '1', title: 'Note', body: '![g](silique-image:$id)'),
          ExportNote(id: '2', title: 'Sub', body: 'x', folder: 'Folder'),
        ],
        images: {id: image},
      );
      final zip = buildVaultExportZip(plan);
      final archive = ZipDecoder().decodeBytes(zip);
      final names = archive.map((f) => f.name).toSet();
      expect(names, contains('Note.md'));
      expect(names, contains('Folder/Sub.md'));
      expect(
        names.any((n) => n.startsWith('_images/') && n.endsWith('.gif')),
        true,
      );
      // No wrapper directory: every entry is a top-level name or a folder path.
      expect(names.every((n) => !n.startsWith('vault/')), true);
    });

    test('safeVaultZipName sanitizes the vault name', () {
      expect(safeVaultZipName('My/Vault.txt'), 'My_Vault_txt.zip');
      expect(safeVaultZipName(''), 'Untitled.zip');
    });

    test('writes a note into a nested subfolder, creating parent dirs and '
        'linking images with the right number of ../', () async {
      final root = Directory.systemTemp.createTempSync('vault-export-sub-');
      final image = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 9, 9]);
      const id = 'eeeeeeee-0000-0000-0000-000000000005';
      final plan = buildVaultExportPlan(
        [
          ExportNote(
            id: '1',
            title: 'Deep',
            body: '![i](silique-image:$id)',
            folder: 'A/B',
          ),
        ],
        images: {id: image},
      );
      final writer = ExportVaultWriter(root);
      final stats = await writer.write(plan);
      expect(stats.notes, 1);
      expect(stats.folders, 3); // A, A/B and _images
      final file = File('${root.path}/A/B/Deep.md');
      expect(file.existsSync(), true);
      final content = file.readAsStringSync();
      expect(content, contains('# Deep'));
      // Depth 2 -> two levels up to reach _images.
      expect(content, contains('../../_images/'));
      expect(
        File('${root.path}/_images/${plan.images.single.fileName}').existsSync(),
        true,
      );
      root.deleteSync(recursive: true);
    });

    test('writer creates empty folders and the zip includes the folder entry', () async {
      final root = Directory.systemTemp.createTempSync('vault-export-empty-');
      final plan = buildVaultExportPlan(
        [ExportNote(id: '1', title: 'Note', body: '')],
        folders: ['Pusty'],
      );
      final writer = ExportVaultWriter(root);
      final stats = await writer.write(plan);
      // The empty folder is created on disk even though no note lands in it.
      expect(Directory('${root.path}/Pusty').existsSync(), true);
      expect(stats.folders, 1);
      // The ZIP contains a trailing-slash directory entry for the empty folder.
      final zip = buildVaultExportZip(plan);
      final archive = ZipDecoder().decodeBytes(zip);
      expect(archive.map((f) => f.name), contains('Pusty/'));
      root.deleteSync(recursive: true);
    });

    test('writer rejects relativeDir with .. and absolute paths', () async {
      final root = Directory.systemTemp.createTempSync('vault-export-safe-');
      final writer = ExportVaultWriter(root);
      final escapeDir = ExportNoteFile(
        noteId: '1',
        title: 'Esc',
        body: '',
        folderPath: '',
        relativeDir: '..',
        fileName: 'Esc.md',
        hidden: false,
      );
      final absoluteNote = ExportNoteFile(
        noteId: '2',
        title: 'Abs',
        body: '',
        folderPath: '',
        relativeDir: '/etc',
        fileName: 'Abs.md',
        hidden: false,
      );
      // A directly-constructed note with a `..` or absolute relativeDir throws
      // and never writes a file outside the root.
      await expectLater(
        writer.write(
          VaultExportPlan(
            notes: [escapeDir],
            images: const [],
            folders: const [],
            hiddenCount: 0,
            skippedImageCount: 0,
          ),
        ),
        throwsFormatException,
      );
      await expectLater(
        writer.write(
          VaultExportPlan(
            notes: [absoluteNote],
            images: const [],
            folders: const [],
            hiddenCount: 0,
            skippedImageCount: 0,
          ),
        ),
        throwsFormatException,
      );
      expect(File('${root.path}/Esc.md').existsSync(), false);
      root.deleteSync(recursive: true);
    });
  });
}