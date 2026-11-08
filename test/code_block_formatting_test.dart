import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';
import 'package:silique/ui/theme.dart';

/// Inline code fill used by the note body; it stays close to the field fill
/// `0xff1c2435` from the application theme without merging into it.
const _inlineCodeBackground = Color(0xff1f2739);

final _codeBlockDecoration = BoxDecoration(
  color: panel,
  borderRadius: BorderRadius.circular(10),
  border: Border.all(color: line),
);

const _text =
    'Before\n\n```\nfinal answer = 42;\nprint(answer);\n```\n\nUse `answer` inline after.';

/// Mirrors the live theme `_noteBody` builds in `lib/ui/home.dart`.
LiveMarkdownThemeData _liveTheme({bool decorateBlocks = true}) =>
    LiveMarkdownThemeData(
      bodyStyle: const TextStyle(
        fontSize: 14,
        height: 1.5,
        leadingDistribution: TextLeadingDistribution.even,
      ),
      codeStyle: const TextStyle(
        fontFamily: kMonoFontFamily,
        fontFamilyFallback: ['monospace'],
        fontSize: 13,
        backgroundColor: _inlineCodeBackground,
      ),
      codeBlockDecoration: decorateBlocks ? _codeBlockDecoration : null,
    );

/// Mounts the editor in the two layouts the app uses: a bounded viewport and a
/// content-sized field inside the document scroll view.
Future<void> _mount(
  WidgetTester tester,
  LiveMarkdownController document, {
  required bool contentSized,
  LiveMarkdownThemeData? theme,
}) async {
  final scroll = ScrollController();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    document.dispose();
    scroll.dispose();
  });
  final editor = LiveMarkdownEditor(
    controller: document,
    scrollController: scroll,
    contentSizedField: contentSized,
    padding: EdgeInsets.zero,
    theme: theme ?? _liveTheme(),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: siliqueTheme(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 420,
            height: 520,
            child: contentSized
                ? SingleChildScrollView(controller: scroll, child: editor)
                : editor,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The rendered rectangle of every source line of the fenced block.
Rect _codeLinesRect(WidgetTester tester, int start, int end) {
  final editable = tester
      .state<EditableTextState>(find.byType(EditableText))
      .renderEditable;
  final boxes = editable.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: end),
  );
  expect(boxes, isNotEmpty, reason: 'the fenced source must stay laid out');
  var lines = boxes.first.toRect();
  for (final box in boxes.skip(1)) {
    lines = lines.expandToInclude(box.toRect());
  }
  return Rect.fromPoints(
    editable.localToGlobal(lines.topLeft),
    editable.localToGlobal(lines.bottomRight),
  );
}

void main() {
  for (final contentSized in [false, true]) {
    testWidgets(
      'a fenced block paints its themed panel over the code lines '
      'contentSized=$contentSized',
      (tester) async {
        final document = LiveMarkdownController(
          text: _text,
          selection: TextSelection.collapsed(offset: _text.length),
        );
        await _mount(tester, document, contentSized: contentSized);

        expect(
          find.byKey(const ValueKey('code-background-layer')),
          findsOneWidget,
          reason: 'both layouts own the code background layer',
        );
        final start = _text.indexOf('```');
        final end = _text.indexOf('```', start + 3) + 3;
        final panel = find.byKey(ValueKey('code-background-$start'));
        expect(panel, findsOneWidget);
        expect(
          tester.widget<DecoratedBox>(panel).decoration,
          _codeBlockDecoration,
        );

        final code = _codeLinesRect(tester, start, end);
        final painted = tester.getRect(panel);
        expect(painted.top, closeTo(code.top, 2));
        expect(painted.bottom, closeTo(code.bottom, 2));
        expect(
          painted.left,
          lessThanOrEqualTo(code.left + 2),
          reason: 'the panel must cover the code glyphs horizontally',
        );
        expect(painted.right, greaterThanOrEqualTo(code.right - 2));
        expect(
          painted.width,
          closeTo(tester.getSize(find.byType(LiveMarkdownEditor)).width, 2),
          reason: 'the panel spans the editing surface',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('inline code keeps the codeStyle background', (tester) async {
    final document = LiveMarkdownController(
      text: _text,
      selection: TextSelection.collapsed(offset: _text.length),
    );
    await _mount(tester, document, contentSized: true);

    TextSpan? code;
    tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable
        .text!
        .visitChildren((span) {
          if (span is TextSpan &&
              span.text?.contains('answer') == true &&
              span.style?.backgroundColor == _inlineCodeBackground) {
            code = span;
          }
          return true;
        });
    expect(
      code,
      isNotNull,
      reason: 'the inline code span carries codeStyle.backgroundColor',
    );
    expect(code!.style?.fontFamily, kMonoFontFamily);
    expect(code!.style?.fontSize, 13);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an omitted codeBlockDecoration keeps the default panel', (
    tester,
  ) async {
    final document = LiveMarkdownController(
      text: _text,
      selection: TextSelection.collapsed(offset: _text.length),
    );
    await _mount(
      tester,
      document,
      contentSized: true,
      theme: _liveTheme(decorateBlocks: false),
    );

    final start = _text.indexOf('```');
    final panel = find.byKey(ValueKey('code-background-$start'));
    expect(panel, findsOneWidget);
    final decoration =
        tester.widget<DecoratedBox>(panel).decoration as BoxDecoration;
    // A host decoration wins; omitting it restores the vendor default, which
    // follows the host surface fill instead of the inline `codeStyle` color.
    expect(decoration, isNot(_codeBlockDecoration));
    expect(decoration.color, siliqueTheme().colorScheme.surface);
    expect(decoration.border, isNull);
    expect(decoration.borderRadius, isA<BorderRadius>());
    expect(tester.takeException(), isNull);
  });
}
