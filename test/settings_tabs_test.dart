import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/ui/dialogs.dart';
import 'package:silique/ui/theme.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;
import 'hidden_notes_home_test.dart' show drainUntil;

Finder _fieldByLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Finder _compactSwitch() => find.byKey(const Key('compact-mode-toggle'));

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

void main() {
  testWidgets('settings render tabs and switching keeps section content', (
    tester,
  ) async {
    final repo = await _sqliteNotebook(tester, 'silique-settings-tabs-');
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _mountPanel(tester, repo);

    // All five tabs render with their labels; the dialog starts on General.
    expect(find.text('Ogólne'), findsOneWidget);
    expect(find.text('Wygląd'), findsOneWidget);
    expect(find.text('Konto i synchronizacja'), findsOneWidget);
    expect(find.text('Pamięć i bezpieczeństwo'), findsOneWidget);
    expect(find.text('Aktualizacje'), findsOneWidget);
    expect(find.byKey(const Key('language-picker')), findsOneWidget);
    // The compact-mode switch moved to the Appearance tab, so it is absent on
    // General and present only there.
    expect(_compactSwitch(), findsNothing);
    await _openTab(tester, 'settings-tab-appearance');
    expect(_compactSwitch(), findsOneWidget);
    await _openTab(tester, 'settings-tab-general');

    // The account tab keeps every server field; the storage tab keeps the
    // hidden-notes and data-location sections; without an updater the updates
    // tab has no updates section.
    await _openTab(tester, 'settings-tab-account');
    expect(find.text('TWÓJ SERWER'), findsOneWidget);
    expect(_fieldByLabel('Adres serwera'), findsOneWidget);
    expect(_fieldByLabel('E-mail'), findsOneWidget);
    await tester.enterText(
      _fieldByLabel('Adres serwera'),
      'https://notes.example.com',
    );
    await tester.enterText(_fieldByLabel('E-mail'), 'kamil@example.com');
    final serverController = tester
        .widget<TextField>(_fieldByLabel('Adres serwera'))
        .controller;
    final emailController = tester
        .widget<TextField>(_fieldByLabel('E-mail'))
        .controller;
    await _openTab(tester, 'settings-tab-storage');
    expect(find.text('UKRYTE NOTATKI'), findsOneWidget);
    expect(find.text('MIEJSCE DANYCH'), findsOneWidget);
    expect(find.byKey(const Key('data-location')), findsOneWidget);
    await _openTab(tester, 'settings-tab-updates');
    expect(find.byKey(const Key('updates-section')), findsNothing);

    // Back on the account tab: the same controllers still hold their text.
    await _openTab(tester, 'settings-tab-account');
    expect(
      tester.widget<TextField>(_fieldByLabel('Adres serwera')).controller,
      same(serverController),
    );
    expect(
      tester.widget<TextField>(_fieldByLabel('E-mail')).controller,
      same(emailController),
    );
    expect(serverController!.text, 'https://notes.example.com');
    expect(emailController!.text, 'kamil@example.com');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('compact mode switch persists in the encrypted vault metadata', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('silique-compact-mode-');
    final keys = MemoryKeys();
    final crypto = TestCrypto();
    Notebook make() =>
        Notebook(storage: NativeStorage(dir.path), keys: keys, crypto: crypto);
    // The Notebook must be constructed inside runAsync: its serialization
    // tail future is zone-bound, and a fake-async-zone construction would
    // stall every serialized() operation (createVault, close, …).
    late Notebook repo;
    addTearDown(() async {
      await repo.close();
      dir.deleteSync(recursive: true);
    });
    await tester.runAsync(() async {
      repo = make();
      await repo.initialize();
      await repo.createVault('Compact', password: 'folder password 12345');
      await repo.createFolder(repo.vaults.single, 'Alpha');
      final note = await repo.createNote(
        repo.vaults.single.id,
        folder: 'Alpha',
      );
      await repo.save(note.copyWith(title: 'Compact sentinel'));
    });
    var vault = repo.vaults.single;
    final before = Map.of(repo.storage.documents(vault.id));
    final outbox = jsonEncode(
      repo.storage.pending(vault.id).map((r) => r.toWire()).toList(),
    );
    expect(repo.compactModeOf(vault.id), isFalse);

    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _mountPanel(tester, repo, vault: vault);
    await _openTab(tester, 'settings-tab-appearance');
    expect(tester.widget<SwitchListTile>(_compactSwitch()).value, isFalse);
    await tester.tap(_compactSwitch());
    // The metadata write runs through real SQLite; pump bounded frames.
    await drainUntil(tester, () => repo.compactModeOf(vault.id));
    expect(tester.widget<SwitchListTile>(_compactSwitch()).value, isTrue);

    // The preference is a pure metadata sibling: notes, folders and pending
    // revisions are untouched.
    expect(repo.storage.documents(vault.id), before);
    expect(
      jsonEncode(
        repo.storage.pending(vault.id).map((r) => r.toWire()).toList(),
      ),
      outbox,
      reason: 'compact mode never rewrites note documents or revisions',
    );
    // An unknown metadata key survives later preference writes.
    await tester.runAsync(() async {
      final metadata = jsonDecode(
        await crypto.open(
          repo.unlocked[vault.id]!,
          vault.metadata,
          'silique:2:vault-meta:${vault.id}',
        ),
      ) as Map<String, dynamic>;
      expect(metadata['compactMode'], isTrue);
      metadata['futureField'] = {
        'sentinel': [1, 'preserve'],
      };
      vault.metadata = await crypto.seal(
        repo.unlocked[vault.id]!,
        jsonEncode(metadata),
        'silique:2:vault-meta:${vault.id}',
      );
      repo.storage.putVault(vault);
    });

    // Reopening the panel returns the stored value.
    await tester.pumpWidget(const SizedBox());
    await _mountPanel(tester, repo, vault: vault);
    await _openTab(tester, 'settings-tab-appearance');
    expect(tester.widget<SwitchListTile>(_compactSwitch()).value, isTrue);
    await tester.pumpWidget(const SizedBox());

    // A restart (fresh Notebook over the same storage) keeps the preference
    // and the unknown sibling key; a locked vault still reads as off.
    await tester.runAsync(() async {
      await repo.close();
      repo = make();
      await repo.initialize();
      vault = repo.vaults.single;
      expect(repo.unlocked, isNot(contains(vault.id)));
      expect(repo.compactModeOf(vault.id), isFalse);
      await repo.unlock(vault, password: 'folder password 12345');
      expect(repo.compactModeOf(vault.id), isTrue);
      final decoded = jsonDecode(
        await crypto.open(
          repo.unlocked[vault.id]!,
          vault.metadata,
          'silique:2:vault-meta:${vault.id}',
        ),
      ) as Map;
      expect(decoded['futureField'], {
        'sentinel': [1, 'preserve'],
      });
      expect(repo.storage.documents(vault.id), before);
    });
    await _mountPanel(tester, repo, vault: vault);
    await _openTab(tester, 'settings-tab-appearance');
    expect(tester.widget<SwitchListTile>(_compactSwitch()).value, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('compact mode switch stays disabled without an unlocked vault', (
    tester,
  ) async {
    final repo = await _sqliteNotebook(tester, 'silique-compact-locked-');
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _mountPanel(tester, repo);
    await _openTab(tester, 'settings-tab-appearance');
    expect(tester.widget<SwitchListTile>(_compactSwitch()).value, isFalse);
    expect(tester.widget<SwitchListTile>(_compactSwitch()).onChanged, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('settings tabs stay overflow-free on a narrow large-font phone', (
    tester,
  ) async {
    final repo = await _sqliteNotebook(tester, 'silique-settings-narrow-');
    await tester.runAsync(
      () => repo.createVault('Compact', password: 'folder password 12345'),
    );
    await tester.binding.setSurfaceSize(const Size(320, 640));
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(() {
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      return tester.binding.setSurfaceSize(null);
    });
    await _mountPanel(tester, repo, vault: repo.vaults.single);
    // At 1.8x text scale a single tab label can be wider than the viewport,
    // so the pages are traversed by swiping the TabBarView instead of tapping
    // the tab bar. Every page must lay out without overflow.
    final pages = find.byType(TabBarView);
    for (var i = 0; i < 4; i++) {
      await tester.fling(pages, const Offset(-400, 0), 2000);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'overflow on page $i');
    }
    final general = find.byKey(const Key('language-picker'));
    for (var i = 0; i < 5 && general.hitTestable().evaluate().isEmpty; i++) {
      await tester.fling(pages, const Offset(400, 0), 2000);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'overflow swiping back');
    }
    expect(general.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
