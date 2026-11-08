import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/main.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

void main() {
  testWidgets(
    'folder edge drag reorders siblings without moving their subtree and survives restart',
    (tester) async {
      final root = Directory.systemTemp.createTempSync(
        'silique-folder-order-ui-',
      );
      final keys = MemoryKeys();
      Notebook make() => Notebook(
        storage: NativeStorage(root.path),
        keys: keys,
        crypto: TestCrypto(),
      );
      late Notebook repo;
      await tester.runAsync(() async {
        repo = make();
        await repo.initialize();
        await repo.createVault('Order');
        for (final path in ['Alpha', 'Beta', 'Gamma/Child']) {
          await repo.createFolder(repo.vaults.single, path);
        }
      });
      await tester.binding.setSurfaceSize(const Size(1380, 900));
      addTearDown(() async {
        await repo.storage.close();
        root.deleteSync(recursive: true);
        await tester.binding.setSurfaceSize(null);
      });
      Future<void> mount() async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [notebookProvider.overrideWithValue(repo)],
            child: const SiliqueApp(),
          ),
        );
        await tester.pumpAndSettle();
      }

      await mount();
      Finder label(String name) => find.text(name).first;
      expect(
        tester.getTopLeft(label('Alpha')).dy,
        lessThan(tester.getTopLeft(label('Gamma')).dy),
      );
      // The edge means sibling placement; the centre continues to mean nesting.
      final source = tester.getCenter(label('Gamma'));
      final target = tester.getTopLeft(label('Alpha')) + const Offset(12, -4);
      final drag = await tester.startGesture(source);
      await tester.pump(const Duration(milliseconds: 250));
      await drag.moveBy(const Offset(8, 0));
      await tester.pump();
      await drag.moveTo(target);
      await tester.pump(const Duration(milliseconds: 150));
      await drag.up();
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(
        tester.getTopLeft(label('Gamma')).dy,
        lessThan(tester.getTopLeft(label('Alpha')).dy),
        reason:
            'edge drop must change sibling order, not nest Gamma under Alpha',
      );
      expect(
        repo.allFolders(repo.vaults.single.id),
        containsAll(['Gamma', 'Gamma/Child']),
      );
      expect(
        repo.allFolders(repo.vaults.single.id),
        isNot(contains('Alpha/Gamma')),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await repo.close();
        repo = make();
        await repo.initialize();
      });
      await mount();
      expect(
        tester.getTopLeft(label('Gamma')).dy,
        lessThan(tester.getTopLeft(label('Alpha')).dy),
      );
      expect(find.text('Child'), findsOneWidget);
      await tester.tap(find.byKey(const Key('folder-toggle-Gamma')));
      await tester.pumpAndSettle();
      expect(find.text('Child'), findsNothing);
      final betaRow = tester.getRect(
        find.ancestor(of: label('Beta'), matching: find.byType(InkWell)).first,
      );
      final lowerDrag = await tester.startGesture(
        tester.getCenter(label('Gamma')),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await lowerDrag.moveBy(const Offset(8, 0));
      await tester.pump();
      await lowerDrag.moveTo(betaRow.bottomLeft + const Offset(45, -3));
      await tester.pump(const Duration(milliseconds: 150));
      await lowerDrag.up();
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(
        tester.getTopLeft(label('Gamma')).dy,
        greaterThan(tester.getTopLeft(label('Beta')).dy),
        reason: 'bottom edge moves the collapsed subtree after its sibling',
      );
      expect(find.text('Child'), findsNothing);
      expect(
        repo.allFolders(repo.vaults.single.id),
        isNot(contains('Beta/Gamma')),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
