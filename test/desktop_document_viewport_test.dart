import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/notebook.dart';

import 'hidden_folder_ui_test.dart' show openHidden, seedHidden;
import 'hidden_notes_home_test.dart' show drainUntil, fixture, mount;

Finder documentViewport() => find.byKey(const Key('mobile-note-scroll'));

ScrollController documentScroll(WidgetTester tester) => tester
    .widget<SingleChildScrollView>(documentViewport())
    .controller!;

Finder bodyField(bool source) => source
    ? find.byKey(const Key('source-editor'))
    : find.byKey(const ValueKey('livemd-document-field'));

EditableTextState bodyState(WidgetTester tester, bool source) => tester
    .state<EditableTextState>(
      find
          .descendant(of: bodyField(source), matching: find.byType(EditableText))
          .first,
    );

/// Replaces the fixture note body with a document long enough to scroll.
Future<Note> seedLongBody(WidgetTester tester, Notebook repo) async {
  final note = repo.notes[repo.vaults.single.id]!.values.single;
  await tester.runAsync(
    () => repo.save(
      note.copyWith(
        body: List.generate(
          120,
          (i) => 'Wiersz $i ze słowami do przewijania dokumentu',
        ).join('\n\n'),
      ),
    ),
  );
  return repo.notes[repo.vaults.single.id]!.values.single;
}

Future<void> toggleSource(WidgetTester tester) async {
  final toggle = find.byTooltip('Markdown / podgląd na żywo');
  await tester.ensureVisible(toggle);
  await tester.tap(toggle);
  await tester.pumpAndSettle();
}

void main() {
  for (final source in [false, true]) {
    testWidgets(
      'desktop heading and tags scroll inside the shared document viewport source=$source',
      (tester) async {
        final repo = await fixture(tester);
        final note = await seedLongBody(tester, repo);
        await mount(tester, repo, desktop: true);
        await tester.tap(find.byKey(Key('note-card-${note.id}')));
        await tester.pumpAndSettle();
        if (source) {
          await toggleSource(tester);
        }
        final viewport = documentViewport();
        expect(viewport, findsOneWidget);
        // The heading (dates, title field, tag chips) belongs to the scrolled
        // document, exactly like on the phone layout.
        expect(
          find.descendant(
            of: viewport,
            matching: find.byKey(const Key('note-title')),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: viewport, matching: bodyField(source)),
          findsOneWidget,
        );
        // The tab bar, the toolbar and the status bar stay pinned around it.
        final focusMode = tester.getRect(find.byTooltip('Tryb skupienia'));
        final words = tester.getRect(find.textContaining('słów').last);
        final title = find.byKey(const Key('note-title'));
        final before = tester.getTopLeft(title).dy;
        expect(documentScroll(tester).offset, 0);
        await tester.dragFrom(tester.getCenter(viewport), const Offset(0, -260));
        await tester.pumpAndSettle();
        expect(
          documentScroll(tester).offset,
          greaterThan(0),
          reason: 'the document viewport owns the note offset',
        );
        expect(
          tester.getTopLeft(title).dy,
          lessThan(before - 100),
          reason: 'the heading scrolls down with the note content',
        );
        expect(tester.getRect(find.byTooltip('Tryb skupienia')), focusMode);
        expect(tester.getRect(find.textContaining('słów').last), words);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('desktop source typing keeps the scrolled document offset', (
    tester,
  ) async {
    final repo = await fixture(tester);
    final note = await seedLongBody(tester, repo);
    await mount(tester, repo, desktop: true);
    await tester.tap(find.byKey(Key('note-card-${note.id}')));
    await tester.pumpAndSettle();
    await toggleSource(tester);
    final scroll = documentScroll(tester);
    scroll.jumpTo(320);
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getCenter(documentViewport()));
    await tester.pumpAndSettle();
    final state = bodyState(tester, true);
    expect(state.widget.focusNode.hasFocus, isTrue);
    final anchor = scroll.offset;
    expect(anchor, greaterThan(0));
    final controller = state.widget.controller;
    final insertion = controller.selection.extentOffset;
    final original = controller.text;
    // Send platform text-input messages so the offset check exercises the
    // real editing path, not a controller assignment.
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: original.replaceRange(insertion, insertion, 'ABC'),
        selection: TextSelection.collapsed(offset: insertion + 3),
      ),
    );
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      controller.text,
      original.replaceRange(insertion, insertion, 'ABC'),
    );
    expect(
      documentScroll(tester).offset,
      closeTo(anchor, 1),
      reason: 'typing must not reset the document to its head',
    );
    // Flush the debounced autosave so no timer outlives the widget tree.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final source in [false, true]) {
    for (final ime in [false, true]) {
      testWidgets(
        'desktop Enter from the title focuses the body at offset 0 source=$source ime=$ime',
        (tester) async {
          final repo = await fixture(tester);
          final note = repo.notes[repo.vaults.single.id]!.values.single;
          await mount(tester, repo, desktop: true);
          await tester.tap(find.byKey(Key('note-card-${note.id}')));
          await tester.pumpAndSettle();
          if (source) {
            await toggleSource(tester);
          }
          final title = find.byKey(const Key('note-title'));
          await tester.tap(title);
          await tester.pumpAndSettle();
          final titleField = tester.widget<TextField>(title);
          expect(titleField.focusNode!.hasFocus, isTrue);
          if (ime) {
            await tester.testTextInput.receiveAction(TextInputAction.done);
          } else {
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          }
          await tester.pumpAndSettle();
          final state = bodyState(tester, source);
          expect(
            state.widget.focusNode.hasFocus,
            isTrue,
            reason: 'Enter in the title moves focus into the note body',
          );
          expect(
            state.widget.controller.selection,
            TextSelection.collapsed(offset: 0),
            reason: 'the caret starts at the beginning of the content',
          );
          expect(titleField.focusNode!.hasFocus, isFalse);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('desktop Enter from a frozen read-only title keeps focus', (
    tester,
  ) async {
    final repo = await fixture(tester);
    final hidden = await seedHidden(tester, repo);
    await tester.runAsync(() => repo.setHiddenAutoLock(null));
    await mount(tester, repo, desktop: true);
    await openHidden(tester);
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    var blocked = false;
    final barrier = repo.serialized(() async {
      blocked = true;
      await gate.future;
    });
    await drainUntil(tester, () => blocked);
    await tester.ensureVisible(find.byKey(const Key('note-options')));
    await tester.tap(find.byKey(const Key('note-options')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Przenieś do folderu'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('folder-target-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    try {
      final title = find.byKey(const Key('note-title'));
      final titleField = tester.widget<TextField>(title);
      expect(
        titleField.readOnly,
        isTrue,
        reason: 'the reveal freezes editing before draining writes',
      );
      titleField.focusNode!.requestFocus();
      await tester.pumpAndSettle();
      expect(titleField.focusNode!.hasFocus, isTrue);
      final body = bodyState(tester, false);
      expect(body.widget.focusNode.hasFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        body.widget.focusNode.hasFocus,
        isFalse,
        reason: 'a read-only title must not hand focus to the body',
      );
      expect(titleField.focusNode!.hasFocus, isTrue);
    } finally {
      gate.complete();
    }
    await barrier;
    await drainUntil(
      tester,
      () =>
          !repo.hiddenUnlocked &&
          repo.notes[hidden.vaultId]!.containsKey(hidden.id),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
