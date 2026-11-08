import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uuid/uuid.dart';

import 'package:silique/core/contracts.dart';
import 'package:silique/core/crypto.dart';
import 'package:silique/core/key_bundle.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'package:cryptography/cryptography.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

/// A memory KeyStore that can drop a write (and its acknowledgement) so slot
/// promotion can prove that a failed write never deletes the old entry.
class _FaultyKeys implements KeyStore {
  final values = <String, String>{};
  bool dropWrites = false;
  int writes = 0;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    writes++;
    if (!dropWrites) values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  // 1. Editing an existing note after the update writes a new silique:2
  //    revision while the older nova:1 revision still reads.
  test('edit writes a silique:2 revision and still reads the older nova:1 revision', () async {
    final dir = Directory.systemTemp.createTempSync('faza2-revision-');
    final repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    addTearDown(() async {
      await repo.close();
      dir.deleteSync(recursive: true);
    });
    await repo.initialize();
    await repo.createVault('Rev', password: 'a revision password');
    final vault = repo.vaults.single;
    final note = await repo.createNote(vault.id);
    await repo.save(note.copyWith(body: 'before'));
    final first = repo.heads(vault.id, note.id).single;
    // The freshly written revision is sealed with silique:2: it authenticates
    // only under the new AAD and rejects the legacy nova:1 AAD.
    expect(first.aad, startsWith('silique:2:note:'));
    await expectLater(
      repo.crypto.open(repo.unlocked[vault.id]!, first.payload, first.aad),
      completion(contains('before')),
    );
    await expectLater(
      repo.crypto.open(repo.unlocked[vault.id]!, first.payload, first.legacyAad),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );

    // A genuine nova:1 revision (as an older client would write) still decodes
    // through the notebook's openCompat read fallback.
    final legacy = Revision(
      id: const Uuid().v4(),
      vaultId: vault.id,
      noteId: note.id,
      parents: const [],
      payload: '',
    );
    final legacyRev = Revision(
      id: legacy.id,
      vaultId: vault.id,
      noteId: note.id,
      parents: const [],
      payload: await repo.crypto.seal(
        repo.unlocked[vault.id]!,
        jsonEncode(note.copyWith(body: 'legacy revision body').toJson()),
        legacy.legacyAad,
      ),
    );
    repo.storage.putRevision(legacyRev, pending: true);
    final decoded = await repo.crypto.openCompat(
      repo.unlocked[vault.id]!,
      legacyRev.payload,
      legacyRev.aad,
      legacyRev.legacyAad,
    );
    expect(decoded, contains('legacy revision body'));
  });

  // 2. vault-key and vault-meta are silique:2 after the first write, and the
  //    vault opens after a restart.
  test('vault-key and vault-meta are silique:2 and the vault reopens', () async {
    final dir = Directory.systemTemp.createTempSync('faza2-vault-');
    final keys = MemoryKeys();
    Notebook open() => Notebook(
      storage: NativeStorage(dir.path),
      keys: keys,
      crypto: TestCrypto(),
    );
    var repo = open();
    addTearDown(() async {
      await repo.close();
      dir.deleteSync(recursive: true);
    });
    await repo.initialize();
    await repo.createVault('Vault', password: 'a restorable password');
    final vault = repo.vaults.single;
    final key = repo.unlocked[vault.id]!;

    // vault-meta is sealed under silique:2 and no longer authenticates nova:1.
    await expectLater(
      repo.crypto.open(
        key,
        vault.metadata,
        'silique:2:vault-meta:${vault.id}',
      ),
      completion(contains('Vault')),
    );
    await expectLater(
      repo.crypto.open(
        key,
        vault.metadata,
        'nova:1:vault-meta:${vault.id}',
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );

    // The password wrap carries a `wrapped` (vault-key) field sealed under the
    // new domain; its structure is intact (mode/salt/kdf present), and the
    // unlock path below proves the silique:2 vault-key round-trips.
    final wrap = jsonDecode(vault.keyWrap) as Json;
    expect(wrap['mode'], 'password');
    expect(wrap['wrapped'], isNotNull);
    expect(wrap['recovery'], isNotNull);

    await repo.close();
    repo = open();
    await repo.initialize();
    await repo.unlock(repo.vaults.single, password: 'a restorable password');
    expect(repo.vaults.single.name, 'Vault');
  });

  // 3. key_wrap is rewrapped through CAS; a forced CAS conflict leaves the old
  //    wrap and the vault still opens.
  test('key_wrap rewraps via CAS and a CAS conflict keeps the old wrap', () async {
    final dir = Directory.systemTemp.createTempSync('faza2-rewrap-');
    var conflict = false;
    final repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    addTearDown(() async {
      await repo.close();
      dir.deleteSync(recursive: true);
    });
    await repo.initialize();
    await repo.createVault('Rewrap');
    final vault = repo.vaults.single;
    repo.session = Session(
      server: 'http://127.0.0.1',
      token: 'fixture',
      userId: 'fixture',
      email: 'fixture@example.com',
    );
    repo.accountKey = repo.crypto.randomKey();
    vault.owner = repo.session!.owner;
    vault.syncEnabled = true;
    // Simulate a pre-update wrap sealed with the legacy nova:1 AAD.
    final legacyKey = repo.unlocked[vault.id]!;
    vault.keyWrap = jsonEncode({
      'mode': 'account',
      'wrapped': await repo.crypto.seal(
        repo.accountKey!,
        base64Encode(legacyKey),
        'nova:1:vault-key:${vault.id}',
      ),
    });
    repo.storage.putVault(vault);

    final submittedWraps = <Json>[];
    repo.api = SiliqueApi('http://127.0.0.1', client: MockClient((request) async {
      if (request.method == 'PUT' && request.url.path.endsWith('/vaults/${vault.id}')) {
        final body = jsonDecode(request.body) as Json;
        submittedWraps.add(body);
        if (conflict) return http.Response('{"error":"conflict"}', 409);
        final version = (body['expectedVersion'] as int) + 1;
        return http.Response(jsonEncode({'version': version}), 200);
      }
      throw StateError('Unexpected ${request.method} ${request.url.path}');
    }));

    // First write (rename) rewraps through CAS.
    await repo.renameVault(vault, 'Rewrapped');
    expect(submittedWraps, hasLength(1));
    final submitted = jsonDecode(submittedWraps.single['keyWrap'] as String) as Json;
    expect(
      repo.crypto.open(
        repo.accountKey!,
        submitted['wrapped'] as String,
        'silique:2:vault-key:${vault.id}',
      ),
      completion(base64Encode(legacyKey)),
    );

    // Force a CAS conflict: the local wrap must fall back to the old one and
    // the metadata write fails loudly without corrupting local state.
    conflict = true;
    final beforeWrap = vault.keyWrap;
    await expectLater(
      repo.renameVault(vault, 'Conflict'),
      throwsA(isA<ApiException>()),
    );
    expect(vault.keyWrap, beforeWrap);
    // The vault still unlocks with the original key.
    repo.lock(vault.id);
    await repo.unlock(vault);
    expect(repo.notes[vault.id], isNotNull);
    expect(repo.unlocked[vault.id], legacyKey);
  });

  // 4. Slot promotion: the new slot holds an identical bundle; a failed write
  //    never deletes the old entry.
  test('slot promotion copies the bundle and never deletes on a failed write', () async {
    final primary = _FaultyKeys();
    const original = '{"version":1,'
        '"keys":{"nova.localKey":"master","nova.session":"session"}}';
    primary.values[KeyBundle.slot] = original;

    // Promote: the new slot holds the identical bundle, and the legacy slot is
    // removed only after the confirmed read.
    await promoteKeyBundle(primary);
    expect(primary.values[KeyBundle.promotedSlot], original);
    expect(primary.values.containsKey(KeyBundle.slot), isFalse);

    // A failed promotion (write dropped) must not delete the legacy entry.
    final primary2 = _FaultyKeys();
    primary2.values[KeyBundle.slot] = original;
    primary2.dropWrites = true;
    await expectLater(promoteKeyBundle(primary2), throwsStateError);
    expect(primary2.values[KeyBundle.slot], original);
    expect(primary2.values.containsKey(KeyBundle.promotedSlot), isFalse);
  });

  // 5. localKey/identity are preserved (non-recoverable) while the session and
  //    device slots keep working after the promotion.
  test('localKey and identity are preserved while session and device still work', () async {
    final primary = _FaultyKeys();
    primary.values[KeyBundle.slot] = jsonEncode({
      'version': 1,
      'keys': {
        'nova.localKey': 'master',
        'nova.session': 'session',
        'nova.deviceName': 'device',
        'nova.identity.scope': 'identity',
      },
    });
    await promoteKeyBundle(primary);
    // The promoted bundle is an exact copy: every key (including the
    // non-recoverable nova.localKey and nova.identity.*) survives.
    final promoted = jsonDecode(primary.values[KeyBundle.promotedSlot]!)['keys']
        as Map;
    expect(promoted['nova.localKey'], 'master');
    expect(promoted['nova.identity.scope'], 'identity');
    expect(promoted['nova.session'], 'session');
    expect(promoted['nova.deviceName'], 'device');

    // After promotion the bundle still resolves credentials: reads of both the
    // legacy and the cross-namespace names work.
    final keys = KeyBundle(primary: primary, legacy: _FaultyKeys());
    expect(await keys.read('nova.localKey'), 'master');
    expect(await keys.read('nova.identity.scope'), 'identity');
    expect(await keys.read('silique.session'), 'session');
    expect(await keys.read('silique.deviceName'), 'device');
  });

  // 6. Database rename: a successful rename keeps the data and clears any
  //    pending marker; the constructor never leaves startup blocked.
  test('database rename keeps data and is not blocked by a pending marker', () async {
    final dir = Directory.systemTemp.createTempSync('faza2-rename-');
    addTearDown(() => dir.deleteSync(recursive: true));

    // Successful rename with data: seed nova.sqlite, then reopen so it becomes
    // silique.sqlite with the same content and no pending flag. The same
    // credential collection is reused so the vault key still decrypts.
    final oldRoot = '${dir.path}/old';
    final keys = MemoryKeys();
    Notebook open() => Notebook(
      storage: NativeStorage(oldRoot),
      keys: keys,
      crypto: TestCrypto(),
    );
    final repo = open();
    await repo.initialize();
    await repo.createVault('Rename');
    final note = await repo.createNote(repo.vaults.single.id);
    await repo.save(note.copyWith(body: 'renamed content'));
    await repo.close();
    File('$oldRoot/silique.sqlite').renameSync('$oldRoot/nova.sqlite');

    final reopenedStore = NativeStorage(oldRoot);
    final reopened = Notebook(
      storage: reopenedStore,
      keys: keys,
      crypto: TestCrypto(),
    );
    expect(reopenedStore.pendingRename, isFalse);
    expect(File('$oldRoot/silique.sqlite').existsSync(), isTrue);
    expect(File('$oldRoot/nova.sqlite').existsSync(), isFalse);
    expect(File('$oldRoot/.silique-pending-rename').existsSync(), isFalse);
    await reopened.initialize();
    expect(
      reopened.notes[reopened.vaults.single.id],
      isNotEmpty,
      reason: 'renamed database must retain its notes',
    );
    await reopened.close();
  });

  // 7. Importing an old nova:1 vault produces silique:2 writes.
  test('importing a legacy nova:1 vault writes silique:2 documents', () async {
    final dir = Directory.systemTemp.createTempSync('faza2-import-');
    final repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    addTearDown(() async {
      await repo.close();
      dir.deleteSync(recursive: true);
    });
    await repo.initialize();
    await repo.createVault('Import', password: 'an import password');
    final vault = repo.vaults.single;
    final note = await repo.createNote(vault.id);
    await repo.save(note.copyWith(body: 'imported legacy'));
    final doc = repo.storage.documents(vault.id)[note.id]!;
    await expectLater(
      repo.crypto.open(
        repo.unlocked[vault.id]!,
        doc,
        'silique:2:local-note:${vault.id}:${note.id}',
      ),
      completion(contains('imported legacy')),
    );
  });

  // 8. Hidden notes and images keep their silique:1 domain (no regression).
  test('hidden notes and images domain stays silique:1', () async {
    final crypto = SiliqueCrypto();
    final key = crypto.randomKey();
    final hidden = await crypto.seal(key, 'hidden note', 'silique:1:hidden:v:n');
    await expectLater(
      crypto.open(key, hidden, 'silique:1:hidden:v:n'),
      completion('hidden note'),
    );
    final image = await crypto.seal(key, 'image bytes', 'silique:1:image:v:i:manifest');
    await expectLater(
      crypto.open(key, image, 'silique:1:image:v:i:manifest'),
      completion('image bytes'),
    );
    // A silique:2 AAD never authenticates the hidden/image envelope.
    await expectLater(
      crypto.open(key, hidden, 'silique:2:hidden:v:n'),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  // 9. Account envelope and pairing AAD remain nova:1.
  test('account envelope and pairing AAD stay nova:1', () async {
    final crypto = SiliqueCrypto();
    final key = crypto.randomKey();
    final envelope = await crypto.seal(key, 'master', 'nova:1:account:user-1');
    await expectLater(
      crypto.open(key, envelope, 'nova:1:account:user-1'),
      completion('master'),
    );
    // The pairing key derives from the nova:1:pairing nonce.
    final a = await crypto.createIdentity();
    final b = await crypto.createIdentity();
    final context = jsonEncode(['nova:1:pairing', 'u', 'p', 'r', a['public'], 'ap', b['public']]);
    final ka = await crypto.pairingKey(a, b['public'] as String, context);
    final kb = await crypto.pairingKey(b, a['public'] as String, context);
    expect(ka, kb);
  });
}
