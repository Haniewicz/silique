import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/main.dart';
import 'package:silique/l10n/app_language.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/ui/hidden_notes_page.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

Future<void> drainIo(WidgetTester tester, Future<void> operation) async {
  var completed = false;
  Object? failure;
  StackTrace? failureStack;
  operation.then<void>(
    (_) {
      completed = true;
    },
    onError: (Object error, StackTrace stack) {
      failure = error;
      failureStack = stack;
      completed = true;
    },
  );
  // Repository work can await both real filesystem I/O and continuations
  // registered by Home in the widget's fake-async zone. Neither runAsync nor
  // pumpAndSettle alone drains both; never await the queue inside runAsync.
  for (var i = 0; i < 100 && !completed; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  expect(
    completed,
    isTrue,
    reason: 'Repository I/O did not finish in 100 turns',
  );
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
}

Future<Notebook> fixture(
  WidgetTester tester, {
  bool seedExisting = true,
}) async {
  late Notebook repo;
  late Directory directory;
  await tester.runAsync(() async {
    directory = Directory.systemTemp.createTempSync('home-language-');
    repo = Notebook(
      storage: NativeStorage(directory.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    if (seedExisting) {
      await repo.createVault('Existing Polish vault');
      final note = await repo.createNote(repo.vaults.single.id);
      await repo.save(note.copyWith(title: 'Moja istniejąca notatka'));
    }
  });
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    final closing = repo.close();
    for (var i = 0; i < 8; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await closing;
    await tester.runAsync(() async => directory.deleteSync(recursive: true));
  });
  return repo;
}

void main() {
  late String previousLanguage;
  setUp(() async {
    previousLanguage = appLanguage.languageCode;
    await appLanguage.setLanguage('en');
  });
  tearDown(() => appLanguage.setLanguage(previousLanguage));

  testWidgets(
    'English home translates navigation but preserves existing titles',
    (tester) async {
      final repo = await fixture(tester);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1380, 880);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [notebookProvider.overrideWithValue(repo)],
          child: const SiliqueApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('All notes'), findsOneWidget);
      expect(find.text('Deleted'), findsOneWidget);
      expect(find.byTooltip('Sync settings'), findsOneWidget);
      expect(find.text('Moja istniejąca notatka'), findsWidgets);
      expect(
        repo.notes[repo.vaults.single.id]!.values.single.title,
        'Moja istniejąca notatka',
      );
      expect(find.byTooltip('Bold'), findsOneWidget);
      expect(find.byTooltip('Markdown / live preview'), findsOneWidget);
      final titleController = tester
          .widget<TextField>(find.byKey(const Key('note-title')))
          .controller;
      await tester.runAsync(() => appLanguage.setLanguage('pl'));
      await tester.pumpAndSettle();
      expect(find.text('Wszystkie notatki'), findsOneWidget);
      expect(find.byTooltip('Ustawienia synchronizacji'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('note-title')))
            .controller,
        same(titleController),
      );
      expect(titleController!.text, 'Moja istniejąca notatka');
    },
  );

  testWidgets('English new note stores Untitled only at creation', (
    tester,
  ) async {
    final repo = await fixture(tester);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1380, 880);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [notebookProvider.overrideWithValue(repo)],
        child: const SiliqueApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'New note'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    final notes = repo.notes[repo.vaults.single.id]!.values;
    expect(notes.map((note) => note.title), contains('Untitled'));
    expect(
      notes.map((note) => note.title),
      contains('Moja istniejąca notatka'),
    );
  });

  for (final language in ['en', 'pl']) {
    testWidgets('$language onboarding seeds folder only at creation', (
      tester,
    ) async {
      await tester.runAsync(() => appLanguage.setLanguage(language));
      final repo = await fixture(tester, seedExisting: false);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1380, 880);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [notebookProvider.overrideWithValue(repo)],
          child: const SiliqueApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(language == 'en' ? 'Start locally' : 'Rozpocznij lokalnie'),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      final note = repo.notes[repo.vaults.single.id]!.values.single;
      final expectedFolder = language == 'en' ? 'Projects' : 'Projekty';
      expect(note.folder, expectedFolder);
      await drainIo(tester, () async {
        final userNote = await repo.createNote(
          repo.vaults.single.id,
          folder: 'Projekty użytkownika',
        );
        await repo.save(userNote.copyWith(title: 'User note'));
      }());
      await tester.runAsync(
        () => appLanguage.setLanguage(language == 'en' ? 'pl' : 'en'),
      );
      await tester.pumpAndSettle();
      expect(
        repo.notes[repo.vaults.single.id]![note.id]!.folder,
        expectedFolder,
      );
      expect(
        repo.notes[repo.vaults.single.id]!.values.map((n) => n.folder),
        contains('Projekty użytkownika'),
      );
    });
  }

  testWidgets('English hidden page explains the locked state', (tester) async {
    final repo = await fixture(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: HiddenNotesPage(notebook: repo, vaultId: repo.vaults.single.id),
      ),
    );
    await tester.pump();
    expect(find.text('Hidden notes'), findsOneWidget);
    expect(find.text('Hidden notes are locked.'), findsOneWidget);
  });
}
