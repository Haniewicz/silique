import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/ui/dialogs.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

const _updatesTab = Key('settings-tab-updates');

Future<Notebook> _notebook(WidgetTester tester) async {
  final dir = Directory.systemTemp.createTempSync('silique-tab-scroll-');
  final repo = Notebook(
    storage: NativeStorage(dir.path),
    keys: MemoryKeys(),
    crypto: TestCrypto(),
  );
  await tester.runAsync(() => repo.initialize());
  addTearDown(() async {
    await repo.storage.close();
    dir.deleteSync(recursive: true);
  });
  return repo;
}

Future<void> _mount(WidgetTester tester, Notebook repo) async {
  tester.view.physicalSize = const Size(700, 700);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: Dialog(
            child: SettingsPanel(notebook: repo, onChanged: () {}),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Rect of the scrollable tab strip (the horizontal SingleChildScrollView that
/// carries the tabs), in global coordinates.
Rect _barRect(WidgetTester tester) {
  final box = tester.renderObject<RenderBox>(
    find
        .descendant(
          of: find.byType(TabBar),
          matching: find.byType(SingleChildScrollView),
        )
        .first,
  );
  return box.localToGlobal(Offset.zero) & box.size;
}

Rect _updatesRect(WidgetTester tester) {
  final box = tester.renderObject<RenderBox>(find.byKey(_updatesTab));
  return box.localToGlobal(Offset.zero) & box.size;
}

void main() {
  testWidgets('mouse wheel over the tab bar scrolls the tabs horizontally', (
    tester,
  ) async {
    final repo = await _notebook(tester);
    await _mount(tester, repo);

    final bar = _barRect(tester);
    final before = _updatesRect(tester);
    // The narrow window pushes the updates tab past the right edge.
    expect(before.right, greaterThan(bar.right), reason: 'updates starts hidden');

    tester.binding.handlePointerEvent(
      PointerScrollEvent(
        position: bar.center,
        scrollDelta: const Offset(0, -2000),
      ),
    );
    await tester.pump();

    final after = _updatesRect(tester);
    expect(after.right, lessThanOrEqualTo(bar.right + 1));
    expect(after.left, greaterThanOrEqualTo(bar.left - 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mouse wheel over tab content does not scroll the tab bar', (
    tester,
  ) async {
    final repo = await _notebook(tester);
    await _mount(tester, repo);

    final bar = _barRect(tester);
    final before = _updatesRect(tester);
    expect(before.right, greaterThan(bar.right));

    // A point well below the tab bar, over the active tab's (vertically
    // scrollable) content.
    final contentPoint = Offset(bar.center.dx, bar.bottom + 40);
    tester.binding.handlePointerEvent(
      PointerScrollEvent(
        position: contentPoint,
        scrollDelta: const Offset(0, -120),
      ),
    );
    await tester.pump();

    final after = _updatesRect(tester);
    expect(after, equals(before), reason: 'bar must not move from content wheel');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mouse drag over the tab bar scrolls the tabs', (tester) async {
    final repo = await _notebook(tester);
    await _mount(tester, repo);

    final bar = _barRect(tester);
    expect(_updatesRect(tester).right, greaterThan(bar.right));

    // Press and drag left with the mouse; the dragDevices override lets the
    // strip's horizontal drag recognizer accept mouse input.
    final gesture = await tester.startGesture(
      bar.center,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 16));
    for (var step = 0; step < 6; step++) {
      await gesture.moveBy(const Offset(-120, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final after = _updatesRect(tester);
    expect(after.right, lessThanOrEqualTo(bar.right + 1));
    expect(after.left, greaterThanOrEqualTo(bar.left - 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
