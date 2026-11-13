import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

void main() {
  test('appearance preferences stay as pending local edits without an owner session', () async {
    final root = Directory.systemTemp.createTempSync(
      'silique-offline-settings-',
    );
    final keys = MemoryKeys();
    final crypto = TestCrypto();
    Notebook make() =>
        Notebook(storage: NativeStorage(root.path), keys: keys, crypto: crypto);
    var repo = make();
    addTearDown(() async {
      await repo.close();
      root.deleteSync(recursive: true);
    });

    await repo.initialize();
    await repo.createVault('Appearance');
    var vault = repo.vaults.single;
    final vaultId = vault.id;
    await repo.createFolder(vault, 'Alpha');

    // A vault that belongs to an account, but this device has no owner
    // session (not logged in / expired). `api` stays null too.
    vault.owner = 'loopback.example|owner-1';
    vault.syncEnabled = true;
    repo.storage.putVault(vault);

    expect(repo.session, isNull);
    expect(repo.api, isNull);

    // Compact mode must not throw; the change stays local and unconfirmed.
    expect(
      await repo.setCompactMode(vault, true),
      isFalse,
      reason: 'a missing owner session is offline-tolerant, not an error',
    );
    expect(repo.compactModeOf(vaultId), isTrue);

    // A folder color rides the exact same metadata path, proving the fix is
    // the path's offline semantics, not a special case for one control.
    expect(await repo.setFolderColor(vault, 'Alpha', 0xFF0000FF), isFalse);
    expect(repo.folderColorsOf(vaultId)['Alpha'], 0xFF0000FF);

    // Durability: a fresh Notebook on the same storage still sees both
    // pending edits after the account-mode vault is auto-unlocked.
    await repo.close();
    repo = make();
    await repo.initialize();
    expect(repo.session, isNull);
    expect(repo.compactModeOf(vaultId), isTrue);
    expect(repo.folderColorsOf(vaultId)['Alpha'], 0xFF0000FF);

    // Negative control: rename is NOT offline-tolerant. The same state still
    // throws the owner-account StateError and restores the previous metadata.
    final renamed = repo.vaults.single;
    expect(renamed.name, 'Appearance');
    await expectLater(
      repo.renameVault(renamed, 'X'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'Połącz konto właściciela vaulta.',
        ),
      ),
    );
    expect(repo.vaults.single.name, 'Appearance');
    expect(repo.compactModeOf(vaultId), isTrue);
    expect(repo.folderColorsOf(vaultId)['Alpha'], 0xFF0000FF);
  });
}
