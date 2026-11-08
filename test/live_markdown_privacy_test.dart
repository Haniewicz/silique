import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';

/// Mounts the editor the way `_noteBody` does: an ordinary note may use the
/// platform keyboard, a hidden one must never reach autocorrect, suggestions,
/// or IME learning.
Future<void> _mount(
  WidgetTester tester,
  LiveMarkdownController document, {
  required bool hidden,
}) async {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    document.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: LiveMarkdownEditor(
          controller: document,
          autocorrect: !hidden,
          enableSuggestions: !hidden,
          enableIMEPersonalizedLearning: !hidden,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

EditableText _field(WidgetTester tester, Finder owner) =>
    tester.widget<EditableText>(
      find.descendant(of: owner, matching: find.byType(EditableText)).first,
    );

/// Asserts the keyboard contract on the field with [key]: both the [TextField]
/// and the [EditableText] it builds. An activated embedded field is inflated
/// inside the document field's own EditableText, so the lookup stays scoped to
/// the field's key instead of matching every editable in the editor.
void _expectKeyboardPrivacy(
  WidgetTester tester,
  Key key, {
  required bool hidden,
}) {
  final owner = find.byKey(key);
  expect(owner, findsOneWidget, reason: 'the field must be mounted');
  final field = tester.widget<TextField>(owner);
  expect(field.autocorrect, !hidden);
  expect(field.enableSuggestions, !hidden);
  expect(field.enableIMEPersonalizedLearning, !hidden);
  final editable = _field(tester, owner);
  expect(editable.autocorrect, !hidden);
  expect(editable.enableSuggestions, !hidden);
  expect(editable.enableIMEPersonalizedLearning, !hidden);
}

void main() {
  for (final empty in [false, true]) {
    test('wipe erases history even when current text is empty=$empty', () {
      final controller = LiveMarkdownController(text: 'Private first');
      controller.text = 'Private second';
      controller.text = empty ? '' : 'Private third';
      if (!empty) controller.undo();
      controller.setAnnotations([
        const LiveMarkdownAnnotation(
          start: 0,
          end: 2,
          backgroundColor: Colors.red,
        ),
      ]);
      var notifications = 0;
      controller.addListener(() => notifications++);
      controller.wipe();
      expect(notifications, 1);
      expect(controller.text, isEmpty);
      expect(controller.annotations, isEmpty);
      expect(controller.selection, const TextSelection.collapsed(offset: 0));
      expect(controller.composing, TextRange.empty);
      expect(controller.canUndo, isFalse);
      expect(controller.canRedo, isFalse);
      controller.undo();
      controller.redo();
      expect(controller.text, isEmpty);
      // Wiping repeatedly is safe and never creates an undo snapshot.
      controller.wipe();
      expect(controller.canUndo, isFalse);
      controller.dispose();
    });
  }

  test(
    'disposing a document erases current text and both history directions',
    () {
      final controller = LiveMarkdownController(text: 'Private first');
      controller.text = 'Private second';
      controller.text = 'Private third';
      controller.undo();
      expect(controller.canUndo, isTrue);
      expect(controller.canRedo, isTrue);
      controller.dispose();
      expect(controller.text, isEmpty);
      expect(
        controller.value,
        const TextEditingValue(selection: TextSelection.collapsed(offset: 0)),
      );
      expect(controller.annotations, isEmpty);
      expect(controller.canUndo, isFalse);
      expect(controller.canRedo, isFalse);
      controller.undo();
      controller.redo();
      expect(controller.text, isEmpty);
    },
  );

  for (final hidden in [false, true]) {
    testWidgets('the document field follows keyboard privacy hidden=$hidden', (
      tester,
    ) async {
      final document = LiveMarkdownController(
        text: 'Ordinary words',
        selection: const TextSelection.collapsed(offset: 14),
      );
      await _mount(tester, document, hidden: hidden);
      _expectKeyboardPrivacy(
        tester,
        const ValueKey('livemd-document-field'),
        hidden: hidden,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final scenario in [
    (
      name: 'table cell',
      text: '| Heading |\n| --- |\n| secret words |',
      previewKey: 'table-cell-0-2-0',
      editorKey: 'table-editor-0-2-0',
    ),
    (
      name: 'callout title',
      text: '> [!note] secret words\n> Body text',
      previewKey: null,
      editorKey: 'callout-title-editor-0',
    ),
    (
      name: 'callout body',
      text: '> [!note] Heading\n> secret words',
      previewKey: null,
      editorKey: 'callout-body-editor-0',
    ),
  ]) {
    for (final hidden in [false, true]) {
      testWidgets(
        'an embedded ${scenario.name} follows keyboard privacy hidden=$hidden',
        (tester) async {
          final document = LiveMarkdownController(
            text: scenario.text,
            selection: TextSelection.collapsed(offset: scenario.text.length),
          );
          await _mount(tester, document, hidden: hidden);
          // Enter the embedded editor through its rendered preview.
          await tester.tap(
            scenario.previewKey == null
                ? find.text('secret words', findRichText: true)
                : find.byKey(ValueKey(scenario.previewKey!)),
          );
          await tester.pumpAndSettle();
          // The preview must have opened the embedded field.
          _expectKeyboardPrivacy(
            tester,
            ValueKey(scenario.editorKey),
            hidden: hidden,
          );
          // The document field keeps the same contract while a cell is open.
          _expectKeyboardPrivacy(
            tester,
            const ValueKey('livemd-document-field'),
            hidden: hidden,
          );
          expect(document.text, scenario.text);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
