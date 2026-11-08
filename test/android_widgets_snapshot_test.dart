import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/android_widgets.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<
    ({
      Notebook repo,
      AndroidWidgets bridge,
      List<MethodCall> calls,
      Directory dir,
    })
  >
  open() async {
    final dir = Directory.systemTemp.createTempSync('widget-snapshot-');
    final repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Ordinary');
    const channel = MethodChannel('silique.notes/widgets-snapshot-retain');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    final bridge = AndroidWidgets(
      notebook: repo,
      channel: channel,
      enabled: true,
    );
    addTearDown(() async {
      await bridge.dispose();
      await repo.close();
      dir.deleteSync(recursive: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    return (repo: repo, bridge: bridge, calls: calls, dir: dir);
  }

  bool cleared(List<MethodCall> calls) =>
      calls.any((c) => c.method == 'clearSnapshot');

  test(
    'locking the vault keeps the launcher list instead of demanding unlock',
    () async {
      final data = await open();
      final id = data.repo.vaults.single.id;
      final note = await data.repo.createNote(id);
      await data.repo.save(note.copyWith(title: 'Visible without unlock'));
      await data.bridge.refresh();
      expect(
        data.calls.where((c) => c.method == 'publishSnapshot'),
        hasLength(1),
      );
      final published = data.calls.length;
      data.repo.lock(id);
      await data.bridge.refresh();
      expect(
        cleared(data.calls),
        isFalse,
        reason:
            'a locked app must not wipe the launcher list it already published',
      );
      expect(
        data.calls.length,
        published,
        reason: 'nothing new may be published while the vault is locked',
      );
      expect(data.bridge.lastError, isNull);
    },
  );

  test(
    'hidden notes never enter the launcher snapshot, even when unlocked',
    () async {
      final data = await open();
      final id = data.repo.vaults.single.id;
      await data.repo.setHiddenPassword('synthetic hidden password');
      final hidden = await data.repo.createHiddenNote(id);
      await data.repo.save(
        hidden.copyWith(title: 'SECRET', body: 'SECRET body text'),
      );
      final ordinary = await data.repo.createNote(id);
      await data.repo.save(ordinary.copyWith(title: 'Ordinary', body: 'ok'));
      await data.bridge.refresh();
      final publish = data.calls.lastWhere(
        (c) => c.method == 'publishSnapshot',
      );
      final payload = publish.arguments as Map;
      final notes = (payload['notes'] as List).cast<Map>();
      expect(notes.map((n) => n['title']), ['Ordinary']);
      expect(publish.arguments.toString(), isNot(contains('SECRET')));
    },
  );

  test('whole vault deletion revokes retained native rows even with no unlocked accounts', () async {
    final data = await open();
    final vault = data.repo.vaults.single;
    await data.repo.createNote(vault.id);
    await data.bridge.start();
    data.calls.clear();
    await data.repo.deleteVault(vault, confirmation: 'Ordinary');
    expect(
      data.calls.any(
        (c) => c.method == 'removeVaultSnapshot' && c.arguments == vault.id,
      ),
      isTrue,
    );
    expect(data.repo.vaults, isEmpty);
  });

  test('widget actions cannot reopen an uncertain deletion target', () async {
    final data = await open();
    final vault = data.repo.vaults.single;
    final note = await data.repo.createNote(vault.id);
    data.repo.revokeVaultSnapshot = (_) async =>
        throw StateError('revocation failure');
    await expectLater(
      data.repo.deleteVault(vault, confirmation: vault.name),
      throwsStateError,
    );
    final action = WidgetAction(
      action: 'openNote',
      requestId: 'fixture',
      vaultId: vault.id,
      noteId: note.id,
    );
    expect(action.isEligible(data.repo), isFalse);
    expect(action.waitsForUnlock(data.repo), isFalse);
  });

  test('deleting every ordinary note clears the launcher list', () async {
    final data = await open();
    final id = data.repo.vaults.single.id;
    final note = await data.repo.createNote(id);
    await data.repo.save(note.copyWith(title: 'Temporary'));
    await data.bridge.refresh();
    data.calls.clear();
    await data.repo.save(
      data.repo.notes[id]![note.id]!.copyWith(deleted: true),
    );
    await data.bridge.refresh();
    expect(
      cleared(data.calls),
      isTrue,
      reason: 'an actually empty account must not leave stale rows behind',
    );
  });
}
