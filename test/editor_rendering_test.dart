import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';
import 'package:silique/ui/theme.dart';

import 'fixtures/image_fixtures.dart';

void main() {
  testWidgets(
    'long attachment names render decoded photos at desktop and phone widths',
    (tester) async {
      const destination = 'silique-image:76e7b6f4-ebaf-4bf9-b76c-f02b3e9410bd';
      const image = '![Zrzut ekranu 2026-09-24 o 15.33.36.png]($destination)';
      const text = '$image\n$image\nAfter';
      final controller = LiveMarkdownController(
        text: text,
        selection: const TextSelection.collapsed(offset: text.length),
      );
      final provider = MemoryImage(sampleBmp(width: 320, height: 160));
      await tester.runAsync(() async {
        final stream = provider.resolve(ImageConfiguration.empty);
        final ready = Completer<void>();
        final listener = ImageStreamListener(
          (info, _) {
            info.dispose();
            if (!ready.isCompleted) ready.complete();
          },
          onError: (Object error, StackTrace? stack) {
            if (!ready.isCompleted) ready.completeError(error, stack);
          },
        );
        stream.addListener(listener);
        try {
          await ready.future.timeout(const Duration(seconds: 5));
        } finally {
          stream.removeListener(listener);
        }
      });
      for (final width in [700.0, 320.0]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: siliqueTheme(),
            home: Scaffold(
              body: SizedBox(
                width: width,
                child: LiveMarkdownEditor(
                  controller: controller,
                  imageResolver: (url) {
                    expect(url, destination);
                    return provider;
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final offset in [text.length, 20, image.length + 21]) {
          controller.setSelection(TextSelection.collapsed(offset: offset));
          await tester.pumpAndSettle();
          final photos = find.byType(RawImage);
          expect(photos, findsNWidgets(2));
          expect(
            tester.getRect(photos.at(0)).bottom,
            lessThanOrEqualTo(tester.getRect(photos.at(1)).top),
          );
          for (final photo in photos.evaluate()) {
            final decoded = (photo.widget as RawImage).image;
            expect(decoded, isNotNull);
            expect(decoded!.width, 320);
            expect(decoded.height, 160);
            expect(
              tester.getSize(find.byWidget(photo.widget)).height,
              greaterThanOrEqualTo(160),
            );
          }
          expect(tester.takeException(), isNull);
        }
      }
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.android,
    }),
  );

  testWidgets(
    'web URLs open their destination and task checkboxes toggle the source',
    (tester) async {
      const text = 'A https://example.com/path.\n- [ ] task\n# Heading\nEnd';
      final controller = LiveMarkdownController(
        text: text,
        selection: const TextSelection.collapsed(offset: text.length),
      );
      String? opened;
      await tester.pumpWidget(
        MaterialApp(
          theme: siliqueTheme(),
          home: Scaffold(
            body: LiveMarkdownEditor(
              controller: controller,
              onLinkTap: (url, _) => opened = url,
              theme: const LiveMarkdownThemeData(
                bodyStyle: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (defaultTargetPlatform == TargetPlatform.android) {
        await tester.tap(find.byKey(const ValueKey('link-2')));
      } else {
        final render = tester
            .state<EditableTextState>(find.byType(EditableText))
            .renderEditable;
        final box = render
            .getBoxesForSelection(
              const TextSelection(baseOffset: 2, extentOffset: 6),
            )
            .first;
        await tester.tapAt(
          render.localToGlobal(box.toRect().center),
          kind: PointerDeviceKind.mouse,
        );
      }
      expect(opened, 'https://example.com/path');
      final taskStart = text.indexOf('- [ ]');
      await tester.tap(find.byKey(ValueKey('task-$taskStart')));
      await tester.pumpAndSettle();
      expect(controller.text, contains('- [x] task'));
      expect(tester.takeException(), isNull);
      controller.setText('Plain text\n# Heading\n');
      controller.setSelection(
        TextSelection.collapsed(offset: controller.text.length),
      );
      await tester.pumpAndSettle();
      final editable = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      final caret = editable.getLocalRectForCaret(
        TextPosition(offset: controller.text.length),
      );
      final lastGlyph = editable
          .getBoxesForSelection(
            const TextSelection(baseOffset: 15, extentOffset: 16),
          )
          .single;
      expect(caret.center.dy, greaterThan(lastGlyph.toRect().bottom));
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.android,
    }),
  );

  testWidgets(
    'caret stays vertically centered on body and heading glyphs',
    (tester) async {
      const text = 'Plain text\n# Heading\nEnd';
      final controller = LiveMarkdownController(text: text);
      await tester.pumpWidget(
        MaterialApp(
          theme: siliqueTheme(),
          home: Scaffold(
            body: LiveMarkdownEditor(
              controller: controller,
              theme: const LiveMarkdownThemeData(
                bodyStyle: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
                h1Style: TextStyle(
                  fontSize: 28,
                  height: 1.4,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              ),
            ),
          ),
        ),
      );
      for (final offset in [2, text.indexOf('Heading') + 2]) {
        controller.setSelection(TextSelection.collapsed(offset: offset));
        await tester.pumpAndSettle();
        final editable = tester
            .state<EditableTextState>(find.byType(EditableText))
            .renderEditable;
        final caret = editable.getLocalRectForCaret(
          TextPosition(offset: offset),
        );
        final glyph = editable
            .getBoxesForSelection(
              TextSelection(baseOffset: offset, extentOffset: offset + 1),
            )
            .single;
        expect(caret.center.dy, closeTo(glyph.toRect().center.dy, 1.5));
      }
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.android,
    }),
  );
}
