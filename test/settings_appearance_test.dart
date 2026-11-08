import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/main.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/ui/dialogs.dart';
import 'package:silique/ui/theme.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;
import 'hidden_notes_home_test.dart' show drainUntil;

Finder _compactSwitch() => find.byKey(const Key('compact-mode-toggle'));

/// Creates a fresh SQLite-backed notebook over a temp directory, with a
/// teardown that closes it and removes the directory.
Future<Notebook> _sqliteNotebook(WidgetTester tester, String prefix) async {
  late Notebook repo;
  late Directory dir;
  await tester.runAsync(() async {
    dir = Directory.systemTemp.createTempSync(prefix);
    repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
  });
  addTearDown(() async {
    await repo.close();
    dir.deleteSync(recursive: true);
  });
  return repo;
}

Future<void> _mountPanel(
  WidgetTester tester,
  Notebook repo, {
  Vault? vault,
  bool openUpdates = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: siliqueTheme(),
      home: Scaffold(
        body: Center(
          child: Dialog(
            insetPadding: const EdgeInsets.all(16),
            child: SettingsPanel(
              notebook: repo,
              vault: vault,
              onChanged: () {},
              openUpdates: openUpdates,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openTab(WidgetTester tester, String tabKey) async {
  final tab = find.byKey(Key(tabKey));
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

int _tabIndex(WidgetTester tester) =>
    tester.widget<TabBar>(find.byType(TabBar)).controller!.index;

/// Taps the given appearance tile, picks the SV-center color and applies it,
/// leaving the "apply existing" question on screen.
Future<void> _pickDefaultColor(WidgetTester tester, String tileKey) async {
  await tester.tap(find.byKey(Key(tileKey)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('color-picker-sv')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('color-picker-apply')));
  await drainUntil(
    tester,
    () => find.byKey(const Key('apply-existing-no')).evaluate().isNotEmpty,
  );
}

Color? _noteIconColor(WidgetTester tester, String noteId) => tester
    .widget<Icon>(
      find.descendant(
        of: find.byKey(Key('note-card-$noteId')),
        matching: find.byIcon(Icons.description_outlined),
      ),
    )
    .color;

Color? _folderIconColor(WidgetTester tester, String path) =>
    tester.widget<Icon>(find.byKey(Key('folder-icon-$path'))).color;

void main() {
  testWidgets('appearance tab is index 1 and openUpdates selects index 4', (
    tester,
  ) async {
    final repo = await _sqliteNotebook(tester, 'silique-appearance-tabs-');
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _mountPanel(tester, repo);
    await _openTab(tester, 'settings-tab-appearance');
    expect(_tabIndex(tester), 1);
    expect(
      find.byKey(const Key('appearance-default-note-color')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('appearance-default-folder-color')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());

    // openUpdates lands on the (now index 4) updates tab.
    await _mountPanel(tester, repo, openUpdates: true);
    expect(_tabIndex(tester), 4);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('compact-mode toggle appears exactly once, only on appearance', (
    tester,
  ) async {
    final repo = await _sqliteNotebook(tester, 'silique-compact-loc-');
    await tester.runAsync(
      () => repo.createVault('Compact', password: 'folder password 12345'),
    );
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _mountPanel(tester, repo, vault: repo.vaults.single);
    // Starts on General: the switch is absent there.
    expect(_compactSwitch(), findsNothing);

    await _openTab(tester, 'settings-tab-appearance');
    expect(_compactSwitch(), findsOneWidget);

    // Back on General it is gone again — no duplicate anywhere.
    await _openTab(tester, 'settings-tab-general');
    expect(_compactSwitch(), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('default note color via the picker tints a new note icon', (
    tester,
  ) async {
    late Notebook repo;
    late Directory dir;
    late String noteId;
    await tester.runAsync(() async {
      dir = Directory.systemTemp.createTempSync('silique-note-default-');
      repo = Notebook(
        storage: NativeStorage(dir.path),
        keys: MemoryKeys(),
        crypto: TestCrypto(),
      );
      await repo.initialize();
      await repo.createVault('Notes');
      final note = await repo.createNote(repo.vaults.single.id);
      noteId = note.id;
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 1000);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      var closed = false;
      final close = repo.close().then((_) => closed = true);
      await drainUntil(tester, () => closed);
      await close;
      await tester.runAsync(() async => dir.deleteSync(recursive: true));
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final vault = repo.vaults.single;
    final before = repo.defaultNoteColorOf(vault.id);
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    await _mountPanel(tester, repo, vault: vault);
    await _openTab(tester, 'settings-tab-appearance');
    await _pickDefaultColor(tester, 'appearance-default-note-color');

    final picked = repo.defaultNoteColorOf(vault.id);
    expect(picked, isNot(before));
    expect(repo.noteColorsOf(vault.id), isEmpty);

    // "No" keeps the (already empty) explicit map; the value still sticks.
    await tester.tap(find.byKey(const Key('apply-existing-no')));
    await tester.pumpAndSettle();
    expect(repo.defaultNoteColorOf(vault.id), picked);
    await tester.pumpWidget(const SizedBox());

    // A note without an explicit color renders in the new default.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [notebookProvider.overrideWithValue(repo)],
        child: const SiliqueApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(_noteIconColor(tester, noteId), Color(picked));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'default folder color applies to colorless folders, explicit wins',
    (tester) async {
      late Notebook repo;
      late Directory dir;
      await tester.runAsync(() async {
        dir = Directory.systemTemp.createTempSync('silique-folder-default-');
        repo = Notebook(
          storage: NativeStorage(dir.path),
          keys: MemoryKeys(),
          crypto: TestCrypto(),
        );
        await repo.initialize();
        await repo.createVault('Colors');
        await repo.createFolder(repo.vaults.single, 'Alpha');
        await repo.createFolder(repo.vaults.single, 'Beta');
        await repo.setFolderColor(repo.vaults.single, 'Beta', 0xff00ff00);
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1440, 1000);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        var closed = false;
        final close = repo.close().then((_) => closed = true);
        await drainUntil(tester, () => closed);
        await close;
        await tester.runAsync(() async => dir.deleteSync(recursive: true));
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final vault = repo.vaults.single;
      expect(repo.defaultFolderColorOf(vault.id), isNull);
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      await _mountPanel(tester, repo, vault: vault);
      await _openTab(tester, 'settings-tab-appearance');
      await _pickDefaultColor(tester, 'appearance-default-folder-color');

      final picked = repo.defaultFolderColorOf(vault.id);
      expect(picked, isNotNull);
      await tester.tap(find.byKey(const Key('apply-existing-no')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());

      await tester.pumpWidget(
        ProviderScope(
          overrides: [notebookProvider.overrideWithValue(repo)],
          child: const SiliqueApp(),
        ),
      );
      await tester.pumpAndSettle();
      // Alpha has no explicit color: it renders the new default.
      expect(_folderIconColor(tester, 'Alpha'), Color(picked!));
      // Beta keeps its explicit color.
      expect(_folderIconColor(tester, 'Beta'), const Color(0xff00ff00));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'apply-existing question: "no" keeps, "yes" clears explicit colors',
    (tester) async {
      late Notebook repo;
      late Directory dir;
      late String noteId;
      await tester.runAsync(() async {
        dir = Directory.systemTemp.createTempSync('silique-apply-existing-');
        repo = Notebook(
          storage: NativeStorage(dir.path),
          keys: MemoryKeys(),
          crypto: TestCrypto(),
        );
        await repo.initialize();
        await repo.createVault('Notes');
        final note = await repo.createNote(repo.vaults.single.id);
        noteId = note.id;
        await repo.setNoteColor(repo.vaults.single, note.id, 0xffff0000);
        await repo.createFolder(repo.vaults.single, 'Alpha');
        await repo.setFolderColor(repo.vaults.single, 'Alpha', 0xff0000ff);
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1440, 1000);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        var closed = false;
        final close = repo.close().then((_) => closed = true);
        await drainUntil(tester, () => closed);
        await close;
        await tester.runAsync(() async => dir.deleteSync(recursive: true));
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final vault = repo.vaults.single;
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      await _mountPanel(tester, repo, vault: vault);
      await _openTab(tester, 'settings-tab-appearance');

      // "No" leaves the explicit note color in place.
      await _pickDefaultColor(tester, 'appearance-default-note-color');
      final pickedNote = repo.defaultNoteColorOf(vault.id);
      await tester.tap(find.byKey(const Key('apply-existing-no')));
      await tester.pumpAndSettle();
      expect(repo.noteColorsOf(vault.id), {noteId: 0xffff0000});

      // "Yes" clears every explicit note color; the map becomes empty.
      await _pickDefaultColor(tester, 'appearance-default-note-color');
      await tester.tap(find.byKey(const Key('apply-existing-yes')));
      await drainUntil(tester, () => repo.noteColorsOf(vault.id).isEmpty);
      expect(repo.noteColorsOf(vault.id), isEmpty);

      // Same for folders: "yes" clears the explicit folder color.
      await _pickDefaultColor(tester, 'appearance-default-folder-color');
      final pickedFolder = repo.defaultFolderColorOf(vault.id);
      await tester.tap(find.byKey(const Key('apply-existing-yes')));
      await drainUntil(tester, () => repo.folderColorsOf(vault.id).isEmpty);
      expect(repo.folderColorsOf(vault.id), isEmpty);
      await tester.pumpWidget(const SizedBox());

      // All existing elements now render the new default values.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [notebookProvider.overrideWithValue(repo)],
          child: const SiliqueApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(_noteIconColor(tester, noteId), Color(pickedNote));
      expect(_folderIconColor(tester, 'Alpha'), Color(pickedFolder!));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
