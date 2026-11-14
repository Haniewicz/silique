import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/l10n/app_language.dart';
import 'package:silique/l10n/strings.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_files.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/ui/vault_export_dialog.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

class _Storage extends NativeStorage {
  _Storage(super.root);
  @override
  Future<void> mirror(Note note) async {}
}

void main() {
  Future<Notebook> emptyNotebook(Directory root) async {
    final repo = Notebook(
      storage: _Storage('${root.path}/store'),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Local');
    return repo;
  }

  testWidgets(
    'vault export dialog shows title, hidden checkbox and desktop picker texts',
    (tester) async {
      currentLanguageCode = 'pl';
      final root = Directory.systemTemp.createTempSync('vault-export-ui-');
      final repo = await emptyNotebook(root);
      final vault = repo.vaults.single;
      await tester.pumpWidget(
        SiliqueMaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showVaultExportDialog(context, repo, vault),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Title and action labels are present.
      expect(find.text('Eksportuj vault'), findsOneWidget);
      expect(find.text('Eksportuj'), findsOneWidget);

      // Desktop destination picker is present (not the mobile ZIP description).
      expect(find.text('Wybierz katalog docelowy'), findsOneWidget);

      // No hidden password set -> checkbox is hidden.
      expect(find.byKey(const Key('include-hidden-notes')), findsNothing);

      await repo.close();
      root.deleteSync(recursive: true);
    },
  );

  testWidgets('vault export dialog honors the English locale', (tester) async {
    currentLanguageCode = 'en';
    final root = Directory.systemTemp.createTempSync('vault-export-ui-');
    final repo = await emptyNotebook(root);
    final vault = repo.vaults.single;
    await tester.pumpWidget(
      SiliqueMaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showVaultExportDialog(context, repo, vault),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Export vault'), findsOneWidget);
    expect(find.text('Export'), findsOneWidget);
    expect(find.text('Choose destination folder'), findsOneWidget);
    await repo.close();
    root.deleteSync(recursive: true);
  });

  testWidgets(
    'exporting without a directory fails fast, choosing a directory shows it',
    (tester) async {
      currentLanguageCode = 'pl';
      final root = Directory.systemTemp.createTempSync('vault-export-ui-');
      final destRoot = Directory.systemTemp.createTempSync('vault-export-dest-');
      final repo = await emptyNotebook(root);
      final vault = repo.vaults.single;

      await tester.pumpWidget(
        SiliqueMaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showVaultExportDialog(context, repo, vault),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // No destination chosen yet -> immediate, readable error, no filesystem
      // access and no busy spinner (so pumpAndSettle cannot hang).
      await tester.tap(find.byKey(const Key('confirm-vault-export')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vault-export-error')), findsOneWidget);
      expect(find.text('Wybierz katalog docelowy.'), findsOneWidget);

      // The picker seam feeds the destination into the dialog.
      debugExportDirectoryPicker = () async => destRoot.path;
      await tester.tap(find.byKey(const Key('choose-export-directory')));
      await tester.pumpAndSettle();
      expect(find.text(destRoot.path), findsOneWidget);

      debugExportDirectoryPicker = null;
      await repo.close();
      root.deleteSync(recursive: true);
      destRoot.deleteSync(recursive: true);
    },
  );
}