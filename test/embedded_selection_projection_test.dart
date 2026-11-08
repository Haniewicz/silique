import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';

void main() {
  for (final scenario in [
    (
      name: 'table cell',
      text: '| Heading |\n| --- |\n| alpha beta |',
      previewKey: 'table-cell-0-2-0',
      editorKey: 'table-editor-0-2-0',
    ),
    (
      name: 'callout title',
      text: '> [!note] alpha beta\n> Body words',
      previewKey: null,
      editorKey: 'callout-title-editor-0',
    ),
    (
      name: 'callout body',
      text: '> [!note] Heading\n> alpha beta',
      previewKey: null,
      editorKey: 'callout-body-editor-0',
    ),
  ]) {
    testWidgets(
      '${scenario.name} keeps its active range selection after rebuild',
      (tester) async {
        final document = LiveMarkdownController(
          text: scenario.text,
          selection: TextSelection.collapsed(offset: scenario.text.length),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: LiveMarkdownEditor(controller: document)),
          ),
        );
        await tester.pumpAndSettle();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          document.dispose();
        });

        // Enter the actual embedded editor through its rendered preview.
        await tester.tap(
          scenario.previewKey == null
              ? find.text('alpha beta', findRichText: true)
              : find.byKey(ValueKey(scenario.previewKey!)),
        );
        await tester.pumpAndSettle();
        final field = find.byKey(ValueKey(scenario.editorKey));
        final editable = find.descendant(
          of: field,
          matching: find.byType(EditableText),
        );
        final state = tester.state<EditableTextState>(editable);
        final controller = state.widget.controller;
        final focus = state.widget.focusNode;
        expect(focus.hasFocus, isTrue);
        expect(controller.text, 'alpha beta');
        final start = scenario.text.indexOf('alpha beta');

        // Establish a caret so the layout snapshot is deliberately collapsed.
        state.userUpdateTextEditingValue(
          controller.value.copyWith(
            selection: const TextSelection.collapsed(offset: 3),
          ),
          SelectionChangedCause.keyboard,
        );
        await tester.pumpAndSettle();
        expect(controller.selection, const TextSelection.collapsed(offset: 3));

        for (final selection in const [
          TextSelection(baseOffset: 0, extentOffset: 5),
          TextSelection(baseOffset: 5, extentOffset: 0),
        ]) {
          state.userUpdateTextEditingValue(
            controller.value.copyWith(selection: selection),
            SelectionChangedCause.keyboard,
          );
          final global = TextSelection(
            baseOffset: start + selection.baseOffset,
            extentOffset: start + selection.extentOffset,
          );
          expect(controller.selection, selection);
          expect(document.selection, global);
          await tester.pumpAndSettle();
          expect(
            controller.selection,
            selection,
            reason: 'A frozen layout caret must not overwrite the live range',
          );
          expect(document.selection, global);
          expect(tester.state<EditableTextState>(editable), same(state));
          expect(state.widget.controller, same(controller));
          expect(state.widget.focusNode, same(focus));
          expect(focus.hasFocus, isTrue);
          expect(document.text, scenario.text);
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  testWidgets('initial range keeps rendered syntax and the live selection', (
    tester,
  ) async {
    const text = '- [ ] Task words\n\nTail';
    const selection = TextSelection(baseOffset: 0, extentOffset: text.length);
    final document = LiveMarkdownController(text: text, selection: selection);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LiveMarkdownEditor(controller: document)),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    expect(document.selection, selection);
    expect(state.widget.controller.selection, selection);
    expect(find.byKey(const ValueKey('task-0')), findsOneWidget);
    expect(state.renderEditable.plainText.length, text.length);
    expect(document.text, text);
    await tester.pumpWidget(const SizedBox());
    document.dispose();
  });

  testWidgets('text edits invalidate the previous syntax reveal snapshot', (
    tester,
  ) async {
    const text = '- [ ] Task words\n\nTail';
    final document = LiveMarkdownController(
      text: text,
      selection: const TextSelection.collapsed(offset: text.length),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LiveMarkdownEditor(controller: document)),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    final editing = state.widget.controller;
    // A range alone retains the Tail caret's rendered task projection.
    const range = TextSelection(baseOffset: 0, extentOffset: 6);
    state.userUpdateTextEditingValue(
      editing.value.copyWith(selection: range),
      SelectionChangedCause.keyboard,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('task-0')), findsOneWidget);
    // An actual text edit must replace that snapshot even with a live range.
    const editedText = '- [x] Task words\n\nTail';
    state.userUpdateTextEditingValue(
      const TextEditingValue(text: editedText, selection: range),
      SelectionChangedCause.keyboard,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('task-0')), findsNothing);
    expect(document.text, editedText);
    expect(document.selection, range);
    expect(editing.selection, range);
    expect(state.renderEditable.plainText.length, editedText.length);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    document.dispose();
  });
}
