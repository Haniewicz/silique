// Only run on a disposable desktop with SILIQUE_ISOLATED_TEST=true.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:silique/core/contracts.dart';
import 'package:silique/main.dart';
import 'package:silique/l10n/app_language.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/services/app_updates.dart';
import 'package:silique/storage/native_crypto.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/storage/vault_import.dart';
import 'package:window_manager/window_manager.dart';
import 'package:silique/storage/native_window.dart';
import 'package:silique/storage/secure_keys.dart';

import '../test/storage_location_failure_test.dart' as location_failures;
import '../test/storage_open_failure_test.dart' as open_failures;
import '../test/native_storage_recovery_test.dart' as recovery_tests;
import '../test/storage_startup_journal_test.dart' as journal_tests;
import '../test/startup_activation_test.dart' as activation_tests;
import '../test/windows_storage_io_test.dart' as windows_io_tests;
import '../test/startup_stale_activation_test.dart' as stale_activation_tests;
import '../test/recovery_activation_fence_test.dart' as activation_fence_tests;
import '../test/update_quiescence_test.dart' as update_quiescence_tests;
import '../test/windows_handoff_test.dart' as windows_handoff_tests;

class _ScopedKeys implements KeyStore {
  _ScopedKeys(this.prefix);
  final String prefix;
  final _keys = const SecureKeys();
  final written = <String>{};
  @override
  Future<String?> read(String key) => _keys.read('$prefix.$key');
  @override
  Future<void> write(String key, String value) async {
    written.add(key);
    await _keys.write('$prefix.$key', value);
  }

  @override
  Future<void> delete(String key) => _keys.delete('$prefix.$key');
  Future<void> clear() async {
    for (final key in written) {
      await delete(key);
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // This native entry point registers legacy Polish-copy fixtures directly;
  // test/flutter_test_config.dart is not loaded for integration app targets.
  // Select their language explicitly without changing the production default.
  setUp(() => appLanguage.setLanguage('pl'));
  // Run the exact mkdir/probe regressions on Windows too. These inject only
  // denied OS operations; they do not enable/disable Defender or require admin.
  location_failures.main();
  // Run the exact WAL-refusal/reopen regressions on Windows as well: the same
  // injected OS boundary, but against the real Windows SQLite build.
  open_failures.main();
  recovery_tests.main();
  journal_tests.main();
  activation_tests.main();
  windows_io_tests.main();
  stale_activation_tests.main();
  activation_fence_tests.main();
  update_quiescence_tests.main();
  windows_handoff_tests.main();
  testWidgets('desktop native keys, SQLite, editor and protected vault reopen', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('SILIQUE_ISOLATED_TEST') ||
        !(Platform.isWindows || Platform.isLinux)) {
      fail(
        'Use an isolated Windows/Linux builder and SILIQUE_ISOLATED_TEST=true.',
      );
    }
    final root = await Directory.systemTemp.createTemp(
      'silique-desktop-smoke-',
    );
    final keys = _ScopedKeys(
      'silique-smoke-${DateTime.now().microsecondsSinceEpoch}',
    );
    // Match the picker path from the Documents report: a native Windows prefix
    // followed by forward-slash components. Use only this disposable fixture,
    // never the builder's actual Documents or Defender configuration.
    final chosen = Directory('${root.path}/Documents/Podfolder')
      ..createSync(recursive: true);
    final unrelated = File('${chosen.path}/keep.txt')
      ..writeAsStringSync('unrelated user file');
    final support = Directory('${root.path}/support')..createSync();
    final dataRoot = NativeStorage.prepareChosenRoot(chosen.path);
    NativeStorage.persistChosenRoot(support.path, dataRoot);
    final repo = Notebook(
      storage: NativeStorage(dataRoot),
      keys: keys,
      crypto: NativeCrypto(),
    );
    Notebook? reopened;
    var repoClosed = false;
    try {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Desktop storage test'))),
      );
      await tester.pumpAndSettle();
      await NativeWindow.initialize();
      expect(await windowManager.getTitleBarHeight(), greaterThan(0));
      final updater = AppUpdater();
      await updater.initialize();
      const expectedVersion = String.fromEnvironment(
        'SILIQUE_EXPECTED_VERSION',
      );
      const expectedBuild = int.fromEnvironment('SILIQUE_EXPECTED_BUILD');
      expect(expectedVersion, isNotEmpty);
      expect(expectedBuild, greaterThan(0));
      expect(updater.installed?.version, expectedVersion);
      expect(updater.installed?.build, expectedBuild);
      expect(updater.installed?.supported, false);
      updater.dispose();
      await repo.initialize();
      await repo.createVault('Desktop test');
      final vault = repo.vaults.single;
      await repo.createFolder(vault, 'Parent/Child');
      final note = await repo.createNote(vault.id, folder: 'Parent/Child');
      await repo.save(
        note.copyWith(
          title: 'Desktop test note',
          body: 'Persisted desktop body',
        ),
      );
      expect(
        File('$dataRoot/markdown/${vault.id}/${note.id}.md').readAsStringSync(),
        contains('Persisted desktop body'),
      );
      expect(NativeStorage.prepareChosenRoot(chosen.path), dataRoot);
      expect(unrelated.readAsStringSync(), 'unrelated user file');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [notebookProvider.overrideWithValue(repo)],
          child: const SiliqueApp(),
        ),
      );
      await tester.pumpAndSettle();
      tester.testTextInput.register();
      await tester.enterText(
        find.byKey(const Key('note-title')),
        'Desktop edited and saved',
      );
      await NativeWindow.instance.beforeClose!();
      await tester.pumpAndSettle();
      tester.testTextInput.unregister();
      expect(
        repo.storage.documents(vault.id)[note.id],
        contains('Desktop edited and saved'),
      );
      expect(await keys.read('nova.localKey'), isNotNull);
      final source = Directory('${root.path}/foreign-notes');
      await Directory('${source.path}/Child/Empty').create(recursive: true);
      await File('${source.path}/Original name.md')
          .writeAsString('Imported Windows body');
      await File('${source.path}/Child/Second.md')
          .writeAsString('![[Original name]]');
      final plan = await scanVaultImport(DirectoryImportSource(source.path));
      final imported = await repo.importVault(
        vault.id,
        plan,
        destination: 'Import',
      );
      expect(imported.notes.length, 2);
      expect(repo.allFolders(vault.id), contains('Import/Child/Empty'));
      expect(
        await File('${source.path}/Original name.md').readAsString(),
        'Imported Windows body',
      );
      await repo.createVault(
        'Protected desktop',
        password: 'isolated-desktop-passphrase-123',
      );
      final protected = repo.vaults.last;
      await repo.rememberVault(protected.id);
      final secret = await repo.createNote(protected.id);
      await repo.save(
        secret.copyWith(title: 'Protected', body: 'ENCRYPTED_DESKTOP_BODY'),
      );
      expect(
        repo.storage.documents(protected.id)[secret.id],
        isNot(contains('ENCRYPTED_DESKTOP_BODY')),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await repo.close();
      repoClosed = true;
      reopened = Notebook(
        storage: NativeStorage(NativeStorage.resolveRoot(support.path)),
        keys: keys,
        crypto: NativeCrypto(),
      );
      await reopened.initialize();
      expect(reopened.lastVaultId, protected.id);
      expect(reopened.allFolders(vault.id), contains('Import/Child/Empty'));
      expect(
        reopened.notes[vault.id]!.values
            .where((n) => n.title == 'Original name')
            .single
            .body,
        'Imported Windows body',
      );
      expect(
        reopened.notes[vault.id]![note.id]!.title,
        'Desktop edited and saved',
      );
      expect(reopened.notes[vault.id]![note.id]!.folder, 'Parent/Child');
      expect(reopened.unlocked.containsKey(protected.id), false);
      await reopened.unlock(
        reopened.vaults.firstWhere((v) => v.id == protected.id),
        password: 'isolated-desktop-passphrase-123',
      );
      expect(
        reopened.notes[protected.id]![secret.id]!.body,
        'ENCRYPTED_DESKTOP_BODY',
      );
    } finally {
      await tester.pumpWidget(const SizedBox());
      await reopened?.close();
      if (!repoClosed) await repo.close();
      await keys.clear();
      await root.delete(recursive: true);
    }
  });
}
