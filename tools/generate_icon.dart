// Run: flutter test tools/generate_icon.dart
// This renders the code-native Silique leaf mark, without a generated bitmap model.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('render Silique launcher icon', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 1024));
    await tester.runAsync(() async {
      final font = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await font.load();
    });
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: key,
          child: Container(
            width: 1024,
            height: 1024,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xff222a44), Color(0xff0e1420)],
              ),
            ),
            child: const Center(
              child: Icon(
                Icons.eco_rounded,
                color: Color(0xff8275ff),
                size: 760,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('assets/icon/app-icon.png')
          .writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
}
