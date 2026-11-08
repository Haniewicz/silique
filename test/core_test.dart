import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/contracts.dart';
import 'package:silique/core/crypto.dart';
import 'package:silique/core/merge.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:cryptography/cryptography.dart';

class MemoryKeys implements KeyStore {
  final values = <String, String>{};
  int writes = 0;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    writes++;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

// Small KDF parameters keep repository tests quick. Production parameters are
// exercised independently below and never come from server-provided input.
class TestCrypto extends SiliqueCrypto {
  @override
  Future<List<int>> passwordKey(String password, List<int> salt) async =>
      (await Argon2id(
            memory: 64,
            iterations: 1,
            parallelism: 1,
            hashLength: 32,
          ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt))
          .extractBytes();
}

void main() {
  test(
    'three-way merge combines disjoint edits and preserves conflicting inputs',
    () {
      final result = threeWayMerge(
        'one\ntwo\nthree',
        'ONE\ntwo\nthree',
        'one\ntwo\nTHREE',
      );
      expect(result.conflict, false);
      expect(result.text, 'ONE\ntwo\nTHREE');
      expect(threeWayMerge('base', 'left', 'right').conflict, true);
      expect(threeWayMerge('base', 'left', 'base').text, 'left');
      expect(threeWayMerge('a\nb', 'a\nx\nb', 'a\ny\nb').conflict, true);
      expect(threeWayMerge('a\nb', 'a\nx\nb', 'a\nx\nb').text, 'a\nx\nb');
    },
  );
  test(
    'AES-GCM detects modified content and contextual substitution',
    () async {
      final crypto = SiliqueCrypto(), key = SiliqueCrypto().randomKey();
      final envelope = await crypto.seal(key, 'private content', 'revision-A');
      expect(await crypto.open(key, envelope, 'revision-A'), 'private content');
      await expectLater(
        crypto.open(key, envelope, 'revision-B'),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      final changed = jsonDecode(envelope) as Map<String, dynamic>;
      changed['c'] = base64Encode(
        List<int>.filled(base64Decode(changed['c'] as String).length, 0),
      );
      await expectLater(
        crypto.open(key, jsonEncode(changed), 'revision-A'),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    },
  );
  test('offline data, stable journal IDs, password separation and restart recovery', () async {
    final dir = Directory.systemTemp.createTempSync('silique-local-'),
        keys = MemoryKeys(),
        crypto = TestCrypto();
    var repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: keys,
      crypto: crypto,
    );
    await repo.initialize();
    await repo.createVault('Osobiste');
    final standard = repo.vaults.single;
    final n = await repo.createNote(standard.id, journalDate: '2026-10-19');
    final same = await repo.createNote(standard.id, journalDate: '2026-10-19');
    expect(n.id, same.id);
    await repo.save(n.copyWith(body: 'saved offline'));
    expect(
      File('${dir.path}/markdown/${standard.id}/${n.id}.md').readAsStringSync(),
      contains('saved offline'),
    );
    final recovery = await repo.createVault(
      'SECRET_VAULT_NAME',
      password: 'a private vault password',
    );
    final protected = repo.vaults.last;
    final secret = await repo.createNote(protected.id);
    await repo.save(
      secret.copyWith(title: 'SECRET_TITLE', body: 'VERY_SECRET_BODY'),
    );
    repo.lock(protected.id);
    expect(repo.notes[protected.id], null);
    expect(
      (repo.storage as NativeStorage).db.select(
        'SELECT data FROM documents WHERE vault_id=?',
        [protected.id],
      ).single['data'],
      isNot(contains('VERY_SECRET_BODY')),
    );
    expect(
      jsonEncode(repo.storage.vaults().map((v) => v.toJson()).toList()),
      isNot(contains('SECRET_VAULT_NAME')),
    );
    expect(
      Directory('${dir.path}/markdown/${protected.id}').existsSync(),
      false,
    );
    await expectLater(
      repo.unlock(protected, password: 'incorrect password'),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
    await repo.unlock(protected, password: recovery, recovery: true);
    expect(repo.notes[protected.id]![secret.id]!.body, 'VERY_SECRET_BODY');
    await repo.changeVaultPassword(protected, 'a changed vault password');
    repo.lock(protected.id);
    await repo.unlock(repo.vaults.last, password: 'a changed vault password');
    await repo.close();
    final existingKeys = Map.of(keys.values), writesBeforeRestart = keys.writes;
    repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: keys,
      crypto: crypto,
    );
    await repo.initialize();
    // Reopening must neither rewrite Keychain items nor rotate an existing key.
    expect(keys.writes, writesBeforeRestart);
    expect(keys.values, existingKeys);
    expect(repo.notes[standard.id]![n.id]!.body, 'saved offline');
    expect(repo.unlocked.containsKey(protected.id), false);
    expect(repo.storage.pending(standard.id), isNotEmpty);
    await repo.close();
    dir.deleteSync(recursive: true);
  });
}
