import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';
import 'package:silique/ui/theme.dart';

/// Inline code fill used by the note body, mirroring
/// `test/code_block_formatting_test.dart`.
const _inlineCodeBackground = Color(0xff1f2739);

final _codeBlockDecoration = BoxDecoration(
  color: panel,
  borderRadius: BorderRadius.circular(10),
  border: Border.all(color: line),
);

/// A fenced block with a short fence line, two code lines, and an empty line
/// between them, framed by ordinary paragraphs.
const _text =
    'Before\n\n```\nfinal answer = 42;\n\nprint(answer);\n```\n\nUse `answer` inline after.';

/// Mirrors the live theme `_noteBody` builds in `lib/ui/home.dart`.
LiveMarkdownThemeData _liveTheme() => LiveMarkdownThemeData(
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
  codeBlockDecoration: _codeBlockDecoration,
);

/// Mounts the editor in the two layouts the app uses: a bounded viewport and a
/// content-sized field inside the document scroll view.
Future<void> _mount(
  WidgetTester tester,
  LiveMarkdownController document, {
  required bool contentSized,
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
    theme: _liveTheme(),
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

void main() {
  for (final contentSized in [false, true]) {
    testWidgets(
      'every fenced code line keeps its glyphs indented from the panel edge '
      'contentSized=$contentSized',
      (tester) async {
        final document = LiveMarkdownController(
          text: _text,
          selection: TextSelection.collapsed(offset: _text.length),
        );
        await _mount(tester, document, contentSized: contentSized);

        final fenceStart = _text.indexOf('```');
        final bodyFirst = _text.indexOf('final');
        final bodySecond = _text.indexOf('print');
        final closingStart = _text.lastIndexOf('```');
        final emptyLine = _text.indexOf(';', bodyFirst) + 2;
        expect(_text[emptyLine], '\n', reason: 'fixture owns an empty line');

        final panel = find.byKey(ValueKey('code-background-$fenceStart'));
        expect(panel, findsOneWidget);
        final panelLeft = tester.getRect(panel).left;

        final editable = tester
            .state<EditableTextState>(find.byType(EditableText))
            .renderEditable;

        // Ordinary paragraphs keep the old flush layout; their shared left
        // inset is the baseline the code leads are measured against.
        final paragraphBoxes = editable.getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 1),
        );
        expect(paragraphBoxes, isNotEmpty);
        final paragraphInset =
            editable
                .localToGlobal(paragraphBoxes.first.toRect().topLeft)
                .dx -
            panelLeft;
        expect(paragraphInset, lessThan(12));

        // Each non-empty block line paints its first glyph behind a projected
        // lead placeholder; the old flush layout had no such key and painted
        // at the paragraph inset. The card floor is panel-relative (>= 12);
        // the added indent itself is the vendor `_codeBlockIndent` of 14px on
        // top of the paragraph inset (measured dx ~= inset + 14).
        for (final lead in [fenceStart, bodyFirst, bodySecond, closingStart]) {
          final finder = find.byKey(ValueKey('code-indent-$lead'));
          expect(finder, findsOneWidget, reason: 'lead glyph at offset $lead');
          final dx = tester.getTopLeft(finder).dx - panelLeft;
          expect(
            dx,
            greaterThanOrEqualTo(12),
            reason: 'the glyphs clear the panel edge',
          );
          expect(dx - paragraphInset, greaterThanOrEqualTo(12));
          expect(dx - paragraphInset, lessThanOrEqualTo(16));
        }

        // The empty code line owns no glyph, so it projects no lead either.
        expect(
          find.byKey(ValueKey('code-indent-$emptyLine')),
          findsNothing,
        );

        // The lead keeps the bundled deterministic monospace family.
        final leadText = tester.widget<Text>(
          find.byKey(ValueKey('code-indent-$bodyFirst')),
        );
        expect(leadText.data, 'f');
        expect(leadText.style?.fontFamily, kMonoFontFamily);

        // The lead placeholder widens the selection box of the first code
        // character by the indent, while the document-global offsets stay
        // 1:1 with the source (a box exists for exactly one source unit).
        final leadBoxes = editable.getBoxesForSelection(
          TextSelection(baseOffset: bodyFirst, extentOffset: bodyFirst + 1),
        );
        expect(leadBoxes, hasLength(1));
        expect(leadBoxes.first.toRect().width, greaterThanOrEqualTo(20));

        // Selecting the whole fenced block still resolves across leads.
        final blockBoxes = editable.getBoxesForSelection(
          TextSelection(baseOffset: fenceStart, extentOffset: closingStart + 3),
        );
        expect(blockBoxes, isNotEmpty);

        // The stored Markdown is never mutated by the presentation indent.
        expect(document.text, _text);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
