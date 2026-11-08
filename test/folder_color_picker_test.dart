import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/main.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;
import 'hidden_notes_home_test.dart' show drainUntil;

void main() {
  testWidgets(
    'the folder menu opens the visual picker; a picked color lands in '
    'folderColorsOf and "no color" removes it',
    (tester) async {
      late Directory root;
      late Notebook repo;
      await tester.runAsync(() async {
        root = Directory.systemTemp.createTempSync('silique-folder-picker-');
        repo = Notebook(
          storage: NativeStorage(root.path),
          keys: MemoryKeys(),
          crypto: TestCrypto(),
        );
        await repo.initialize();
        await repo.createVault('Folders');
        await repo.createFolder(repo.vaults.single, 'Alpha');
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1440, 1000);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        var closed = false;
        final close = repo.close().then((_) => closed = true);
        await drainUntil(tester, () => closed);
        await close;
        await tester.runAsync(() async => root.deleteSync(recursive: true));
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [notebookProvider.overrideWithValue(repo)],
          child: const SiliqueApp(),
        ),
      );
      await tester.pumpAndSettle();
      final vaultId = repo.vaults.single.id;

      // Folder menu -> "Kolor folderu" -> the visual picker opens.
      await tester.tap(find.byKey(const Key('folder-menu-Alpha')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kolor folderu'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('color-picker-sv')), findsOneWidget);

      // Pick a color and apply: the ARGB entry is stored.
      await tester.tap(find.byKey(const Key('color-picker-sv')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('color-picker-apply')));
      await tester.pump();
      await drainUntil(
        tester,
        () => repo.folderColorsOf(vaultId).containsKey('Alpha'),
      );
      expect(repo.folderColorsOf(vaultId)['Alpha'], isNotNull);
      expect(tester.takeException(), isNull);

      // Reopen and choose "no color": the entry is removed.
      await tester.tap(find.byKey(const Key('folder-menu-Alpha')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kolor folderu'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('color-picker-none')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('color-picker-apply')));
      await tester.pump();
      await drainUntil(
        tester,
        () => !repo.folderColorsOf(vaultId).containsKey('Alpha'),
      );
      expect(repo.folderColorsOf(vaultId), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
