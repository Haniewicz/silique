import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/models.dart';
import 'package:silique/main.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/storage/vault_import.dart';
import 'package:silique/ui/vault_import_dialog.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

class _Source implements VaultImportSource {
  @override
  String get label => 'Obsidian';
  @override
  Future<List<ImportEntry>> entries() async => const [
    ImportEntry('Root.md', directory: false),
    ImportEntry('Nested', directory: true),
    ImportEntry('Nested/Child.md', directory: false),
    ImportEntry('Data.csv', directory: false),
  ];
  @override
  Future<Uint8List> read(String path, {required int limit}) async {
    if (path == 'Data.csv') throw StateError('Do not read skipped attachments');
    return Uint8List.fromList(
      utf8.encode(
        path == 'Root.md' ? 'Text in $path\n![[Data.csv]]' : 'Text in $path',
      ),
    );
  }
}

class _Storage extends NativeStorage {
  _Storage(super.root);
  @override
  Future<void> mirror(Note note) async {}
}

void main() {
  late Directory root;
  late Notebook repo;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('silique-import-ui-');
    repo = Notebook(
      storage: _Storage(root.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('First');
    debugVaultImportPicker = () async => _Source();
  });
  tearDown(() async {
    debugVaultImportPicker = null;
    await repo.close();
    root.deleteSync(recursive: true);
  });

  Future<void> dialog(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<VaultImportResult>(
                context: context,
                barrierDismissible: false,
                builder: (_) => VaultImportDialog(
                  notebook: repo,
                  vaultId: repo.vaults.first.id,
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('choose-import-vault')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'starts in the remembered vault and removes duplicate sidebar settings and drawn caption',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() async {
        await repo.createVault('Last');
        final id = repo.vaults.last.id;
        final note = await repo.createNote(id);
        await repo.save(note.copyWith(title: 'Remembered note'));
        await repo.rememberVault(id);
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [notebookProvider.overrideWithValue(repo)],
          child: const SiliqueApp(),
        ),
      );
      await tester.pumpAndSettle();
      final title = tester.widget<TextField>(
        find.byKey(const Key('note-title')),
      );
      expect(title.controller!.text, 'Remembered note');
      expect(find.text('Ustawienia'), findsNothing);
      expect(find.byTooltip('Zamknij okno'), findsNothing);
      expect(find.byTooltip('Ustawienia synchronizacji'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'narrow import preview and cancellation leave no notes or folders',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await dialog(tester);
      expect(find.text('Notatki: 2 • Foldery: 1'), findsOneWidget);
      expect(find.text('Inne pliki nie będą importowane (1):'), findsOneWidget);
      expect(
        find.textContaining('Odnośniki do tych plików pozostaną'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Anuluj'));
      await tester.pumpAndSettle();
      expect(repo.notes[repo.vaults.first.id], isEmpty);
      expect(repo.allFolders(repo.vaults.first.id), isEmpty);
    },
  );

  testWidgets(
    'creates the chosen destination only after confirmation and imports the whole tree',
    (tester) async {
      await dialog(tester);
      await tester.tap(find.byKey(const Key('vault-import-destination')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Utwórz nowy folder…').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('vault-import-new-folder')),
        'New/Imported',
      );
      expect(repo.allFolders(repo.vaults.first.id), isEmpty);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('confirm-vault-import')));
        await repo.serialized(() async {});
      });
      await tester.pumpAndSettle();
      expect(find.byType(VaultImportDialog), findsNothing);
      final notes = repo.notes[repo.vaults.first.id]!.values;
      expect(notes.length, 2);
      expect(
        notes.singleWhere((n) => n.title == 'Root').folder,
        'New/Imported',
      );
      expect(
        notes.singleWhere((n) => n.title == 'Root').body,
        contains('![[Data.csv]]'),
      );
      expect(
        notes.singleWhere((n) => n.title == 'Child').folder,
        'New/Imported/Nested',
      );
      expect(
        repo.allFolders(repo.vaults.first.id),
        containsAll(['New', 'New/Imported', 'New/Imported/Nested']),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
