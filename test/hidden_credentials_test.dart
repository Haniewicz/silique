import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

class _FailingKeys extends MemoryKeys {
  String? failSlot;
  Completer<void>? readingWrap, releaseWrap;
  @override
  Future<String?> read(String key) async {
    if (key == 'silique.hidden.wrap' && readingWrap != null) {
      readingWrap!.complete();
      await releaseWrap!.future;
    }
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    if (key == failSlot) throw StateError('Simulated keystore failure');
    await super.write(key, value);
  }
}

void main() {
  late Notebook repo;
  late _FailingKeys keys;
  late Directory dir;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('hidden-credentials-');
    keys = _FailingKeys();
    repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: keys,
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Private');
  });
  tearDown(() async {
    await repo.close();
    dir.deleteSync(recursive: true);
  });

  test(
    'background lock invalidates an initial password setup already queued',
    () async {
      final events = <bool>[];
      final sub = repo.hiddenStateChanges.listen(
        (_) => events.add(repo.hiddenUnlocked),
      );
      final gate = Completer<void>();
      final blocked = repo.serialized(() => gate.future);
      final creating = repo.setHiddenPassword('additional password');
      final locking = repo.lockHidden();
      gate.complete();
      await blocked;
      await creating;
      await locking;
      expect(events, isNot(contains(true)));
      expect(repo.hiddenPasswordSet, isTrue);
      expect(repo.hiddenUnlocked, isFalse);
      await sub.cancel();
    },
  );

  test(
    'lock during portable configuration preparation never reopens setup',
    () async {
      final events = <bool>[];
      final sub = repo.hiddenStateChanges.listen(
        (_) => events.add(repo.hiddenUnlocked),
      );
      keys.readingWrap = Completer<void>();
      keys.releaseWrap = Completer<void>();
      final setting = repo.setHiddenPassword('additional password');
      await keys.readingWrap!.future;
      final locking = repo.lockHidden();
      keys.releaseWrap!.complete();
      await setting;
      await locking;
      expect(events, isNot(contains(true)));
      expect(repo.hiddenUnlocked, isFalse);
      await sub.cancel();
    },
  );

  test('failed initial password setup is not mistaken for usable credentials after restart', () async {
    keys.failSlot = 'silique.hidden.wrap';
    await expectLater(
      repo.setHiddenPassword('additional password'),
      throwsStateError,
    );
    await repo.loadHiddenSettings();
    expect(repo.hiddenPasswordSet, isFalse);
    keys.failSlot = null;
    await repo.setHiddenPassword('additional password');
    await repo.lockHidden();
    expect(await repo.unlockHidden('additional password'), isTrue);
  });

  test(
    'default auto lock is five minutes and rejects nonpositive policies',
    () async {
      expect(repo.hiddenAutoLock, const Duration(minutes: 5));
      await expectLater(
        repo.setHiddenAutoLock(Duration.zero),
        throwsArgumentError,
      );
      await expectLater(
        repo.setHiddenAutoLock(const Duration(seconds: -1)),
        throwsArgumentError,
      );
    },
  );
}
