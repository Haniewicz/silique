import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';

void main() {
  for (final width in [240.0, 320.0]) {
    for (final text in [
      '- [ ] First task many ordinary words here.\n'
          '- [x] Second task many ordinary words here.\n\nTAIL words',
      'First [link words here](https://example.com/some/long/path) more words.\n\nTAIL words',
    ]) {
      testWidgets(
        'range selection preserves fixed glyph and handle geometry width=$width ${text.startsWith('-') ? 'tasks' : 'link'}',
        (tester) async {
          String? clipboard;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') {
                clipboard = (call.arguments as Map)['text'] as String;
              } else if (call.method == 'Clipboard.getData') {
                return <String, dynamic>{'text': clipboard};
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          final document = LiveMarkdownController(text: text);
          final scroll = ScrollController();
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    height: 500,
                    child: SingleChildScrollView(
                      controller: scroll,
                      child: LiveMarkdownEditor(
                        controller: document,
                        scrollController: scroll,
                        contentSizedField: true,
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final state = tester.state<EditableTextState>(
            find.byType(EditableText),
          );
          final editing = state.widget.controller;
          editing.selection = TextSelection.collapsed(offset: text.length);
          await tester.pumpAndSettle();
          final render = state.renderEditable;
          final tail = text.indexOf('TAIL');
          Rect tailGlyph() => render
              .getBoxesForSelection(
                TextSelection(baseOffset: tail, extentOffset: tail + 1),
              )
              .first
              .toRect();
          final height = render.size.height;
          final glyph = tailGlyph();
          // Range endpoints use glyph boxes; a collapsed caret uses line height.
          // Compare like for like before extending across Markdown syntax.
          editing.selection = TextSelection(
            baseOffset: tail,
            extentOffset: text.length,
          );
          await tester.pumpAndSettle();
          final end = render
              .getEndpointsForSelection(editing.selection)
              .last
              .point;
          for (final start in [tail, 7, 1, 0, tail]) {
            editing.selection = TextSelection(
              baseOffset: start,
              extentOffset: text.length,
            );
            await tester.pumpAndSettle();
            debugPrint(
              'GEOMETRY width=$width start=$start height=$height -> ${render.size.height}, glyph=$glyph -> ${tailGlyph()}',
            );
            expect(
              render.size.height,
              closeTo(height, 0.01),
              reason: 'Highlighting Markdown must not reveal syntax and reflow the document',
            );
            expect(tailGlyph(), glyph);
            expect(
              render.getEndpointsForSelection(editing.selection).last.point,
              end,
              reason: 'The fixed lower handle must not move when only the upper range changes',
            );
            expect(scroll.offset, 0);
            expect(document.text, text);
            expect(render.plainText.length, text.length);
          }
          // A stable projection must not replace the lossless source clipboard.
          editing.selection = TextSelection(
            baseOffset: 0,
            extentOffset: text.length,
          );
          await tester.pumpAndSettle();
          state.copySelection(SelectionChangedCause.toolbar);
          await tester.pump();
          final copied = await tester.runAsync(
            () => Clipboard.getData(Clipboard.kTextPlain),
          );
          expect(copied!.text, text);
          // Returning to a caret still reveals editable Markdown syntax.
          editing.selection = const TextSelection.collapsed(offset: 2);
          await tester.pumpAndSettle();
          if (text.startsWith('-')) {
            expect(find.byKey(const ValueKey('task-0')), findsNothing);
          }
          // Replacing a selected range must discard its old layout snapshot.
          editing.selection = TextSelection(
            baseOffset: 0,
            extentOffset: text.length,
          );
          state.userUpdateTextEditingValue(
            const TextEditingValue(
              text: 'Replacement',
              selection: TextSelection.collapsed(offset: 11),
            ),
            SelectionChangedCause.keyboard,
          );
          await tester.pumpAndSettle();
          expect(document.text, 'Replacement');
          expect(render.plainText, 'Replacement');
          expect(editing.selection, const TextSelection.collapsed(offset: 11));
          await tester.pumpWidget(const SizedBox());
          document.dispose();
          scroll.dispose();
        },
      );
    }
  }
}
