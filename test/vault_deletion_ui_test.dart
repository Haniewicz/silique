import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/main.dart';
import 'package:silique/ui/menus.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

void main() {
  for (final desktop in [true, false]) {
    testWidgets(
      'management cancel is harmless and typed confirmation deletes last vault without recreating it desktop=$desktop',
      (tester) async {
        tester.view.physicalSize = desktop
            ? const Size(1280, 900)
            : const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        late Directory dir;
        late Notebook repo;
        await tester.runAsync(() async {
          dir = Directory.systemTemp.createTempSync('delete-vault-ui-');
          repo = Notebook(
            storage: NativeStorage(dir.path),
            keys: MemoryKeys(),
            crypto: TestCrypto(),
          );
          await repo.initialize();
          await repo.createVault('Synthetic');
          await repo.createNote(repo.vaults.single.id);
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [notebookProvider.overrideWithValue(repo)],
            child: const SiliqueApp(),
          ),
        );
        await tester.pumpAndSettle();
        Future<void> management() async {
          if (find
              .byType(SiliqueChoice<String?>)
              .hitTestable()
              .evaluate()
              .isEmpty) {
            await tester.tap(find.byTooltip('Foldery i vaulty'));
            await tester.pumpAndSettle();
          }
          await tester.tap(find.byType(SiliqueChoice<String?>));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Zarządzaj vaultami'));
          await tester.pumpAndSettle();
        }

        await management();
        expect(find.byTooltip('Usuń vault wraz z zawartością'), findsOneWidget);
        await tester.tap(find.byTooltip('Usuń vault wraz z zawartością'));
        await tester.pumpAndSettle();
        expect(find.text('Usunięcie jest nieodwracalne.'), findsOneWidget);
        await tester.tap(find.text('Anuluj'));
        await tester.pumpAndSettle();
        expect(repo.vaults, hasLength(1));
        expect(
          await tester.runAsync(() => repo.storage.deletionIntents()),
          isEmpty,
        );
        await management();
        await tester.tap(find.byTooltip('Usuń vault wraz z zawartością'));
        await tester.pumpAndSettle();
        final field = find.byKey(const ValueKey('vault-delete-name'));
        await tester.enterText(field, ' Synthetic');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(repo.vaults, hasLength(1));
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('vault-delete-confirm')),
              )
              .onPressed,
          isNull,
        );
        await tester.enterText(field, 'Synthetic');
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('vault-delete-confirm')));
        for (var i = 0; i < 35 && repo.vaults.isNotEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();
        expect(repo.vaults, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        final close = repo.close();
        await tester.pump();
        await tester.runAsync(() => close);
        dir.deleteSync(recursive: true);
      },
    );
  }
}
