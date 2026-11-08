import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/storage/native_window.dart';
import 'package:silique/ui/hidden_notes_page.dart';
import 'package:silique/ui/home.dart';

import 'hidden_notes_home_test.dart'
    show fixture, mount, drainUntil, chooseHiddenFolder, password;

Future<void> tapPrivateLink(WidgetTester tester) async {
  if (find.text('Private target').evaluate().isNotEmpty) {
    await tester.tap(find.text('Private target'));
    return;
  }
  final field = find
      .descendant(
        of: find.byType(LiveMarkdownEditor),
        matching: find.byType(EditableText),
      )
      .first;
  final state = tester.state<EditableTextState>(field);
  final start = state.widget.controller.text.indexOf('Private target');
  expect(start, greaterThanOrEqualTo(0));
  final box = state.renderEditable
      .getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + 7),
      )
      .first;
  await tester.tapAt(
    state.renderEditable.localToGlobal(box.toRect().center),
    kind: PointerDeviceKind.mouse,
  );
}

Future<Note> seedHidden(WidgetTester tester, Notebook repo) async {
  late Note hidden;
  await tester.runAsync(() async {
    await repo.setHiddenPassword('test hidden password');
    hidden = await repo.createHiddenNote(repo.vaults.single.id);
    hidden = hidden.copyWith(title: 'Private title', body: 'Private **body**');
    await repo.save(hidden);
  });
  return hidden;
}

Future<void> enterHidden(WidgetTester tester) async {
  await chooseHiddenFolder(tester);
  await drainUntil(
    tester,
    () => find.text('Private title').evaluate().isNotEmpty,
  );
}

Future<void> openHidden(WidgetTester tester) async {
  await enterHidden(tester);
  await tester.tap(find.text('Private title'));
  await tester.pumpAndSettle();
  expect(find.byType(LiveMarkdownEditor), findsOneWidget);
  expect(find.byType(HiddenNotesPage), findsNothing);
}

void expectHistoryForgotten(LiveMarkdownController controller) {
  expect(controller.text, isEmpty);
  expect(controller.canUndo, isFalse, reason: 'no plaintext undo snapshots');
  expect(controller.canRedo, isFalse, reason: 'no plaintext redo snapshots');
  controller.undo();
  controller.redo();
  expect(
    controller.text,
    isEmpty,
    reason: 'history cannot resurrect plaintext',
  );
}

void expectForgotten(
  WidgetTester tester,
  TextEditingController title,
  LiveMarkdownController body,
) {
  expect(
    title.text,
    isEmpty,
    reason: 'retained title controller must be wiped',
  );
  expectHistoryForgotten(body);
  expect(find.textContaining('Private'), findsNothing);
  expect(find.byType(LiveMarkdownEditor), findsNothing);
  expect(find.byKey(const Key('find-bar')), findsNothing);
}

/// Advances real time (not fake-zone frames) until [clock] reaches [target].
///
/// The hidden auto-lock uses real timers, so assertions about idle refresh must
/// be anchored to a monotonic clock rather than to a single delay: a delayed
/// CI runner can otherwise consume the whole lock window before the simulated
/// activity is dispatched, which is not a product failure.
Future<void> waitForRealTime(
  WidgetTester tester,
  Stopwatch clock,
  Duration target,
) async {
  while (clock.elapsed < target) {
    final remaining = target - clock.elapsed;
    await tester.runAsync(
      () => Future<void>.delayed(
        remaining < const Duration(milliseconds: 25)
            ? remaining
            : const Duration(milliseconds: 25),
      ),
    );
  }
}

void main() {
  for (final activity in ['pointer', 'key']) {
    testWidgets(
      'hidden $activity activity without edits refreshes the idle timer',
      (tester) async {
        final repo = await fixture(tester);
        await seedHidden(tester, repo);
        await mount(tester, repo);
        await openHidden(tester);
        const window = Duration(seconds: 4);
        final clock = Stopwatch()..start();
        await tester.runAsync(() => repo.setHiddenAutoLock(window));
        expect(
          repo.hiddenUnlocked,
          isTrue,
          reason: 'activity below must start while still unlocked',
        );
        // Keep the user active across more than the whole window. Any single
        // refresh moves the deadline, so surviving past it proves refresh;
        // continuous activity keeps the assertion tolerant of CI jitter.
        while (clock.elapsed < window * 2) {
          if (activity == 'pointer') {
            await tester.tap(find.byKey(const Key('note-title')));
          } else {
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          }
          await waitForRealTime(
            tester,
            clock,
            clock.elapsed + const Duration(milliseconds: 250),
          );
        }
        await tester.pump();
        expect(
          repo.hiddenUnlocked,
          isTrue,
          reason: 'A user reading/positioning the caret is still active',
        );
        expect(find.byKey(const Key('note-title')), findsOneWidget);
      },
    );
  }

  for (final desktop in [false, true]) {
    testWidgets(
      'first password cancel and empty hidden folder do not create ordinary copies desktop=$desktop',
      (tester) async {
        final repo = await fixture(tester);
        final id = repo.vaults.single.id;
        final ordinaryDocuments = repo.storage.documents(id);
        final revisionIds = repo.storage
            .revisions(id)
            .map((r) => r.id)
            .toList();
        await mount(tester, repo, desktop: desktop);
        await chooseHiddenFolder(tester);
        expect(find.text('Hasło ukrytych notatek'), findsOneWidget);
        await tester.tap(find.text('Anuluj'));
        await tester.pumpAndSettle();
        expect(repo.hiddenPasswordSet, isFalse);
        expect(repo.hiddenUnlocked, isFalse);
        expect(repo.storage.documents('hidden:$id'), isEmpty);
        expect(repo.storage.documents(id), ordinaryDocuments);
        await chooseHiddenFolder(tester);
        await password(tester);
        await drainUntil(
          tester,
          () =>
              repo.hiddenUnlocked &&
              find.byType(AlertDialog).evaluate().isEmpty,
        );
        expect(
          repo.storage.documents('hidden:$id'),
          isEmpty,
          reason: 'Entering a new folder never creates an empty note',
        );
        expect(find.byKey(const Key('note-title')), findsNothing);
        if (desktop) {
          await tester.tap(find.text('Nowa notatka').first);
        } else {
          await tester.tap(find.byType(FloatingActionButton));
        }
        await drainUntil(
          tester,
          () => find.byType(LiveMarkdownEditor).evaluate().isNotEmpty,
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('note-title')))
              .controller!
              .text,
          'Bez tytułu',
        );
        expect(
          tester
              .widget<LiveMarkdownEditor>(find.byType(LiveMarkdownEditor))
              .controller
              .text,
          isEmpty,
        );
        final toggle = find.byTooltip('Markdown / podgląd na żywo');
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('source-editor')),
          'Private created source body',
        );
        await tester.tap(find.byKey(const Key('hidden-lock-now')).last);
        await drainUntil(tester, () => !repo.hiddenUnlocked);
        expect(repo.storage.documents(id), ordinaryDocuments);
        expect(repo.storage.revisions(id).map((r) => r.id), revisionIds);
        expect(repo.storage.documents('hidden:$id'), hasLength(1));
        expect(
          repo.storage.documents('hidden:$id').values.single,
          isNot(contains('Private created')),
        );
        await tester.runAsync(() => repo.unlockHidden('test hidden password'));
        final stored = (await tester.runAsync(() => repo.hiddenNotes(id)))!;
        expect(stored.single.body, 'Private created source body');
        expect(stored.single.hidden, isTrue);
      },
    );
  }

  testWidgets(
    'hidden title and source preserve disabled keyboard suggestions',
    (tester) async {
      final repo = await fixture(tester);
      await seedHidden(tester, repo);
      await mount(tester, repo);
      await openHidden(tester);
      final title = tester.widget<TextField>(
        find.byKey(const Key('note-title')),
      );
      final liveFields = tester
          .widgetList<EditableText>(
            find.descendant(
              of: find.byType(LiveMarkdownEditor),
              matching: find.byType(EditableText),
            ),
          )
          .toList();
      expect(liveFields, isNotEmpty);
      for (final field in liveFields) {
        expect(field.autocorrect, isFalse);
        expect(field.enableSuggestions, isFalse);
        expect(field.enableIMEPersonalizedLearning, isFalse);
      }
      final toggle = find.byTooltip('Markdown / podgląd na żywo');
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      final source = tester.widget<TextField>(
        find.byKey(const Key('source-editor')),
      );
      for (final field in [title, source]) {
        expect(field.autocorrect, isFalse);
        expect(field.enableSuggestions, isFalse);
        expect(field.enableIMEPersonalizedLearning, isFalse);
      }
    },
  );

  for (final body in [
    '| Private cell | Other |\n| --- | --- |\n| Secret | Value |',
    '> [!NOTE] Private callout\n> Private content',
  ]) {
    testWidgets('hidden embedded fields disable keyboard learning: $body', (
      tester,
    ) async {
      final repo = await fixture(tester);
      final note = await seedHidden(tester, repo);
      await tester.runAsync(
        () => repo.save(note.copyWith(body: '$body\n\nOrdinary paragraph')),
      );
      await mount(tester, repo, desktop: true);
      await openHidden(tester);
      await tester.tap(
        body.startsWith('|')
            ? find.byKey(const ValueKey('table-cell-0-2-0'))
            : find.text('Private content', findRichText: true),
      );
      await tester.pumpAndSettle();
      final fields = tester
          .widgetList<EditableText>(
            find.descendant(
              of: find.byType(LiveMarkdownEditor),
              matching: find.byType(EditableText, skipOffstage: false),
              skipOffstage: false,
            ),
          )
          .toList();
      expect(
        fields.length,
        greaterThan(1),
        reason: 'exercise embedded editors',
      );
      for (final field in fields) {
        expect(field.autocorrect, isFalse);
        expect(field.enableSuggestions, isFalse);
        expect(field.enableIMEPersonalizedLearning, isFalse);
      }
      await tester.tap(find.byKey(const Key('hidden-lock-now')).last);
      await drainUntil(tester, () => !repo.hiddenUnlocked);
      for (final field in fields) {
        expect(
          field.controller.text,
          isEmpty,
          reason: 'retained embedded controllers must not retain plaintext',
        );
      }
    });
  }

  testWidgets('hidden search and find queries disable keyboard learning', (
    tester,
  ) async {
    final repo = await fixture(tester);
    await seedHidden(tester, repo);
    await mount(tester, repo, desktop: true);
    await openHidden(tester);
    await tester.tap(find.byTooltip('Szukaj w notatce'));
    await tester.pumpAndSettle();
    for (final field in [
      tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('note-search-field')),
          matching: find.byType(TextField),
        ),
      ),
      tester.widget<TextField>(find.byKey(const Key('find-field'))),
    ]) {
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse);
    }
  });

  testWidgets(
    'switching hidden documents wipes superseded live and source controllers',
    (tester) async {
      final repo = await fixture(tester);
      await seedHidden(tester, repo);
      await mount(tester, repo);
      await openHidden(tester);
      final previous = tester
          .widget<LiveMarkdownEditor>(find.byType(LiveMarkdownEditor))
          .controller;
      final toggle = find.byTooltip('Markdown / podgląd na żywo');
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      final raw = tester
          .widget<TextField>(find.byKey(const Key('source-editor')))
          .controller!;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await drainUntil(
        tester,
        () =>
            repo.storage.documents('hidden:${repo.vaults.single.id}').length ==
                2 &&
            tester
                    .widget<TextField>(find.byKey(const Key('note-title')))
                    .controller!
                    .text ==
                'Bez tytułu',
      );
      expectHistoryForgotten(previous);
      expect(
        raw.text,
        isEmpty,
        reason: 'do not leave a secret in superseded source controllers',
      );
    },
  );

  testWidgets(
    'disposing home wipes retained hidden editor fields and history',
    (tester) async {
      final repo = await fixture(tester);
      await seedHidden(tester, repo);
      await mount(tester, repo);
      await openHidden(tester);
      final body = tester
          .widget<LiveMarkdownEditor>(find.byType(LiveMarkdownEditor))
          .controller;
      final fields = tester
          .widgetList<EditableText>(
            find.descendant(
              of: find.byType(LiveMarkdownEditor),
              matching: find.byType(EditableText),
            ),
          )
          .toList();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expectHistoryForgotten(body);
      for (final field in fields) {
        expect(
          field.controller.text,
          isEmpty,
          reason: 'disposed private field',
        );
      }
      await drainUntil(tester, () => !repo.hiddenUnlocked);
    },
  );

  testWidgets('native close saves and locks the unified hidden folder', (
    tester,
  ) async {
    final repo = await fixture(tester);
    await seedHidden(tester, repo);
    await mount(tester, repo);
    await openHidden(tester);
    final title = tester
        .widget<TextField>(find.byKey(const Key('note-title')))
        .controller!;
    final body = tester
        .widget<LiveMarkdownEditor>(find.byType(LiveMarkdownEditor))
        .controller;
    body.text = 'Saved on unified close';
    var closed = false;
    final closing = NativeWindow.instance.beforeClose!().then(
      (_) => closed = true,
    );
    await drainUntil(tester, () => closed);
    await closing;
    expect(repo.hiddenUnlocked, isFalse);
    expectForgotten(tester, title, body);
    await tester.runAsync(() => repo.unlockHidden('test hidden password'));
    final stored = await tester.runAsync(
      () => repo.hiddenNotes(repo.vaults.single.id),
    );
    expect(stored!.single.body, 'Saved on unified close');
    expect(repo.notes[repo.vaults.single.id]!.values.map((n) => n.title), [
      'Visible secret',
    ]);
  });

  testWidgets('hidden wiki links never create ordinary notes', (tester) async {
    final repo = await fixture(tester);
    final hidden = await seedHidden(tester, repo);
    await tester.runAsync(
      () => repo.save(hidden.copyWith(body: '[[Private target]]')),
    );
    await mount(tester, repo);
    await openHidden(tester);
    await tapPrivateLink(tester);
    await drainUntil(
      tester,
      () =>
          repo.storage.documents('hidden:${hidden.vaultId}').length == 2 ||
          repo.notes[hidden.vaultId]!.length == 2,
    );
    await drainUntil(
      tester,
      () =>
          tester
              .widget<TextField>(find.byKey(const Key('note-title')))
              .controller!
              .text ==
          'Private target',
    );
    expect(repo.notes[hidden.vaultId]!.values.map((n) => n.title), [
      'Visible secret',
    ]);
    expect(repo.storage.documents(hidden.vaultId), hasLength(1));
    expect(repo.storage.documents('hidden:${hidden.vaultId}'), hasLength(2));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('note-title')))
          .controller!
          .text,
      'Private target',
    );
  });

  for (final hiddenTarget in [false, true]) {
    testWidgets(
      'hidden note-id links stay inside hidden storage target=$hiddenTarget',
      (tester) async {
        final repo = await fixture(tester);
        final hidden = await seedHidden(tester, repo);
        final ordinary = repo.notes[hidden.vaultId]!.values.single;
        late Note target;
        await tester.runAsync(() async {
          target = hiddenTarget
              ? await repo.createHiddenNote(hidden.vaultId)
              : ordinary;
          if (hiddenTarget) {
            target = target.copyWith(
              title: 'Linked hidden',
              body: 'Linked secret',
            );
            await repo.save(target);
          }
          await repo.save(
            hidden.copyWith(
              body: '[Private target](silique-note:${target.id})',
            ),
          );
        });
        await mount(tester, repo);
        await openHidden(tester);
        await tapPrivateLink(tester);
        await tester.pumpAndSettle();
        if (hiddenTarget) {
          await drainUntil(
            tester,
            () =>
                tester
                    .widget<TextField>(find.byKey(const Key('note-title')))
                    .controller!
                    .text ==
                'Linked hidden',
          );
        }
        final title = tester.widget<TextField>(
          find.byKey(const Key('note-title')),
        );
        expect(
          title.controller!.text,
          hiddenTarget ? 'Linked hidden' : 'Private title',
        );
        expect(repo.notes[hidden.vaultId]!.values.single, ordinary);
        expect(repo.storage.documents(hidden.vaultId), hasLength(1));
        if (!hiddenTarget) {
          expect(
            find.text('Ta notatka nie jest już dostępna.'),
            findsOneWidget,
          );
        }
      },
    );
  }

  testWidgets('Ukryte lives only in left drawer, not horizontal filters', (
    tester,
  ) async {
    final repo = await fixture(tester);
    await mount(tester, repo);
    expect(find.text('Ukryte'), findsNothing);
    await tester.tap(find.byTooltip('Foldery i vaulty'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('hidden-folder-nav')), findsOneWidget);
    expect(find.text('Ukryte'), findsOneWidget);
  });

  testWidgets(
    'hidden folder uses ordinary cards, clearing stale ordinary search and editor',
    (tester) async {
      final repo = await fixture(tester);
      final note = await seedHidden(tester, repo);
      await mount(tester, repo);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('note-search-field')),
          matching: find.byType(TextField),
        ),
        'unmatched ordinary query',
      );
      await enterHidden(tester);
      expect(find.byKey(Key('note-card-${note.id}')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(Key('note-card-${note.id}')),
          matching: find.text('Private body'),
        ),
        findsOneWidget,
      );
      expect(find.byType(HiddenNotesPage), findsNothing);
      expect(find.byKey(const Key('note-title')), findsNothing);
      expect(find.text('Visible secret'), findsNothing);
      final search = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('note-search-field')),
          matching: find.byType(TextField),
        ),
      );
      expect(search.controller!.text, isEmpty);
    },
  );

  testWidgets(
    'same plus and Ctrl N create hidden notes in the ordinary live editor without ordinary duplicates',
    (tester) async {
      final repo = await fixture(tester);
      await seedHidden(tester, repo);
      final id = repo.vaults.single.id;
      await mount(tester, repo);
      await enterHidden(tester);
      await tester.tap(find.byType(FloatingActionButton));
      await drainUntil(
        tester,
        () => find.byType(LiveMarkdownEditor).evaluate().isNotEmpty,
      );
      expect(
        find.ancestor(
          of: find.byType(LiveMarkdownEditor),
          matching: find.byType(HomeScreen),
        ),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('note-title')),
        'Created privately',
      );
      final editor = tester.widget<LiveMarkdownEditor>(
        find.byType(LiveMarkdownEditor),
      );
      editor.controller.text = 'Created private body';
      await tester.tap(find.byKey(const Key('editor-back')));
      await drainUntil(
        tester,
        () => find.text('Created privately').evaluate().isNotEmpty,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await drainUntil(
        tester,
        () => repo.storage.documents('hidden:$id').length == 3,
      );
      expect(find.byType(LiveMarkdownEditor), findsOneWidget);
      expect(repo.notes[id]!.values.map((n) => n.title), ['Visible secret']);
      expect(repo.storage.documents(id), hasLength(1));
    },
  );

  for (final desktop in [false, true]) {
    for (final source in [false, true]) {
      for (final action in [
        'manual',
        'expiry',
        'background',
        'vault lock',
        'departure',
      ]) {
        testWidgets(
          '$action wipes unified secret editor, source, find and search desktop=$desktop source=$source',
          (tester) async {
            final repo = await fixture(tester);
            await seedHidden(tester, repo);
            if (action == 'departure') {
              await tester.runAsync(() => repo.setHiddenAutoLock(null));
            }
            await mount(tester, repo, desktop: desktop);
            await enterHidden(tester);
            final searchField = find.descendant(
              of: find.byKey(const Key('note-search-field')),
              matching: find.byType(TextField),
            );
            final search = tester.widget<TextField>(searchField).controller!;
            await tester.enterText(searchField, 'Private');
            await tester.tap(
              find.byKey(
                Key(
                  'note-card-${(await tester.runAsync(() => repo.hiddenNotes(repo.vaults.single.id)))!.single.id}',
                ),
              ),
            );
            await tester.pumpAndSettle();
            final title = tester
                .widget<TextField>(find.byKey(const Key('note-title')))
                .controller!;
            final body = tester
                .widget<LiveMarkdownEditor>(find.byType(LiveMarkdownEditor))
                .controller;
            TextEditingController? raw;
            if (source) {
              final toggle = find.byTooltip('Markdown / podgląd na żywo');
              await tester.ensureVisible(toggle);
              await tester.tap(toggle);
              await tester.pumpAndSettle();
              raw = tester
                  .widget<TextField>(find.byKey(const Key('source-editor')))
                  .controller!;
              expect(raw.text, 'Private **body**');
            }
            final findButton = find.byTooltip('Szukaj w notatce');
            await tester.ensureVisible(findButton);
            await tester.tap(findButton);
            await tester.pumpAndSettle();
            await tester.enterText(
              find.byKey(const Key('find-field')),
              'Private',
            );
            final findController = tester
                .widget<TextField>(find.byKey(const Key('find-field')))
                .controller!;
            if (action == 'manual') {
              await tester.tap(find.byKey(const Key('hidden-lock-now')).last);
            } else if (action == 'expiry') {
              await tester.runAsync(
                () => repo.setHiddenAutoLock(const Duration(seconds: 1)),
              );
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 1150)),
              );
              await tester.pump(const Duration(milliseconds: 250));
            } else if (action == 'background') {
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.inactive,
              );
              // Wipe synchronously before any awaited persistence.
              expect(title.text, isEmpty);
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.hidden,
              );
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.paused,
              );
            } else if (action == 'vault lock') {
              repo.lock(repo.vaults.single.id);
              await tester.pump(const Duration(milliseconds: 250));
            } else {
              if (desktop) {
                await tester.tap(find.text('Wszystkie notatki'));
              } else {
                await tester.tap(find.byKey(const Key('editor-back')));
                await tester.pumpAndSettle();
                await tester.tap(find.text('Notatki').last);
              }
            }
            await drainUntil(
              tester,
              () => find.byKey(const Key('note-title')).evaluate().isEmpty,
            );
            expectForgotten(tester, title, body);
            expect(
              raw?.text ?? '',
              isEmpty,
              reason: 'retained source controller',
            );
            expect(
              findController.text,
              isEmpty,
              reason: 'retained find controller',
            );
            expect(search.text, isEmpty, reason: 'retained search controller');
            expect(find.byKey(const Key('source-editor')), findsNothing);
            if (action != 'vault lock') expect(repo.hiddenUnlocked, isFalse);
            if (action == 'background') {
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.hidden,
              );
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.inactive,
              );
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.resumed,
              );
            }
          },
        );
      }
    }
  }

  testWidgets(
    'failed hidden save cannot retain plaintext on background or create ordinary fallback',
    (tester) async {
      final repo = await fixture(tester);
      await seedHidden(tester, repo);
      await mount(tester, repo);
      await openHidden(tester);
      final title = tester
          .widget<TextField>(find.byKey(const Key('note-title')))
          .controller!;
      final body = tester
          .widget<LiveMarkdownEditor>(find.byType(LiveMarkdownEditor))
          .controller;
      final storage = repo.storage as NativeStorage;
      storage.db.execute(
        "CREATE TRIGGER fail_hidden_save BEFORE INSERT ON documents WHEN NEW.vault_id LIKE 'hidden:%' BEGIN SELECT RAISE(ABORT, 'simulated hidden save failure'); END",
      );
      try {
        await tester.enterText(
          find.byKey(const Key('note-title')),
          'Private failed save',
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        expect(title.text, isEmpty);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await drainUntil(tester, () => !repo.hiddenUnlocked);
        expectForgotten(tester, title, body);
        expect(repo.notes[repo.vaults.single.id]!.values.map((n) => n.title), [
          'Visible secret',
        ]);
        expect(find.textContaining('Nie udało się zapisać'), findsWidgets);
      } finally {
        storage.db.execute('DROP TRIGGER fail_hidden_save');
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
    },
  );
}
