import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

void main() {
  test('compact mode decode and merge follow the pure preference rules', () {
    expect(decodeCompactMode(null), isFalse);
    expect(decodeCompactMode('true'), isFalse);
    expect(decodeCompactMode(1), isFalse);
    expect(decodeCompactMode(true), isTrue);
    expect(
      mergeCompactMode(base: false, local: true, server: false),
      isTrue,
      reason: 'a local toggle survives an unchanged server copy',
    );
    expect(
      mergeCompactMode(base: false, local: false, server: true),
      isTrue,
      reason: 'a confirmed server change wins',
    );
    expect(mergeCompactMode(base: false, local: true, server: true), isTrue);
    expect(
      mergeCompactMode(base: true, local: false, server: true),
      isFalse,
      reason: 'a local removal wins over an unchanged server copy',
    );
    expect(
      mergeCompactMode(base: true, local: true, server: false),
      isFalse,
      reason: 'concurrent edits use the confirmed server value',
    );
  });

  test('SQLite compact mode is encrypted durable metadata and never rewrites note revisions', () async {
    final root = Directory.systemTemp.createTempSync('silique-compact-mode-');
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
    await repo.createVault('Compact', password: 'folder password 12345');
    var vault = repo.vaults.single;
    await repo.createFolder(vault, 'Alpha');
    final note = await repo.createNote(vault.id, folder: 'Alpha');
    await repo.save(note.copyWith(title: 'Compact sentinel'));
    final before = Map.of(repo.storage.documents(vault.id));
    final outbox = jsonEncode(
      repo.storage.pending(vault.id).map((r) => r.toWire()).toList(),
    );

    expect(repo.compactModeOf(vault.id), isFalse);
    expect(await repo.setCompactMode(vault, true), isTrue);
    expect(repo.compactModeOf(vault.id), isTrue);
    expect(
      await repo.setCompactMode(vault, true),
      isTrue,
      reason: 'setting the same value again is a no-op, not an error',
    );
    expect(repo.storage.documents(vault.id), before);
    expect(
      jsonEncode(
        repo.storage.pending(vault.id).map((r) => r.toWire()).toList(),
      ),
      outbox,
      reason: 'compact mode never rewrites note documents or revisions',
    );

    // The flag is sealed inside the vault metadata, and an unknown sibling
    // key survives together with it (same contract as folder order/colors).
    final metadata = jsonDecode(
      await crypto.open(
        repo.unlocked[vault.id]!,
        vault.metadata,
        'silique:2:vault-meta:${vault.id}',
      ),
    ) as Map<String, dynamic>;
    expect(metadata['compactMode'], isTrue);
    metadata['futureField'] = {
      'sentinel': [1, 'preserve'],
    };
    vault.metadata = await crypto.seal(
      repo.unlocked[vault.id]!,
      jsonEncode(metadata),
      'silique:2:vault-meta:${vault.id}',
    );
    repo.storage.putVault(vault);

    // The confirmed merge base carries the flag for the next sync.
    final base = jsonDecode(
      await crypto.open(
        repo.unlocked[vault.id]!,
        vault.folderBase,
        'silique:2:folder-base:${vault.id}',
      ),
    ) as Map;
    expect(decodeCompactMode(base['compactMode']), isTrue);

    // A locked vault reads as off and rejects the write.
    await repo.close();
    repo = make();
    await repo.initialize();
    vault = repo.vaults.single;
    expect(repo.unlocked, isNot(contains(vault.id)));
    expect(repo.compactModeOf(vault.id), isFalse);
    await expectLater(repo.setCompactMode(vault, true), throwsStateError);
    await repo.unlock(vault, password: 'folder password 12345');
    expect(
      repo.compactModeOf(vault.id),
      isTrue,
      reason: 'compact mode survives a Notebook restart through real SQLite',
    );
    final decoded = jsonDecode(
      await crypto.open(
        repo.unlocked[vault.id]!,
        vault.metadata,
        'silique:2:vault-meta:${vault.id}',
      ),
    ) as Map;
    expect(decoded['futureField'], metadata['futureField']);
    expect(repo.storage.documents(vault.id), before);
    expect(
      jsonEncode(
        repo.storage.pending(vault.id).map((r) => r.toWire()).toList(),
      ),
      outbox,
    );

    // Toggling back off round-trips through the same metadata path.
    expect(await repo.setCompactMode(vault, false), isTrue);
    expect(repo.compactModeOf(vault.id), isFalse);
    final cleared = jsonDecode(
      await crypto.open(
        repo.unlocked[vault.id]!,
        vault.metadata,
        'silique:2:vault-meta:${vault.id}',
      ),
    ) as Map;
    expect(cleared['compactMode'], isFalse);
    expect(cleared['futureField'], metadata['futureField']);
  });
}
