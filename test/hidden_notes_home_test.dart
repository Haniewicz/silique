import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';
import 'package:silique/main.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/ui/dialogs.dart';
import 'package:silique/ui/hidden_notes_page.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

Future<void> drainUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 80; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    if (done()) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('UI/persistence did not finish within the bounded test pump');
}

Future<Notebook> fixture(WidgetTester tester) async {
  late Notebook repo;
  late Directory dir;
  await tester.runAsync(() async {
    dir = Directory.systemTemp.createTempSync('hidden-home-');
    repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Phone');
    final note = await repo.createNote(repo.vaults.single.id);
    await repo.save(
      note.copyWith(title: 'Visible secret', body: 'Original secret body'),
    );
  });
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    var closed = false;
    final close = repo.close().then((_) => closed = true);
    await drainUntil(tester, () => closed);
    await close;
    await tester.runAsync(() async {
      dir.deleteSync(recursive: true);
    });
  });
  return repo;
}

Future<void> mount(
  WidgetTester tester,
  Notebook repo, {
  bool desktop = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = desktop
      ? const Size(1440, 1000)
      : const Size(390, 844);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [notebookProvider.overrideWithValue(repo)],
      child: const SiliqueApp(),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> chooseHiddenFolder(WidgetTester tester) async {
  final drawer = find.byTooltip('Foldery i vaulty');
  if (drawer.evaluate().isNotEmpty) {
    await tester.tap(drawer);
    await tester.pumpAndSettle();
  }
  final entry = find.byKey(const Key('hidden-folder-nav'));
  await tester.ensureVisible(entry);
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

Future<void> password(WidgetTester tester) async {
  final fields = find.descendant(
    of: find.byType(AlertDialog),
    matching: find.byType(TextField),
  );
  await tester.enterText(fields.first, 'test hidden password');
  await tester.enterText(fields.last, 'test hidden password');
  await tester.tap(find.widgetWithText(FilledButton, 'Utwórz hasło'));
}

void main() {
  testWidgets('ordinary save failure cannot skip hidden background locking', (
    tester,
  ) async {
    final repo = await fixture(tester);
    await tester.runAsync(() => repo.setHiddenPassword('test hidden password'));
    await mount(tester, repo);
    await tester.tap(find.text('Visible secret'));
    await tester.pumpAndSettle();
    (repo.storage as NativeStorage).db.execute(
      "CREATE TRIGGER fail_normal_save BEFORE INSERT ON documents WHEN NEW.vault_id NOT LIKE 'hidden:%' BEGIN SELECT RAISE(ABORT, 'simulated storage failure'); END",
    );
    await tester.enterText(
      find.byKey(const Key('note-title')),
      'Unsaved regular title',
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    try {
      var queueDrained = false;
      final drain = repo.serialized(() async {
        queueDrained = true;
      });
      await drainUntil(tester, () => queueDrained);
      await drain;
      expect(repo.hiddenUnlocked, isFalse);
    } finally {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      (repo.storage as NativeStorage).db.execute(
        'DROP TRIGGER fail_normal_save',
      );
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'home first move requests a password; opening and editing stay hidden; explicit reveal decrypts',
    (tester) async {
      final repo = await fixture(tester);
      final id = repo.vaults.single.id;
      await mount(tester, repo);
      await tester.tap(find.text('Visible secret'));
      await tester.pumpAndSettle();
      final previousBody = tester
          .widget<LiveMarkdownEditor>(find.byType(LiveMarkdownEditor))
          .controller;
      await tester.tap(find.byKey(const Key('note-options')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ukryj notatkę (hasło)'));
      await tester.pumpAndSettle();
      expect(find.text('Przenieść do ukrytych?'), findsOneWidget);
      final confirm = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(FilledButton),
      );
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(find.text('Hasło ukrytych notatek'), findsOneWidget);
      await password(tester);
      await drainUntil(tester, () => repo.notes[id]!.isEmpty);
      await tester.runAsync(() => repo.setHiddenAutoLock(null));
      expect(find.text('Visible secret'), findsNothing);
      expect(repo.storage.documents('hidden:$id'), hasLength(1));
      expect(
        previousBody.text,
        isEmpty,
        reason: 'Moving to hidden wipes the former ordinary editor controller',
      );
      expect(previousBody.canUndo, isFalse);
      expect(previousBody.canRedo, isFalse);
      previousBody.undo();
      previousBody.redo();
      expect(previousBody.text, isEmpty);
      await chooseHiddenFolder(tester);
      await drainUntil(
        tester,
        () => find.text('Visible secret').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Visible secret'));
      await tester.pumpAndSettle();
      expect(find.byType(HiddenNotesPage), findsNothing);
      expect(
        repo.notes[id],
        isEmpty,
        reason: 'Reading a hidden note is not moving it out',
      );
      tester
              .widget<LiveMarkdownEditor>(find.byType(LiveMarkdownEditor))
              .controller
              .text =
          'Edited still private';
      await tester.tap(find.byKey(const Key('note-options')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Przenieś do folderu'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('folder-target-confirm')));
      await drainUntil(
        tester,
        () =>
            !repo.hiddenUnlocked &&
            repo.storage.documents('hidden:$id').isEmpty &&
            find.text('Moje notatki').evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(seconds: 2));
      expect(repo.notes[id]!.values.single.body, 'Edited still private');
      expect(repo.notes[id]!.values.single.hidden, isFalse);
      expect(repo.storage.documents('hidden:$id'), isEmpty);
      expect(
        repo.hiddenUnlocked,
        isFalse,
        reason: 'Leaving the secret section locks it',
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'first hidden creation asks for a password and never creates an ordinary copy',
    (tester) async {
      final repo = await fixture(tester);
      final id = repo.vaults.single.id;
      await mount(tester, repo);
      await chooseHiddenFolder(tester);
      expect(find.text('Hasło ukrytych notatek'), findsOneWidget);
      await password(tester);
      await drainUntil(tester, () => repo.hiddenUnlocked);
      await tester.runAsync(() => repo.setHiddenAutoLock(null));
      expect(repo.storage.documents('hidden:$id'), isEmpty);
      await tester.tap(find.byType(FloatingActionButton));
      await drainUntil(
        tester,
        () => find.byType(LiveMarkdownEditor).evaluate().isNotEmpty,
      );
      await tester.enterText(
        find.byKey(const Key('note-title')),
        'Fresh hidden',
      );
      tester
              .widget<LiveMarkdownEditor>(find.byType(LiveMarkdownEditor))
              .controller
              .text =
          'Fresh hidden body';
      await tester.tap(find.byKey(const Key('editor-back')));
      await drainUntil(
        tester,
        () => find.byType(LiveMarkdownEditor).evaluate().isEmpty,
      );
      // Returning to the list stays in the same hidden folder; departure locks.
      expect(repo.hiddenUnlocked, isTrue);
      await tester.tap(find.text('Notatki').last);
      await drainUntil(tester, () => !repo.hiddenUnlocked);
      expect(repo.notes[id]!.values.map((n) => n.title), ['Visible secret']);
      expect(repo.storage.documents('hidden:$id'), hasLength(1));
      expect(repo.hiddenUnlocked, isFalse);
      await chooseHiddenFolder(tester);
      await tester.pumpAndSettle();
      expect(find.text('Odblokuj ukryte notatki'), findsOneWidget);
      expect(find.text('Fresh hidden'), findsNothing);
      await tester.tap(find.text('Anuluj'));
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('timed hidden unlock survives leaving the section and re-entry', (
    tester,
  ) async {
    final repo = await fixture(tester);
    await tester.runAsync(() async {
      await repo.setHiddenPassword('test hidden password');
      await repo.setHiddenAutoLock(const Duration(minutes: 5));
    });
    await mount(tester, repo);
    await chooseHiddenFolder(tester);
    expect(repo.hiddenUnlocked, isTrue);
    await tester.tap(find.text('Notatki').last);
    await tester.pumpAndSettle();
    expect(
      repo.hiddenUnlocked,
      isTrue,
      reason: 'Navigation must not shorten the configured idle timeout',
    );
    await chooseHiddenFolder(tester);
    expect(find.text('Odblokuj ukryte notatki'), findsNothing);
    expect(repo.hiddenUnlocked, isTrue);
    await tester.runAsync(repo.lockHidden);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'background locks a retained hidden key before ordinary save completes',
    (tester) async {
      final repo = await fixture(tester);
      await tester.runAsync(() async {
        await repo.setHiddenPassword('test hidden password');
        await repo.setHiddenAutoLock(const Duration(minutes: 5));
      });
      await mount(tester, repo);
      await chooseHiddenFolder(tester);
      await tester.tap(find.text('Notatki').last);
      await tester.pumpAndSettle();
      expect(repo.hiddenUnlocked, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(repo.hiddenUnlocked, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await drainUntil(tester, () => !repo.hiddenUnlocked);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('changing to section-exit lock revokes retained hidden access', (
    tester,
  ) async {
    final repo = await fixture(tester);
    await tester.runAsync(() async {
      await repo.setHiddenPassword('test hidden password');
      await repo.setHiddenAutoLock(const Duration(minutes: 5));
    });
    await mount(tester, repo);
    await chooseHiddenFolder(tester);
    await tester.tap(find.text('Notatki').last);
    await tester.pumpAndSettle();
    expect(repo.hiddenUnlocked, isTrue);
    await tester.tap(find.byTooltip('Ustawienia'));
    await tester.pumpAndSettle();
    // The hidden-notes policies live on the storage & security tab.
    final storageTab = find.byKey(const Key('settings-tab-storage'));
    await tester.ensureVisible(storageTab);
    await tester.pumpAndSettle();
    await tester.tap(storageTab);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('hidden-auto-lock')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('hidden-auto-lock')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.text('Przy wyjściu z sekcji / zamknięciu aplikacji').last,
    );
    await drainUntil(tester, () => repo.hiddenAutoLock == null);
    expect(repo.hiddenUnlocked, isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('hidden reveal chooses folder and waits for confirmation', (
    tester,
  ) async {
    final repo = await fixture(tester);
    final id = repo.vaults.single.id;
    await tester.runAsync(() async {
      await repo.createFolder(repo.vaults.single, 'Archiwum');
      await repo.setHiddenPassword('test hidden password');
      await repo.hideNote(repo.notes[id]!.values.single);
    });
    await mount(tester, repo);
    await chooseHiddenFolder(tester);
    await drainUntil(
      tester,
      () => find.text('Visible secret').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('Visible secret'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note-options')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Przenieś do folderu'));
    await tester.pumpAndSettle();
    expect(repo.storage.documents('hidden:$id'), hasLength(1));
    await tester.tap(find.byKey(const Key('folder-target-Archiwum')));
    await tester.pumpAndSettle();
    expect(repo.storage.documents('hidden:$id'), hasLength(1));
    await tester.tap(find.byKey(const Key('folder-target-confirm')));
    await drainUntil(
      tester,
      () =>
          repo.storage.documents('hidden:$id').isEmpty &&
          find.text('Moje notatki').evaluate().isNotEmpty,
    );
    expect(repo.notes[id]!.values.single.folder, 'Archiwum');
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(repo.lockHidden);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('hidden note deletion requires confirmation', (tester) async {
    final repo = await fixture(tester);
    final id = repo.vaults.single.id;
    await tester.runAsync(() async {
      await repo.setHiddenPassword('test hidden password');
      await repo.hideNote(repo.notes[id]!.values.single);
    });
    await mount(tester, repo);
    await chooseHiddenFolder(tester);
    await drainUntil(
      tester,
      () => find.text('Visible secret').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('Visible secret'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note-options')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Usuń ukrytą notatkę'));
    await tester.pumpAndSettle();
    expect(repo.storage.documents('hidden:$id'), hasLength(1));
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(FilledButton),
      ),
    );
    await drainUntil(
      tester,
      () => repo.storage.documents('hidden:$id').isEmpty,
    );
    expect(repo.notes[id], isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'phone settings persist idle and background policies without layout overflow',
    (tester) async {
      final repo = await fixture(tester);
      await tester.runAsync(
        () => repo.setHiddenPassword('test hidden password'),
      );
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Dialog(
              insetPadding: const EdgeInsets.all(16),
              child: SettingsPanel(notebook: repo, onChanged: () {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The hidden-notes policies live on the storage & security tab.
      final storageTab = find.byKey(const Key('settings-tab-storage'));
      await tester.ensureVisible(storageTab);
      await tester.pumpAndSettle();
      await tester.tap(storageTab);
      await tester.pumpAndSettle();
      final policy = find.byKey(const Key('hidden-auto-lock'));
      await tester.ensureVisible(policy);
      await tester.pumpAndSettle();
      await tester.tap(policy);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Po 1 min bez aktywności').last);
      await drainUntil(
        tester,
        () => repo.hiddenAutoLock == const Duration(minutes: 1),
      );
      await tester.tap(policy);
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('Przy wyjściu z sekcji / zamknięciu aplikacji').last,
      );
      await drainUntil(tester, () => repo.hiddenAutoLock == null);
      final background = find.byKey(const Key('hidden-lock-background'));
      await tester.ensureVisible(background);
      await tester.tap(background);
      await drainUntil(tester, () => !repo.hiddenLockOnBackground);
      expect(tester.takeException(), isNull);
    },
  );
}
