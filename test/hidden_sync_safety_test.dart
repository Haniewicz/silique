import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

class _GatedCrypto extends TestCrypto {
  Completer<void>? entered, release;
  String prefix = 'silique:2:note:';
  @override
  Future<String> seal(List<int> key, String plaintext, String context) async {
    if (entered != null && context.startsWith(prefix)) {
      entered!.complete();
      await release!.future;
    }
    return super.seal(key, plaintext, context);
  }
}

void main() {
  late Directory dir;
  late Notebook repo;
  late _GatedCrypto crypto;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('hidden-sync-safety-');
    crypto = _GatedCrypto();
    repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: crypto,
    );
    await repo.initialize();
    await repo.createVault('Safety');
    await repo.setHiddenPassword('additional password');
  });
  tearDown(() async {
    await repo.close();
    dir.deleteSync(recursive: true);
  });

  test(
    'lock during outer revision encryption rejects fresh hidden creation',
    () async {
      final vault = repo.vaults.single;
      vault.syncEnabled = true;
      repo.storage.putVault(vault);
      crypto.entered = Completer<void>();
      crypto.release = Completer<void>();
      final creating = repo.createHiddenNote(vault.id);
      final checked = expectLater(creating, throwsStateError);
      await crypto.entered!.future;
      final locking = repo.lockHidden();
      crypto.release!.complete();
      await checked;
      await locking;
      expect(repo.storage.documents('hidden:${vault.id}'), isEmpty);
      expect(repo.storage.pending(vault.id), isEmpty);
    },
  );

  test('oversized hidden sync payload fails explicitly without replacing durable content', () async {
    final vault = repo.vaults.single;
    vault.syncEnabled = true;
    repo.storage.putVault(vault);
    final note = await repo.createHiddenNote(vault.id);
    final before = repo.storage.documents('hidden:${vault.id}')[note.id];
    final revisions = repo.storage.revisions(vault.id).length;
    await expectLater(
      repo.save(note.copyWith(body: 'X' * 1300000)),
      throwsFormatException,
    );
    expect(repo.storage.documents('hidden:${vault.id}')[note.id], before);
    expect(repo.storage.revisions(vault.id), hasLength(revisions));
  });

  test(
    'lock during move routing encryption preserves the ordinary note',
    () async {
      final vault = repo.vaults.single;
      final note = await repo.createNote(vault.id);
      crypto.prefix = 'silique:1:hidden-index:';
      crypto.entered = Completer<void>();
      crypto.release = Completer<void>();
      final moving = repo.hideNote(note);
      final checked = expectLater(moving, throwsStateError);
      await crypto.entered!.future;
      final locking = repo.lockHidden();
      crypto.release!.complete();
      await checked;
      await locking;
      expect(repo.notes[vault.id]!.containsKey(note.id), isTrue);
      expect(repo.storage.documents('hidden:${vault.id}'), isEmpty);
    },
  );

  test(
    'local hidden permanent deletion removes its encrypted recovery copy',
    () async {
      final note = await repo.createHiddenNote(repo.vaults.single.id);
      await repo.save(note.copyWith(deleted: true));
      await repo.purgeNote(note.copyWith(deleted: true));
      expect(repo.storage.documents('hidden:${note.vaultId}'), isEmpty);
    },
  );
}
