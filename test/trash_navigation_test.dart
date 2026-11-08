import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/models.dart';
import 'package:silique/main.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/ui/home.dart';

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
  fail('Navigation/persistence did not finish within the bounded test pump');
}

Future<({Notebook repo, Note active, Note deleted})> fixture(
  WidgetTester tester, {
  bool locked = false,
  bool emptyTrash = false,
}) async {
  late Notebook repo;
  late Directory dir;
  late Note active, deleted;
  await tester.runAsync(() async {
    // Dart resolves the platform's temp root (and honors TMPDIR when present).
    dir = Directory.systemTemp.createTempSync('trash-navigation-');
    repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault(
      'Navigation',
      password: locked ? 'vault password 123' : null,
    );
    final id = repo.vaults.single.id;
    active = (await repo.createNote(
      id,
      folder: 'Projects',
    )).copyWith(title: 'Active project', body: 'Ordinary content');
    await repo.save(active);
    deleted = (await repo.createNote(id, folder: 'Archive')).copyWith(
      title: 'Deleted archive',
      body: 'Recoverable content',
      deleted: !emptyTrash,
    );
    await repo.save(deleted);
    if (locked) repo.lock(id);
  });
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    var closed = false;
    final close = repo.close().then((_) => closed = true);
    await drainUntil(tester, () => closed);
    await close;
    await tester.runAsync(() async => dir.deleteSync(recursive: true));
  });
  return (repo: repo, active: active, deleted: deleted);
}

Future<void> mount(WidgetTester tester, Notebook repo, bool phone) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = phone
      ? const Size(390, 844)
      : const Size(1380, 880);
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
  expect(find.byType(HomeScreen), findsOneWidget);
}

Finder get search => find.descendant(
  of: find.byKey(const Key('note-search-field')),
  matching: find.byType(TextField),
);

Finder card(Note note) => find.byKey(Key('note-card-${note.id}'));

Future<void> navigate(WidgetTester tester, bool phone, String label) async {
  if (phone) {
    await tester.tap(find.byTooltip('Foldery i vaulty'));
    await tester.pumpAndSettle();
  }
  final destination = phone
      ? find.descendant(of: find.byType(Drawer), matching: find.text(label))
      : find.text(label).first;
  expect(destination, findsOneWidget);
  expect(tester.getCenter(destination).dx, lessThan(phone ? 260 : 220));
  await tester.ensureVisible(destination);
  await tester.tap(destination);
  await tester.pumpAndSettle();
  if (phone) {
    expect(
      tester.state<ScaffoldState>(find.byType(Scaffold).first).isDrawerOpen,
      isFalse,
    );
  }
}

void expectNoHorizontalTrash() {
  final horizontalRows = find.byWidgetPredicate(
    (widget) =>
        widget is SingleChildScrollView &&
        widget.scrollDirection == Axis.horizontal,
  );
  for (final label in ['Kosz', 'Usunięte']) {
    expect(
      find.descendant(of: horizontalRows, matching: find.text(label)),
      findsNothing,
    );
  }
}

void main() {
  for (final phone in [true, false]) {
    final layout = phone ? 'phone drawer' : 'desktop sidebar';
    testWidgets(
      '$layout empty trash stays separate and can return to ordinary notes',
      (tester) async {
        final data = await fixture(tester, emptyTrash: true);
        await mount(tester, data.repo, phone);
        await navigate(tester, phone, 'Usunięte');
        expectNoHorizontalTrash();
        expect(card(data.active), findsNothing);
        expect(card(data.deleted), findsNothing);
        expect(find.text('Miejsce na Twoje myśli'), findsOneWidget);
        await tester.tap(find.byTooltip('Wszystkie notatki'));
        await tester.pumpAndSettle();
        expect(card(data.active), findsOneWidget);
        expect(card(data.deleted), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(
        phone ? TargetPlatform.android : TargetPlatform.linux,
      ),
    );

    testWidgets(
      '$layout locked trash never exposes notes and unlock preserves deleted filter',
      (tester) async {
        final data = await fixture(tester, locked: true);
        await mount(tester, data.repo, phone);
        await navigate(tester, phone, 'Usunięte');
        expect(find.text('Ten vault jest chroniony'), findsWidgets);
        expect(card(data.active), findsNothing);
        expect(card(data.deleted), findsNothing);
        expect(data.repo.unlocked, isEmpty);
        await tester.tap(find.widgetWithText(FilledButton, 'Odblokuj').first);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          'vault password 123',
        );
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(FilledButton),
          ),
        );
        await drainUntil(
          tester,
          () => card(data.deleted).evaluate().isNotEmpty,
        );
        // askText disposes its controller one second after the dialog closes.
        await tester.pump(const Duration(seconds: 1));
        expect(card(data.active), findsNothing);
        await navigate(tester, phone, 'Wszystkie notatki');
        expect(card(data.active), findsOneWidget);
        expect(card(data.deleted), findsNothing);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(
        phone ? TargetPlatform.android : TargetPlatform.linux,
      ),
    );

    testWidgets(
      '$layout permanent deletion still requires confirmation',
      (tester) async {
        final data = await fixture(tester);
        await mount(tester, data.repo, phone);
        await navigate(tester, phone, 'Usunięte');
        await tester.tap(find.byKey(const Key('select-mode')));
        await tester.tap(card(data.deleted));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('bulk-purge')));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(find.text('Anuluj'));
        await tester.pumpAndSettle();
        expect(card(data.deleted), findsOneWidget);
        expect(
          data.repo.notes[data.deleted.vaultId]![data.deleted.id]!.deleted,
          isTrue,
        );
        await tester.tap(find.byKey(const Key('bulk-purge')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Potwierdź'));
        await drainUntil(
          tester,
          () =>
              !data.repo.notes[data.deleted.vaultId]!.containsKey(
                data.deleted.id,
              ) &&
              card(data.deleted).evaluate().isEmpty,
        );
        expect(
          data.repo.storage
              .documents(data.deleted.vaultId)
              .containsKey(data.deleted.id),
          isFalse,
        );
        await navigate(tester, phone, 'Wszystkie notatki');
        expect(card(data.active), findsOneWidget);
        expect(card(data.deleted), findsNothing);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(
        phone ? TargetPlatform.android : TargetPlatform.linux,
      ),
    );

    for (final exit in ['close', 'recent']) {
      testWidgets(
        '$layout leaving trash via $exit clears trash-only search',
        (tester) async {
          final data = await fixture(tester);
          await mount(tester, data.repo, phone);
          await navigate(tester, phone, 'Usunięte');
          await tester.enterText(search, 'Deleted archive');
          await tester.pumpAndSettle();
          expect(card(data.deleted), findsOneWidget);
          expect(card(data.active), findsNothing);
          if (exit == 'close') {
            await tester.tap(find.byTooltip('Wszystkie notatki'));
          } else {
            await tester.tap(find.text('Ostatnie'));
          }
          await tester.pumpAndSettle();
          expect(tester.widget<TextField>(search).controller!.text, isEmpty);
          expect(card(data.active), findsOneWidget);
          expect(card(data.deleted), findsNothing);
          expect(find.byTooltip('Wszystkie notatki'), findsNothing);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(
          phone ? TargetPlatform.android : TargetPlatform.linux,
        ),
      );
    }
    testWidgets(
      '$layout trash navigation clears folder/search and restores to ordinary list',
      (tester) async {
        final data = await fixture(tester);
        await mount(tester, data.repo, phone);
        expectNoHorizontalTrash();
        await navigate(tester, phone, 'Projects');
        expect(card(data.active), findsOneWidget);
        expect(card(data.deleted), findsNothing);
        await tester.enterText(search, 'Active project');
        await tester.pumpAndSettle();

        await navigate(tester, phone, 'Usunięte');
        expect(tester.widget<TextField>(search).controller!.text, isEmpty);
        expect(card(data.deleted), findsOneWidget);
        expect(card(data.active), findsNothing);
        expectNoHorizontalTrash();

        await tester.tap(find.byKey(const Key('select-mode')));
        await tester.tap(card(data.deleted));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('bulk-restore')), findsOneWidget);
        expect(find.byKey(const Key('bulk-purge')), findsOneWidget);
        await tester.tap(find.byKey(const Key('bulk-restore')));
        await drainUntil(
          tester,
          () =>
              !data
                  .repo
                  .notes[data.deleted.vaultId]![data.deleted.id]!
                  .deleted &&
              card(data.deleted).evaluate().isEmpty,
        );
        expect(card(data.deleted), findsNothing);
        await navigate(tester, phone, 'Wszystkie notatki');
        expect(card(data.active), findsOneWidget);
        expect(card(data.deleted), findsOneWidget);
        expect(
          data.repo.notes[data.deleted.vaultId]![data.deleted.id]!.body,
          'Recoverable content',
        );
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(
        phone ? TargetPlatform.android : TargetPlatform.linux,
      ),
    );
  }
}
