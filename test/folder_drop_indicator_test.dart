import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/main.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

void main() {
  testWidgets('folder edge drag shows a real 3 px insertion slot', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('silique-drop-indicator-');
    late Notebook repo;
    await tester.runAsync(() async {
      repo = Notebook(
        storage: NativeStorage(root.path),
        keys: MemoryKeys(),
        crypto: TestCrypto(),
      );
      await repo.initialize();
      await repo.createVault('Order');
      for (final path in ['Alpha', 'Beta', 'Gamma']) {
        await repo.createFolder(repo.vaults.single, path);
      }
    });
    await tester.binding.setSurfaceSize(const Size(1380, 900));
    addTearDown(() async {
      await repo.storage.close();
      root.deleteSync(recursive: true);
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [notebookProvider.overrideWithValue(repo)],
        child: const SiliqueApp(),
      ),
    );
    await tester.pumpAndSettle();

    Finder row(String name) => find.byKey(Key('folder-row-$name'));
    final indicator = find.byKey(const Key('folder-drop-indicator'));

    // No drag in progress: no indicator anywhere.
    expect(indicator, findsNothing);

    final alphaRect = tester.getRect(row('Alpha'));

    // Drag Gamma and hover the TOP quarter of Alpha (a sibling at the root).
    final source = tester.getCenter(row('Gamma'));
    final topTarget = Offset(
      alphaRect.center.dx,
      alphaRect.top + alphaRect.height * .1,
    );
    final drag = await tester.startGesture(source);
    await tester.pump(const Duration(milliseconds: 250));
    await drag.moveBy(const Offset(8, 0));
    await tester.pump();
    await drag.moveTo(topTarget);
    await tester.pump(const Duration(milliseconds: 150));

    // The indicator is a real bar: 3 px tall, full row width (±1 px), and the
    // sibling row below is pushed down by the slot (3 px + 8 px padding).
    expect(indicator, findsOneWidget);
    final indicatorRect = tester.getRect(indicator);
    expect(indicatorRect.height, 3);
    final rowBox = find
        .ancestor(of: row('Alpha'), matching: find.byType(Container))
        .first;
    expect(
      (indicatorRect.width - tester.getRect(rowBox).width).abs(),
      lessThanOrEqualTo(1),
    );
    final alphaDuring = tester.getRect(row('Alpha'));
    expect(alphaDuring.top - alphaRect.top, greaterThanOrEqualTo(8));

    // The middle keeps the move-into-folder highlight, with no insertion slot.
    await drag.moveTo(tester.getRect(row('Alpha')).center);
    await tester.pump(const Duration(milliseconds: 150));
    expect(indicator, findsNothing);

    // Drop back on the source (a self-drop is rejected) and clean up.
    await drag.moveTo(tester.getCenter(row('Gamma')));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
