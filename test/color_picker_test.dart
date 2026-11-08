import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/ui/color_picker.dart';

void main() {
  // Opens the picker inside a minimal MaterialApp and returns the Future that
  // resolves when the dialog is dismissed.
  Future<Future<VisualColorResult?>> openPicker(
    WidgetTester tester, {
    Color? initial,
  }) async {
    late Future<VisualColorResult?> result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () {
                  result = showVisualColorPicker(context, initial: initial);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  Color colorOf(VisualColorResult result) => (result as VisualColorValue).color;

  int channel(Color color, int shift) => (color.toARGB32() >> shift) & 0xff;

  void expectNear(Color color, int r, int g, int b) {
    expect(
      (channel(color, 16) - r).abs() <= 8,
      isTrue,
      reason: 'red ${channel(color, 16)} vs $r',
    );
    expect(
      (channel(color, 8) - g).abs() <= 8,
      isTrue,
      reason: 'green ${channel(color, 8)} vs $g',
    );
    expect(
      (channel(color, 0) - b).abs() <= 8,
      isTrue,
      reason: 'blue ${channel(color, 0)} vs $b',
    );
  }

  testWidgets('clicking the SV center picks the expected color', (
    tester,
  ) async {
    final result = await openPicker(tester);
    await tester.tap(find.byKey(const Key('color-picker-sv')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('color-picker-apply')));
    await tester.pumpAndSettle();

    final value = await result;
    expect(value, isA<VisualColorValue>());
    // hue 0, saturation 0.5, value 0.5 -> RGB(128, 64, 64), far from the
    // dialog's neutral background (the picker is not a static surface).
    final color = colorOf(value!);
    expectNear(color, 128, 64, 64);
    expect(color.toARGB32(), isNot(0xff1c222d));
  });

  testWidgets(
    'the SV field is not static: top-left differs from bottom-right',
    (tester) async {
      final topLeft = await openPicker(tester);
      final rect = tester.getRect(find.byKey(const Key('color-picker-sv')));
      await tester.tapAt(rect.topLeft + const Offset(4, 4));
      await tester.pump();
      await tester.tap(find.byKey(const Key('color-picker-apply')));
      await tester.pumpAndSettle();
      final topColor = colorOf((await topLeft)!);

      final bottomRight = await openPicker(tester);
      final rect2 = tester.getRect(find.byKey(const Key('color-picker-sv')));
      await tester.tapAt(rect2.bottomRight - const Offset(4, 4));
      await tester.pump();
      await tester.tap(find.byKey(const Key('color-picker-apply')));
      await tester.pumpAndSettle();
      final bottomColor = colorOf((await bottomRight)!);

      expect(topColor.toARGB32(), isNot(bottomColor.toARGB32()));
    },
  );

  testWidgets('the hue slider changes the hue across its width', (
    tester,
  ) async {
    final left = await openPicker(tester);
    final rect = tester.getRect(find.byKey(const Key('color-picker-hue')));
    await tester.tapAt(Offset(rect.left + rect.width * 0.2, rect.center.dy));
    await tester.pump();
    await tester.tap(find.byKey(const Key('color-picker-apply')));
    await tester.pumpAndSettle();
    final leftColor = colorOf((await left)!);

    final right = await openPicker(tester);
    final rect2 = tester.getRect(find.byKey(const Key('color-picker-hue')));
    await tester.tapAt(Offset(rect2.left + rect2.width * 0.8, rect2.center.dy));
    await tester.pump();
    await tester.tap(find.byKey(const Key('color-picker-apply')));
    await tester.pumpAndSettle();
    final rightColor = colorOf((await right)!);

    expect(leftColor.toARGB32(), isNot(rightColor.toARGB32()));
  });

  testWidgets('"no color" yields a clear result, distinct from a color', (
    tester,
  ) async {
    final result = await openPicker(tester);
    await tester.tap(find.byKey(const Key('color-picker-none')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('color-picker-apply')));
    await tester.pumpAndSettle();
    expect(await result, isA<VisualColorClear>());
  });

  testWidgets('cancelling returns null, distinct from "no color"', (
    tester,
  ) async {
    final result = await openPicker(tester);
    await tester.tap(find.byKey(const Key('color-picker-cancel')));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  testWidgets('apply after a selection returns the color and shows its hex', (
    tester,
  ) async {
    final result = await openPicker(tester, initial: const Color(0xffff0000));
    // A pure primary round-trips exactly, so the informational hex is exact.
    expect(
      tester.widget<Text>(find.byKey(const Key('color-picker-hex'))).data,
      '#FF0000',
    );
    expect(find.byKey(const Key('color-picker-preview')), findsOneWidget);

    await tester.tap(find.byKey(const Key('color-picker-sv')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('color-picker-apply')));
    await tester.pumpAndSettle();
    expect(await result, isA<VisualColorValue>());
  });
}
