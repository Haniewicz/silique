import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/device_settings.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/ui/dialogs.dart';
import 'package:silique/ui/theme.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

String? choiceLabel(WidgetTester tester, String key) {
  return tester
      .widget<InputDecorator>(
        find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byType(InputDecorator),
        ),
      )
      .decoration
      .labelText;
}

void main() {
  testWidgets(
    'template pickers use InputDecoration and persist a subfolder selection',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('silique-settings-tpl-');
      late Notebook repo;
      late String subId;
      addTearDown(() async {
        await deviceSettings.setJournalTemplateId(null);
        await deviceSettings.setNoteTemplateId(null);
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      // The Notebook must be constructed inside runAsync: its serialization
      // tail future is zone-bound, and a fake-async-zone construction would
      // stall every serialized() operation (createVault, close, …).
      await tester.runAsync(() async {
        repo = Notebook(
          storage: NativeStorage(dir.path),
          keys: MemoryKeys(),
          crypto: TestCrypto(),
        );
        await repo.initialize();
        await repo.createVault('Vault');
        final vault = repo.vaults.single;
        final root = await repo.createNote(vault.id, folder: 'Szablony');
        await repo.save(root.copyWith(title: 'Spotkanie', body: 'root'));
        final sub = await repo.createNote(
          vault.id,
          folder: 'Szablony/Podfolder',
        );
        subId = sub.id;
        await repo.save(sub.copyWith(title: 'Codzienny', body: 'sub'));
      });
      final vault = repo.vaults.single;

      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: siliqueTheme(),
          home: Scaffold(
            body: Center(
              child: Dialog(
                insetPadding: const EdgeInsets.all(16),
                child: SettingsPanel(
                  notebook: repo,
                  vault: vault,
                  onChanged: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The standalone labels are gone; the InputDecoration carries them.
      expect(
        choiceLabel(tester, 'journal-template-select'),
        'Domyślny szablon wpisu',
      );
      expect(
        choiceLabel(tester, 'note-template-select'),
        'Domyślny szablon notatki',
      );

      // Open the journal picker and choose the subfolder template.
      await tester.tap(find.byKey(const Key('journal-template-select')));
      await tester.pumpAndSettle();
      // Both templates are listed; the subfolder one shows its relative path.
      expect(find.text('Spotkanie'), findsOneWidget);
      expect(find.text('Codzienny'), findsOneWidget);
      expect(find.text('Podfolder'), findsOneWidget);
      await tester.tap(find.text('Codzienny'));
      await tester.pumpAndSettle();
      expect(deviceSettings.journalTemplateId, subId);
      // The closed trigger stays one line: the relative path is menu-only.
      expect(find.text('Podfolder'), findsNothing);
      expect(find.text('Codzienny'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
