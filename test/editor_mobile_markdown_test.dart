import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';
import 'package:silique/ui/theme.dart';

void main() {
  Future<void> mount(
    WidgetTester tester,
    LiveMarkdownController controller,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: siliqueTheme(),
        home: Scaffold(body: LiveMarkdownEditor(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }

  testWidgets(
    'existing bare tasks accept labels, composition commits add a separator, and undo stays atomic',
    (tester) async {
      final controller = LiveMarkdownController(
        text: '- [ ]',
        selection: const TextSelection.collapsed(offset: 5),
      );
      await mount(tester, controller);
      final field = find.byKey(const ValueKey('livemd-document-field'));
      await tester.showKeyboard(field);
      expect(
        controller.text,
        '- [ ]',
        reason: 'Opening a note must not rewrite it',
      );
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '- [ ]tekst',
          selection: TextSelection.collapsed(offset: 10),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.text, '- [ ] tekst');
      expect(find.byKey(const ValueKey('task-0')), findsOneWidget);
      controller.setText(
        '',
        selection: const TextSelection.collapsed(offset: 0),
      );
      await tester.pumpAndSettle();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '- [ ]',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange(start: 2, end: 5),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.text, '- [ ]');
      tester.testTextInput.updateEditingValue(
        controller.value.copyWith(composing: TextRange.empty),
      );
      await tester.pumpAndSettle();
      expect(controller.text, '- [ ] ');
      controller.setText(
        '',
        selection: const TextSelection.collapsed(offset: 0),
      );
      await tester.pumpAndSettle();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '- [x]',
          selection: TextSelection.collapsed(offset: 5),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.text, '- [x] ');
      controller.undo();
      await tester.pumpAndSettle();
      expect(controller.text, '');
      controller.redo();
      await tester.pumpAndSettle();
      expect(controller.text, '- [x] ');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'task-looking text inside fenced code or after ordinary text stays literal',
    (tester) async {
      final controller = LiveMarkdownController();
      await mount(tester, controller);
      final field = find.byKey(const ValueKey('livemd-document-field'));
      for (final prefix in ['```\n- [ ', '~~~\n- [ ', 'tekst - [ ']) {
        controller.setText(
          prefix,
          selection: TextSelection.collapsed(offset: prefix.length),
        );
        await tester.pumpAndSettle();
        await tester.showKeyboard(field);
        final text = '$prefix]';
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.text, text);
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: '$text\n',
            selection: TextSelection.collapsed(offset: text.length + 1),
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.text, '$text\n');
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'typing a task inserts a separator and both Enter paths preserve repeated empty tasks',
    (tester) async {
      final controller = LiveMarkdownController();
      await mount(tester, controller);
      final field = find.byKey(const ValueKey('livemd-document-field'));
      await tester.showKeyboard(field);
      Future<void> type(String text) async {
        for (final rune in text.runes) {
          final value = controller.value;
          final inserted = String.fromCharCode(rune);
          tester.testTextInput.updateEditingValue(
            value.copyWith(
              text: value.text.replaceRange(
                value.selection.start,
                value.selection.end,
                inserted,
              ),
              selection: TextSelection.collapsed(
                offset: value.selection.start + inserted.length,
              ),
              composing: TextRange.empty,
            ),
          );
          await tester.pumpAndSettle();
        }
      }

      await type('- [ ]');
      expect(controller.text, '- [ ] ');
      expect(controller.selection.extentOffset, 6);
      await type('test 😀');
      expect(controller.text, '- [ ] test 😀');
      expect(find.byKey(const ValueKey('task-0')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(controller.text, '- [ ] test 😀\n- [ ] ');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(controller.text, '- [ ] test 😀\n- [ ] \n- [ ] ');
      await type('\n');
      expect(controller.text, '- [ ] test 😀\n- [ ] \n- [ ] \n- [ ] ');
      await type('kolejne');
      expect(controller.text, endsWith('- [ ] kolejne'));
      expect(
        find.byIcon(Icons.check_box_outline_blank_rounded),
        findsNWidgets(4),
      );
      await type('\n');
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
      expect(controller.text, endsWith('kolejne\n'));
      expect(
        find.byIcon(Icons.check_box_outline_blank_rounded),
        findsNWidgets(4),
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.linux,
    }),
  );

  testWidgets(
    'Enter on existing empty and nested tasks retains them and adds an unchecked task',
    (tester) async {
      final controller = LiveMarkdownController();
      await mount(tester, controller);
      for (final marker in ['- [ ]', '- [x]', '+ [X]', '  * [ ]', '\t- [ ]']) {
        controller.setText(
          marker,
          selection: TextSelection.collapsed(offset: marker.length),
        );
        await tester.pumpAndSettle();
        await tester.showKeyboard(
          find.byKey(const ValueKey('livemd-document-field')),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        final next = marker.replaceFirst(RegExp(r'\[[ xX]\]'), '[ ]');
        expect(controller.text, '$marker\n$next ');
        expect(controller.selection.extentOffset, controller.text.length);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'typing a task without trailing space hides its closing bracket and preserves caret geometry',
    (tester) async {
      final controller = LiveMarkdownController();
      await mount(tester, controller);
      final field = find.byKey(const ValueKey('livemd-document-field'));
      await tester.showKeyboard(field);
      for (final text in [
        '-',
        '- ',
        '- [',
        '- [ ',
        '- [ ]',
        '- [ ] ',
        '- [x]',
        '- [X]',
      ]) {
        if (text == '- [x]' || text == '- [X]') {
          // Replace the selection as a real paste, rather than fabricating a
          // deletion and a marker-state change with an unrelated old caret.
          controller.setSelection(
            TextSelection(baseOffset: 0, extentOffset: controller.text.length),
          );
        }
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          ),
        );
        await tester.pumpAndSettle();
        final completed = text.endsWith(']') ? '$text ' : text;
        expect(controller.text, completed);
        if (!text.contains(']')) continue;
        expect(find.byKey(const ValueKey('task-0')), findsOneWidget);
        final editable = tester.widget<EditableText>(find.byType(EditableText));
        final span = editable.controller.buildTextSpan(
          context: tester.element(field),
          withComposing: false,
        );
        final visible = StringBuffer();
        void visit(InlineSpan span, TextStyle inherited) {
          final style = inherited.merge(span.style);
          if (span is TextSpan) {
            if ((style.color?.a ?? 1) > 0) visible.write(span.text ?? '');
            for (final child in span.children ?? <InlineSpan>[]) {
              visit(child, style);
            }
          }
        }

        visit(span, editable.style);
        expect(
          visible.toString(),
          isNot(contains(']')),
          reason:
              'The rendered checkbox must hide the entire marker in "$text"',
        );
        final render = tester
            .state<EditableTextState>(find.byType(EditableText))
            .renderEditable;
        final caret = render.getLocalRectForCaret(
          TextPosition(offset: completed.length),
        );
        expect(caret.height, greaterThan(0));
        expect(caret.top.isFinite, true);
        expect(tester.takeException(), isNull);
      }
      controller.setSelection(const TextSelection.collapsed(offset: 3));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('task-0')),
        findsNothing,
        reason: 'Moving into the marker must still allow editing its source',
      );
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.android,
      TargetPlatform.linux,
    }),
  );

  testWidgets(
    'empty list and task prefixes render after space and software Enter continues a rendered task',
    (tester) async {
      final controller = LiveMarkdownController(
        text: '- ',
        selection: const TextSelection.collapsed(offset: 2),
      );
      await mount(tester, controller);
      final field = find.byKey(const ValueKey('livemd-document-field'));
      final editable = tester.widget<EditableText>(find.byType(EditableText));
      final spans = editable.controller.buildTextSpan(
        context: tester.element(field),
        withComposing: false,
      );
      expect(spans.toPlainText(), contains('• '));
      controller.setText(
        '- [ ] ',
        selection: const TextSelection.collapsed(offset: 6),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('task-0')), findsOneWidget);
      controller.setSelection(const TextSelection.collapsed(offset: 3));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('task-0')), findsNothing);
      controller.setText(
        '- [ ] one',
        selection: const TextSelection.collapsed(offset: 9),
      );
      await tester.pumpAndSettle();
      await tester.showKeyboard(field);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '- [ ] one\n',
          selection: TextSelection.collapsed(offset: 10),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.text, '- [ ] one\n- [ ] ');
      expect(find.byKey(const ValueKey('task-10')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'mouse down preserves the projected task until release and repeated clicks toggle it',
    (tester) async {
      const text = '- [ ] first\n- [ ] second\nEnd';
      final controller = LiveMarkdownController(
        text: text,
        selection: const TextSelection.collapsed(offset: text.length),
      );
      await mount(tester, controller);
      final checkbox = find.byKey(const ValueKey('task-0'));
      final point = tester.getCenter(checkbox);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.down(point);
      await tester.pump(const Duration(milliseconds: 200));
      expect(checkbox, findsOneWidget);
      expect(controller.selection.extentOffset, text.length);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(controller.text, startsWith('- [x] first'));
      await tester.tap(checkbox, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(controller.text, startsWith('- [ ] first'));
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'phone IME preserves emoji graphemes and composing text in Markdown',
    (tester) async {
      final controller = LiveMarkdownController(
        text: '- ',
        selection: const TextSelection.collapsed(offset: 2),
      );
      await mount(tester, controller);
      await tester.showKeyboard(
        find.byKey(const ValueKey('livemd-document-field')),
      );
      const text = '- 👩‍💻 👍🏽 🇵🇱 ❤️';
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
          composing: TextRange(start: 2, end: text.length),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.text, text);
      expect(controller.composing, const TextRange(start: 2, end: text.length));
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '- 👩‍💻 👍🏽 🇵🇱 ',
          selection: TextSelection.collapsed(
            offset: '- 👩‍💻 👍🏽 🇵🇱 '.length,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.text, '- 👩‍💻 👍🏽 🇵🇱 ');
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
