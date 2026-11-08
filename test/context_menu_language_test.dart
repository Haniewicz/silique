import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/main.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/l10n/app_language.dart';
import 'package:silique/ui/menus.dart';

import 'home_language_test.dart' show fixture;

const enEditMenuLabels = [
  'Undo',
  'Redo',
  'Cut',
  'Copy',
  'Paste',
  'Delete',
  'Select all',
];
const plEditMenuLabels = [
  'Cofnij',
  'Ponów',
  'Wytnij',
  'Kopiuj',
  'Wklej',
  'Usuń',
  'Zaznacz wszystko',
];

Future<void> switchLanguage(WidgetTester tester, String code) async {
  await tester.runAsync(() => appLanguage.setLanguage(code));
  await tester.pumpAndSettle();
}

Future<Notebook> mountHome(WidgetTester tester) async {
  final previous = appLanguage.languageCode;
  addTearDown(() => appLanguage.setLanguage(previous));
  await switchLanguage(tester, 'en');
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
  return repo;
}

Future<void> openNoteMenu(WidgetTester tester, Notebook repo) async {
  final note = repo.notes[repo.vaults.single.id]!.values.first;
  await tester.tap(
    find.byKey(Key('note-card-${note.id}')),
    buttons: kSecondaryMouseButton,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'open note menu relocalizes EN to PL and back on the same route',
    (tester) async {
      final repo = await mountHome(tester);
      final before = repo.notes[repo.vaults.single.id]!.values.single.toJson();
      final controller = tester
          .widget<TextField>(find.byKey(const Key('note-title')))
          .controller;
      await openNoteMenu(tester, repo);
      expect(find.text('Rename'), findsOneWidget);
      final menu = find.byType(SiliquePopupItem<String>).first;
      final route = ModalRoute.of(tester.element(menu));
      await switchLanguage(tester, 'pl');
      expect(find.text('Zmień nazwę'), findsOneWidget);
      expect(find.text('Rename'), findsNothing);
      expect(find.text('Otwórz w karcie'), findsOneWidget);
      expect(ModalRoute.of(tester.element(menu)), same(route));
      await switchLanguage(tester, 'en');
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Zmień nazwę'), findsNothing);
      expect(ModalRoute.of(tester.element(menu)), same(route));
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('note-title')))
            .controller,
        same(controller),
      );
      expect(repo.notes[repo.vaults.single.id]!.values.single.toJson(), before);
      await tester.tap(find.text('Open in a tab'));
      await tester.pumpAndSettle();
      expect(find.byType(SiliquePopupItem<String>), findsNothing);
      expect(controller!.text, 'Moja istniejąca notatka');
    },
  );

  testWidgets(
    'android exposes the full seven-item edit menu on every text field',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final repo = await mountHome(tester);
        final note = repo.notes[repo.vaults.single.id]!.values.first;
        if (find.byKey(const Key('note-title')).evaluate().isEmpty) {
          await tester.tap(find.byKey(Key('note-card-${note.id}')));
          await tester.pumpAndSettle();
        }

        EditableTextState editableOf(Finder field) =>
            tester.state<EditableTextState>(
              find
                  .descendant(of: field, matching: find.byType(EditableText))
                  .first,
            );

        void expectFullMenu(EditableTextState state, List<String> expected) {
          final menu =
              state.widget.contextMenuBuilder!(state.context, state)
                  as SiliqueSelectionToolbar;
          expect(menu.buttonItems, hasLength(7));
          expect(
            menu.buttonItems
                .map(
                  (item) =>
                      item.label ??
                      AdaptiveTextSelectionToolbar.getButtonLabel(
                        state.context,
                        item,
                      ),
                )
                .toList(),
            expected,
          );
        }

        final title = editableOf(find.byKey(const Key('note-title')));
        final search = editableOf(find.byKey(const Key('note-search-field')));
        final live = editableOf(
          find.byKey(const ValueKey('livemd-document-field')),
        );

        // State-aware: without a selection Cut/Copy/Delete stay disabled.
        final titleController = title.widget.controller;
        titleController.selection = const TextSelection.collapsed(offset: 0);
        await tester.pump();
        var menu =
            siliqueTextContextMenu(title.context, title)
                as SiliqueSelectionToolbar;
        for (final index in [2, 3, 5]) {
          expect(
            menu.buttonItems[index].onPressed,
            isNull,
            reason: 'item $index without selection',
          );
        }
        titleController.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 3,
        );
        await tester.pump();
        menu =
            siliqueTextContextMenu(title.context, title)
                as SiliqueSelectionToolbar;
        for (final index in [2, 3, 5]) {
          expect(
            menu.buttonItems[index].onPressed,
            isNotNull,
            reason: 'item $index with selection',
          );
        }

        expectFullMenu(title, enEditMenuLabels);
        expectFullMenu(search, enEditMenuLabels);
        expectFullMenu(live, enEditMenuLabels);

        final sourceToggle = find.byTooltip('Markdown / live preview');
        await tester.ensureVisible(sourceToggle);
        await tester.tap(sourceToggle);
        await tester.pumpAndSettle();
        expectFullMenu(
          editableOf(find.byKey(const Key('source-editor'))),
          enEditMenuLabels,
        );

        await switchLanguage(tester, 'pl');
        expectFullMenu(
          editableOf(find.byKey(const Key('note-title'))),
          plEditMenuLabels,
        );
        expectFullMenu(
          editableOf(find.byKey(const Key('note-search-field'))),
          plEditMenuLabels,
        );
        expectFullMenu(
          editableOf(find.byKey(const Key('source-editor'))),
          plEditMenuLabels,
        );

        final liveToggle = find.byTooltip('Markdown / podgląd na żywo');
        await tester.ensureVisible(liveToggle);
        await tester.tap(liveToggle);
        await tester.pumpAndSettle();
        expectFullMenu(
          editableOf(find.byKey(const ValueKey('livemd-document-field'))),
          plEditMenuLabels,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'android readOnly field keeps every modifying command disabled',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final controller = TextEditingController(text: 'alpha beta');
        addTearDown(controller.dispose);
        final previous = appLanguage.languageCode;
        addTearDown(() => appLanguage.setLanguage(previous));
        await tester.runAsync(() => appLanguage.setLanguage('pl'));
        await tester.pumpWidget(
          SiliqueMaterialApp(
            home: Scaffold(
              body: TextField(
                controller: controller,
                readOnly: true,
                contextMenuBuilder: siliqueTextContextMenu,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final state = tester.state<EditableTextState>(
          find.byType(EditableText),
        );
        controller.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 5,
        );
        await tester.pump();
        final menu =
            siliqueTextContextMenu(state.context, state)
                as SiliqueSelectionToolbar;
        expect(menu.buttonItems, hasLength(7));
        // Undo, Redo, Cut, Paste and Delete must never modify a readOnly
        // field; Copy and Select all remain available.
        for (final index in [0, 1, 2, 4, 5]) {
          expect(
            menu.buttonItems[index].onPressed,
            isNull,
            reason: 'modifying item $index on readOnly field',
          );
        }
        expect(menu.buttonItems[3].onPressed, isNotNull);
        expect(menu.buttonItems[6].onPressed, isNotNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
