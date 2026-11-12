import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/credential_mode.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/credential_files.dart';
import 'package:silique/storage/credential_startup.dart';
import 'package:silique/storage/managed_keys.dart';
import 'package:silique/core/server_trust.dart';
import 'package:silique/storage/startup_notebook.dart';

class _SystemKeys implements SystemCredentialBackend {
  final values = <String, String>{};
  var calls = 0;
  @override
  Future<String?> read(String key) async {
    calls++;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    calls++;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    calls++;
    values.remove(key);
  }

  @override
  Future<Map<String, String>> snapshot() async {
    calls++;
    return {...values};
  }

  @override
  Future<void> replace(Map<String, String> next) async {
    calls++;
    values
      ..clear()
      ..addAll(next);
  }

  @override
  Future<void> clear() async {
    calls++;
    values.clear();
  }
}

void main() {
  test('real notebook retains keys, notes and hidden-password boundary across both modes', () async {
    // /var is a symlink on macOS; the native walker refuses symlinked
    // components, so the fixture must start from a canonical path.
    final temporary = Directory(
      Directory.systemTemp
          .createTempSync('silique-credential-notebook-')
          .resolveSymbolicLinksSync(),
    );
    final root = '${temporary.path}/notes';
    final credentialDirectory = Directory('${temporary.path}/credentials');
    final system = _SystemKeys();
    ManagedKeys make() => ManagedKeys(
      files: NativeCredentialFiles(credentialDirectory),
      system: system,
    );
    var keys = make();
    Notebook? notebook;
    addTearDown(() async {
      await notebook?.close();
      temporary.deleteSync(recursive: true);
    });
    await keys.initialize(firstRunMode: CredentialMode.local);
    notebook = await openStartupNotebook(root, keys: keys, trustStore: InMemoryTrustStore());
    await notebook.createVault('Synthetic ordinary vault');
    final vaultId = notebook.vaults.single.id;
    final note = await notebook.createNote(vaultId);
    await notebook.save(
      note.copyWith(
        title: 'Synthetic note',
        body: 'Retained across credential placement',
      ),
    );
    await notebook.setHiddenPassword('synthetic hidden password');
    final hidden = await notebook.createHiddenNote(vaultId);
    await notebook.save(
      hidden.copyWith(title: 'Synthetic hidden', body: 'Hidden sentinel'),
    );
    await keys.write(
      'nova.account.inactive-fixture',
      'synthetic inactive account key',
    );
    final installationKey = await keys.read('nova.localKey');
    final identityKeys = await keys.read('nova.deviceName');
    final initialSystemCalls = system.calls;
    await notebook.close();
    notebook = null;

    // Simulate upgrading a real local-mode Android notebook. Merely checking
    // or declining the one-time offer must not access the system backend.
    keys = make();
    CredentialStartupPolicy policy() => CredentialStartupPolicy(
      files: NativeCredentialFiles(credentialDirectory),
      platform: TargetPlatform.android,
    );
    await policy().initialize(keys, requireExistingKey: true);
    expect(await policy().shouldOfferAndroidMigration(keys), isTrue);
    final originalLocal = await NativeCredentialFiles(credentialDirectory)
        .read(ManagedKeys.localFile);
    await policy().keepLocalCredentials();
    keys = make();
    await policy().initialize(keys, requireExistingKey: true);
    expect(await policy().shouldOfferAndroidMigration(keys), isFalse);
    expect(
      await NativeCredentialFiles(credentialDirectory)
          .read(ManagedKeys.localFile),
      originalLocal,
    );
    notebook = await openStartupNotebook(root, keys: keys, trustStore: InMemoryTrustStore());
    expect(
      system.calls,
      initialSystemCalls,
      reason: 'Normal local restart must not open the system keyring',
    );
    expect(keys.mode, CredentialMode.local);
    expect(await keys.read('nova.localKey'), installationKey);
    expect(
      notebook.notes[vaultId]![note.id]!.body,
      'Retained across credential placement',
    );
    expect(notebook.hiddenUnlocked, isFalse);
    expect(await notebook.unlockHidden('wrong synthetic password'), isFalse);
    expect(await notebook.unlockHidden('synthetic hidden password'), isTrue);
    expect(
      (await notebook.hiddenNotes(vaultId)).single.body,
      'Hidden sentinel',
    );

    await keys.changeMode(CredentialMode.system);
    expect(keys.cleanupPending, isFalse);
    expect(await policy().shouldOfferAndroidMigration(keys), isFalse);
    expect(
      await NativeCredentialFiles(credentialDirectory)
          .read(ManagedKeys.localFile),
      isNull,
    );
    expect(await keys.read('nova.localKey'), installationKey);
    expect(
      system.values['nova.account.inactive-fixture'],
      'synthetic inactive account key',
    );
    expect(await keys.read('nova.deviceName'), identityKeys);
    await notebook.close();
    notebook = null;
    keys = make();
    await keys.initialize(requireExistingKey: true);
    notebook = await openStartupNotebook(root, keys: keys, trustStore: InMemoryTrustStore());
    expect(keys.mode, CredentialMode.system);
    expect(notebook.notes[vaultId]![note.id]!.title, 'Synthetic note');
    expect(notebook.hiddenUnlocked, isFalse);
    await keys.changeMode(CredentialMode.local);
    expect(keys.cleanupPending, isFalse);
    expect(system.values, isEmpty);
    expect(await keys.read('nova.localKey'), installationKey);
    expect(
      await keys.read('nova.account.inactive-fixture'),
      'synthetic inactive account key',
    );
    final callsAfterMigration = system.calls;
    await keys.write('nova.lastVault', vaultId);
    await keys.read('nova.lastVault');
    expect(system.calls, callsAfterMigration);
  });
}
