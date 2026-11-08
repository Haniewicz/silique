import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/ui/top_pull_dismiss.dart';

void main() {
  testWidgets('multitouch remains canceled until every contact is released', (
    tester,
  ) async {
    var dismissals = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: TopPullDismiss(
          onDismiss: () {
            dismissals++;
          },
          child: const ColoredBox(color: Colors.white),
        ),
      ),
    );
    final first = await tester.startGesture(const Offset(150, 100), pointer: 1);
    final second = await tester.startGesture(
      const Offset(200, 100),
      pointer: 2,
    );
    await first.up();
    final third = await tester.startGesture(const Offset(250, 100), pointer: 3);
    await third.moveBy(const Offset(0, 140));
    await third.up();
    await tester.pumpAndSettle();
    expect(dismissals, 0);
    await second.up();
    await tester.dragFrom(const Offset(200, 100), const Offset(0, 140));
    await tester.pumpAndSettle();
    expect(dismissals, 1);
  });
  testWidgets('exit stays offscreen while save-before-close is pending', (
    tester,
  ) async {
    final saved = Completer<void>();
    const target = Key('saving-note');
    await tester.pumpWidget(
      MaterialApp(
        home: TopPullDismiss(
          onDismiss: () async {
            await saved.future;
          },
          child: const ColoredBox(key: target, color: Colors.white),
        ),
      ),
    );
    await tester.dragFrom(const Offset(200, 100), const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(target)).dy, greaterThanOrEqualTo(600));
    saved.complete();
    await tester.pumpAndSettle();
  });
  testWidgets('pull follows finger reversibly and animates home on release', (
    tester,
  ) async {
    var dismissals = 0;
    const target = Key('moving-note');
    await tester.pumpWidget(
      MaterialApp(
        home: TopPullDismiss(
          onDismiss: () {
            dismissals++;
          },
          child: const ColoredBox(key: target, color: Colors.white),
        ),
      ),
    );
    final origin = tester.getTopLeft(find.byKey(target));
    final gesture = await tester.startGesture(const Offset(200, 100));
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(target)).dy, origin.dy + 120);
    expect(dismissals, 0);
    await gesture.moveBy(const Offset(0, -90));
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(target)).dy, origin.dy + 30);
    await gesture.up();
    await tester.pump();
    expect(dismissals, 0);
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      tester.getTopLeft(find.byKey(target)).dy,
      inExclusiveRange(origin.dy, origin.dy + 30),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(target)), origin);
  });

  testWidgets('released pull animates offscreen before dismissing once', (
    tester,
  ) async {
    var dismissals = 0;
    const target = Key('moving-note');
    await tester.pumpWidget(
      MaterialApp(
        home: TopPullDismiss(
          onDismiss: () {
            dismissals++;
          },
          child: const ColoredBox(key: target, color: Colors.white),
        ),
      ),
    );
    final gesture = await tester.startGesture(const Offset(200, 100));
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump();
    expect(dismissals, 0);
    await gesture.up();
    await tester.pump();
    expect(dismissals, 0);
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getTopLeft(find.byKey(target)).dy, greaterThan(120));
    await tester.pumpAndSettle();
    expect(dismissals, 1);
  });
  testWidgets(
    'long press extends real text selection at top without dismissing',
    (tester) async {
      final controller = TextEditingController(
        text: List.generate(12, (i) => 'Selection line $i words').join('\n'),
      );
      addTearDown(controller.dispose);
      var dismissals = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TopPullDismiss(
              onDismiss: () {
                dismissals++;
              },
              child: TextField(
                controller: controller,
                maxLines: null,
                expands: true,
              ),
            ),
          ),
        ),
      );
      final field = find.byType(TextField);
      final start = tester.getTopLeft(field) + const Offset(60, 15);
      final gesture = await tester.startGesture(start);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      final initial = controller.selection;
      expect(initial.isCollapsed, isFalse);
      await gesture.moveBy(const Offset(0, 110));
      await tester.pump();
      expect(controller.selection, isNot(initial));
      expect(controller.selection.isCollapsed, isFalse);
      await gesture.up();
      await tester.pump();
      expect(dismissals, 0);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('selection winning during a fast pull cancels dismissal', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'Selection line words');
    addTearDown(controller.dispose);
    var dismissals = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopPullDismiss(
            onDismiss: () {
              dismissals++;
            },
            child: TextField(
              controller: controller,
              maxLines: null,
              expands: true,
            ),
          ),
        ),
      ),
    );
    final start =
        tester.getTopLeft(find.byType(TextField)) + const Offset(60, 15);
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(0, 110));
    // A selection recognizer can win before the long-press deadline.
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 9);
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pump();
    expect(dismissals, 0);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'nested vertical editor must start at top before pull can dismiss',
    (tester) async {
      final nested = ScrollController();
      var dismissals = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TopPullDismiss(
              onDismiss: () {
                dismissals++;
              },
              child: ListView(
                children: [
                  SizedBox(
                    height: 300,
                    child: ListView(
                      key: const Key('nested'),
                      controller: nested,
                      children: List.generate(
                        40,
                        (i) => SizedBox(height: 40, child: Text('Line $i')),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      nested.jumpTo(100);
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(200, 100), const Offset(0, 180));
      await tester.pumpAndSettle();
      expect(nested.offset, 0);
      expect(dismissals, 0);
      await tester.dragFrom(const Offset(200, 100), const Offset(0, 140));
      await tester.pumpAndSettle();
      expect(dismissals, 1);
      await tester.pumpWidget(const SizedBox());
      nested.dispose();
    },
  );

  for (final entry in <String, List<Offset>>{
    'short': [const Offset(0, 40)],
    'upward': [const Offset(0, -120)],
    'horizontal': [const Offset(120, 100)],
    'diagonal without vertical dominance': [const Offset(45, 85)],
    'horizontal then down': [const Offset(60, 0), const Offset(-60, 140)],
    'up then down': [const Offset(0, -40), const Offset(0, 180)],
  }.entries) {
    testWidgets('${entry.key} gesture does not dismiss', (tester) async {
      var dismissals = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: TopPullDismiss(
            onDismiss: () {
              dismissals++;
            },
            child: const ColoredBox(color: Colors.white),
          ),
        ),
      );
      final gesture = await tester.startGesture(const Offset(200, 200));
      for (final delta in entry.value) {
        await gesture.moveBy(delta);
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();
      expect(dismissals, 0);
    });
  }

  for (final hold in [
    kLongPressTimeout - const Duration(milliseconds: 1),
    kLongPressTimeout,
    kLongPressTimeout + const Duration(milliseconds: 1),
  ]) {
    testWidgets('hold boundary ${hold.inMilliseconds}ms before downward pull', (
      tester,
    ) async {
      var dismissals = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: TopPullDismiss(
            onDismiss: () {
              dismissals++;
            },
            child: const ColoredBox(color: Colors.white),
          ),
        ),
      );
      final gesture = await tester.startGesture(const Offset(200, 200));
      await tester.pump(hold);
      await gesture.moveBy(const Offset(35, 120));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(dismissals, hold < kLongPressTimeout ? 1 : 0);
    });
  }

  for (final originalUpFirst in [false, true]) {
    testWidgets(
      'multitouch cancels pull with original up first $originalUpFirst',
      (tester) async {
        var dismissals = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: TopPullDismiss(
              onDismiss: () {
                dismissals++;
              },
              child: const ColoredBox(color: Colors.white),
            ),
          ),
        );
        final first = await tester.startGesture(
          const Offset(200, 200),
          pointer: 1,
        );
        final second = await tester.startGesture(
          const Offset(240, 200),
          pointer: 2,
        );
        await first.moveBy(const Offset(0, 140));
        if (originalUpFirst) {
          await first.up();
          await second.moveBy(const Offset(0, 140));
          await second.up();
        } else {
          await second.up();
          await first.up();
        }
        await tester.pump();
        expect(dismissals, 0);
        // A subsequent independent fast touch still works.
        await tester.dragFrom(const Offset(200, 200), const Offset(0, 140));
        await tester.pumpAndSettle();
        expect(dismissals, 1);
      },
    );
  }

  testWidgets('mouse drag and canceled touch never dismiss', (tester) async {
    var dismissals = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: TopPullDismiss(
          onDismiss: () {
            dismissals++;
          },
          child: const ColoredBox(color: Colors.white),
        ),
      ),
    );
    final mouse = await tester.startGesture(
      const Offset(200, 200),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(0, 150));
    await mouse.up();
    final touch = await tester.startGesture(const Offset(200, 200));
    await touch.moveBy(const Offset(0, 150));
    await touch.cancel();
    await tester.pump();
    expect(dismissals, 0);
  });
}
