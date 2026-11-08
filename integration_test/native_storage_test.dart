import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:silique/main.dart' as app;
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_crypto.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/storage/secure_keys.dart';
import 'package:silique/ui/home.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native keystore, SQLite, autosave and protected vault survive reopening',
    (tester) async {
      // Keep synthetic enterText events separate from the emulator's real IME.
      // Native storage, keystore, crypto and HTTP remain the production adapters.
      tester.testTextInput.register();
      addTearDown(tester.testTextInput.unregister);
      Future<void> until(bool Function() ready) async {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!ready()) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Native operation did not finish within 30 seconds');
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
      }

      await app.main();
      await tester.pumpAndSettle();
      if (find.text('Rozpocznij lokalnie').evaluate().isNotEmpty) {
        await tester.tap(find.text('Rozpocznij lokalnie'));
        await until(() => find.text('Plan na tydzień').evaluate().isNotEmpty);
      }
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HomeScreen)),
      );
      final notebook = container.read(app.notebookProvider);
      expect(await const SecureKeys().read('nova.localKey'), isNotNull);
      const server = String.fromEnvironment('SILIQUE_SMOKE_SERVER');
      if (server.isNotEmpty) {
        final api = SiliqueApi(server);
        try {
          final health = await api.request('GET', '/health');
          expect(health['status'], 'ok');
          expect(health['protocol'], 1);
        } finally {
          api.close();
        }
      }
      final initial = notebook.notes[notebook.vaults.first.id]!.values
          .firstWhere((note) => !note.deleted);
      await tester.tap(find.text(initial.title).first);
      await tester.pumpAndSettle();
      final title = 'Natywny test ${DateTime.now().millisecondsSinceEpoch}';
      await tester.enterText(find.byKey(const Key('note-title')), title);
      final vault = notebook.vaults.first;
      await until(
        () => notebook.notes[vault.id]!.values.any((n) => n.title == title),
      );
      final saved = notebook.notes[vault.id]!.values.firstWhere(
        (n) => n.title == title,
      );
      expect(notebook.storage.documents(vault.id)[saved.id], contains(title));
      await tester.tap(find.byTooltip('Wróć do notatek'));
      await until(() => find.byKey(const Key('note-title')).evaluate().isEmpty);
      expect(notebook.notes[vault.id]![saved.id]!.title, title);
      expect(notebook.storage.documents(vault.id)[saved.id], contains(title));
      final root = (notebook.storage as NativeStorage).root;
      final recovery = await notebook.createVault(
        'Natywny chroniony vault',
        password: 'native secure password 12345',
      );
      expect(recovery, isNotNull);
      final protected = notebook.vaults.last;
      final secret = await notebook.createNote(protected.id);
      await notebook.save(
        secret.copyWith(
          title: 'PRIVATE_NATIVE_TITLE',
          body: 'PRIVATE_NATIVE_BODY',
        ),
      );
      final row = (notebook.storage as NativeStorage).db.select(
        'SELECT data FROM documents WHERE vault_id=?',
        [protected.id],
      ).single;
      expect(row['data'], isNot(contains('PRIVATE_NATIVE_BODY')));
      expect(notebook.storage.documents(vault.id)[saved.id], contains(title));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(notebook.storage.documents(vault.id)[saved.id], contains(title));
      await notebook.close();
      final reopened = Notebook(
        storage: NativeStorage(root),
        keys: const SecureKeys(),
        crypto: NativeCrypto(),
      );
      await reopened.initialize();
      expect(reopened.notes[vault.id]![saved.id]!.title, title);
      expect(reopened.unlocked.containsKey(protected.id), false);
      await reopened.unlock(
        reopened.vaults.firstWhere((v) => v.id == protected.id),
        password: 'native secure password 12345',
      );
      expect(
        reopened.notes[protected.id]![secret.id]!.body,
        'PRIVATE_NATIVE_BODY',
      );
      await reopened.close();
    },
  );
}
