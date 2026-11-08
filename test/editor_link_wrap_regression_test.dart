import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';

void main() {
  for (final width in [320.0, 390.0]) {
    testWidgets('full link paints and suffix opens at phone width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final renderFont = Platform.environment['SILIQUE_RENDER_FONT'];
      if (renderFont != null) {
        final loader = FontLoader('EvidenceFont')
          ..addFont(
            Future.value(
              ByteData.sublistView(File(renderFont).readAsBytesSync()),
            ),
          );
        await loader.load();
      }
      const url =
          'https://maps.app.goo.gl/7y68vzWJJ6LvCcNs8?g_st=ic&query=😀%20address';
      const source = '😀 before\n$url\nafter';
      final controller = LiveMarkdownController(text: source);
      String? opened;
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('render-evidence'),
          child: MaterialApp(
            theme: ThemeData(
              fontFamily: renderFont == null ? null : 'EvidenceFont',
            ),
            home: Scaffold(
              body: LiveMarkdownEditor(
                controller: controller,
                onLinkTap: (destination, _) => opened = destination,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final link = find.byKey(ValueKey('link-${source.indexOf(url)}'));
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: link, matching: find.byType(RichText)).first,
      );
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: url.length - 7, extentOffset: url.length),
      );
      expect(boxes, isNotEmpty);
      final suffix = paragraph.localToGlobal(boxes.last.toRect().center);
      final target = tester.getRect(link);
      expect(
        target.contains(suffix),
        isTrue,
        reason:
            'The final URL glyphs must fit inside the painted link/tap target: suffix=$suffix target=$target',
      );
      expect(
        target.height,
        greaterThan(30),
        reason: 'Long URL must wrap, not crop to one row',
      );
      debugPrint('LINK width=$width suffix=$suffix target=$target');
      final evidenceDirectory =
          Platform.environment['SILIQUE_RENDER_EVIDENCE_DIR'];
      if (evidenceDirectory != null) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('render-evidence')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(evidenceDirectory).create(recursive: true);
          await File('$evidenceDirectory/link-${width.toInt()}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tapAt(suffix);
      await tester.pumpAndSettle();
      expect(opened, url);
      expect(controller.text, source);
      final field = find.byKey(const ValueKey('livemd-document-field'));
      await tester.showKeyboard(field);
      controller.setSelection(
        TextSelection.collapsed(offset: source.indexOf(url) + 35),
      );
      await tester.pumpAndSettle();
      final editable = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      expect(editable.text!.toPlainText(), source);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(controller.text, source);
      expect(controller.selection.extentOffset, source.indexOf(url) + 36);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }
}
