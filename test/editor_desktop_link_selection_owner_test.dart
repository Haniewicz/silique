import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';

// Caret rects include cursorOffset, custom cursor height and physical-pixel
// snapping. The editor realigns that cursor after selection changes; none of
// those paint adjustments move the text. Compare every ASCII label/URL glyph's
// actual global box instead, including wrapped rows and both rectangle edges.
// Global coordinates also catch scrolling or movement of the editor itself.
List<List<Rect>> _glyphBounds(RenderEditable render, int start, int end) {
  final result = <List<Rect>>[];
  for (var offset = start; offset < end; offset++) {
    final boxes = render.getBoxesForSelection(
      TextSelection(baseOffset: offset, extentOffset: offset + 1),
    );
    expect(boxes, isNotEmpty, reason: 'Native glyph at source offset $offset');
    // A trailing space or span boundary can have multiple boxes. Preserve all
    // of them, grouped by source offset, rather than assuming one box per char.
    result.add([
      for (final box in boxes)
        Rect.fromPoints(
          render.localToGlobal(box.toRect().topLeft),
          render.localToGlobal(box.toRect().bottomRight),
        ),
    ]);
  }
  return result;
}

void main() {
  testWidgets('a link pointer is revoked by a document edit before release', (
    tester,
  ) async {
    const source = 'before\n[label](https://example.org)\nafter';
    final document = LiveMarkdownController(text: source);
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveMarkdownEditor(
            controller: document,
            onLinkTap: (url, _) => opened.add(url),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final render = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final box = render
        .getBoxesForSelection(
          TextSelection(
            baseOffset: source.indexOf('label'),
            extentOffset: source.indexOf('label') + 2,
          ),
        )
        .first;
    final pointer = await tester.startGesture(
      render.localToGlobal(box.toRect().center),
      kind: PointerDeviceKind.mouse,
    );
    document.text = 'replacement';
    await tester.pump();
    await pointer.up();
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(document.text, 'replacement');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    document.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  for (final width in [240.0, 320.0]) {
    testWidgets(
      'native wrapped URL final glyph remains visible and opens width=$width',
      (tester) async {
        const url =
            'https://maps.app.goo.gl/7y68vzWJJ6LvCcNs8?g_st=ic&query=😀%20addressEND';
        const source = '😀 before\n$url\nafter';
        final document = LiveMarkdownController(text: source);
        String? opened;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: width,
                child: LiveMarkdownEditor(
                  controller: document,
                  onLinkTap: (url, _) => opened = url,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final render = tester
            .state<EditableTextState>(find.byType(EditableText))
            .renderEditable;
        final end = source.indexOf('END') + 3;
        final boxes = render.getBoxesForSelection(
          TextSelection(baseOffset: end - 3, extentOffset: end),
        );
        expect(boxes, isNotEmpty);
        final suffix = render.localToGlobal(boxes.last.toRect().center);
        expect(
          (Offset.zero & render.size).contains(boxes.last.toRect().center),
          isTrue,
        );
        expect(
          boxes.last.top,
          greaterThan(
            render
                .getBoxesForSelection(
                  TextSelection(
                    baseOffset: source.indexOf(url),
                    extentOffset: source.indexOf(url) + 1,
                  ),
                )
                .first
                .bottom,
          ),
        );
        await tester.tapAt(suffix);
        await tester.pumpAndSettle();
        expect(opened, url);
        expect(document.text, source);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(document.selection.isCollapsed, isTrue);
        expect(render.plainText, source);
        await tester.pumpWidget(const SizedBox());
        document.dispose();
      },
      variant: TargetPlatformVariant({
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      }),
    );
  }
  testWidgets(
    'wiki alias supports partial reverse selection and still opens its target',
    (tester) async {
      const source = 'before\n[[Private target|alias words]]\nafter';
      final document = LiveMarkdownController(text: source);
      final opened = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveMarkdownEditor(
              controller: document,
              onWikiLinkTap: (target, alias) => opened.add('$target|$alias'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final render = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      Offset point(int offset) => render.localToGlobal(
        render.getLocalRectForCaret(TextPosition(offset: offset)).center,
      );
      final start = source.indexOf('alias');
      final labelEnd = start + 'alias words'.length;
      final glyphs = _glyphBounds(render, start, labelEnd);
      final a = point(start);
      final b = point(start + 5);
      final drag = await tester.startGesture(b, kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(
        _glyphBounds(render, start, labelEnd),
        glyphs,
        reason: 'Mouse-down must not reveal or move wiki alias glyphs',
      );
      await drag.moveTo(a);
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(
        document.selection,
        TextSelection(baseOffset: start + 5, extentOffset: start),
      );
      expect(document.selection.textInside(source), 'alias');
      expect(opened, isEmpty);
      expect(_glyphBounds(render, start, labelEnd), glyphs);
      await tester.tapAt(point(start + 7));
      await tester.pumpAndSettle();
      expect(opened, ['Private target|alias words']);
      expect(document.text, source);
      await tester.pumpWidget(const SizedBox());
      document.dispose();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets('one-character mouse range is selection rather than a link tap', (
    tester,
  ) async {
    const source = 'before\n[short label](https://example.org)\nafter';
    final document = LiveMarkdownController(text: source);
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveMarkdownEditor(
            controller: document,
            onLinkTap: (url, _) => opened.add(url),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final render = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    Offset point(int offset) => render.localToGlobal(
      render.getLocalRectForCaret(TextPosition(offset: offset)).center,
    );
    final start = source.indexOf('short');
    final drag = await tester.startGesture(
      point(start),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveTo(point(start + 1));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(document.selection.textInside(source), 's');
    expect(
      opened,
      isEmpty,
      reason: 'Even a one-character drag must not navigate',
    );
    await tester.pumpWidget(const SizedBox());
    document.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets(
    'wrapped label opens on tap but preserves geometry during partial drag',
    (tester) async {
      const label = 'a long descriptive link label with wrapped words';
      const source = 'before\n[$label](https://example.org)\nafter';
      final document = LiveMarkdownController(text: source);
      final opened = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 240,
              child: LiveMarkdownEditor(
                controller: document,
                onLinkTap: (url, _) => opened.add(url),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final render = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      Offset point(int offset) => render.localToGlobal(
        render.getLocalRectForCaret(TextPosition(offset: offset)).center,
      );
      final start = source.indexOf('descriptive');
      final end = start + 5;
      final labelStart = source.indexOf(label);
      final glyphs = _glyphBounds(
        render,
        labelStart,
        labelStart + label.length,
      );
      final a = point(start);
      final b = point(end);
      final drag = await tester.startGesture(a, kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(
        _glyphBounds(render, labelStart, labelStart + label.length),
        glyphs,
        reason: 'Mouse-down must not reveal syntax and reflow the link',
      );
      await drag.moveTo(b);
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(
        document.selection,
        TextSelection(baseOffset: start, extentOffset: end),
      );
      expect(document.selection.textInside(source), 'descr');
      expect(
        _glyphBounds(render, labelStart, labelStart + label.length),
        glyphs,
      );
      expect(opened, isEmpty);
      await tester.tapAt(point(source.indexOf('wrapped')) + const Offset(4, 0));
      await tester.pumpAndSettle();
      expect(opened, ['https://example.org']);
      expect(document.text, source);
      await tester.pumpWidget(const SizedBox());
      document.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'mouse selects only URL substring without opening or moving glyphs',
    (tester) async {
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      const url = 'https://example.org/abcdefghijk/long-path';
      const source = 'before\n$url\nafter';
      final document = LiveMarkdownController(text: source);
      final opened = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveMarkdownEditor(
              controller: document,
              onLinkTap: (url, _) => opened.add(url),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final state = tester.state<EditableTextState>(find.byType(EditableText));
      final render = state.renderEditable;
      final start = source.indexOf('abcdef');
      final end = start + 6;
      final urlStart = source.indexOf(url);
      final glyphs = _glyphBounds(render, urlStart, urlStart + url.length);
      Offset point(int offset) => render.localToGlobal(
        render.getLocalRectForCaret(TextPosition(offset: offset)).center,
      );
      final a = point(start);
      final b = point(end);
      expect(
        (b - a).distance,
        greaterThan(20),
        reason: 'Every visible URL character needs its own caret geometry, not one WidgetSpan slot',
      );
      final gesture = await tester.startGesture(
        a,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(
        _glyphBounds(render, urlStart, urlStart + url.length),
        glyphs,
        reason: 'Mouse-down must not move URL glyphs',
      );
      await gesture.moveTo(b);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        document.selection,
        TextSelection(baseOffset: start, extentOffset: end),
      );
      expect(document.selection.textInside(document.text), 'abcdef');
      expect(_glyphBounds(render, urlStart, urlStart + url.length), glyphs);
      expect(opened, isEmpty);
      state.copySelection(SelectionChangedCause.toolbar);
      await tester.pump();
      expect(
        (await tester.runAsync(() => Clipboard.getData(Clipboard.kTextPlain)))!
            .text,
        'abcdef',
      );
      expect(document.text, source);
      await tester.pumpWidget(const SizedBox());
      document.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );
}
