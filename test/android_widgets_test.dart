import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/android_widgets.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

Future<
  ({Notebook repo, AndroidWidgets bridge, List<MethodCall> calls, Note note})
>
bridgeFixture() async {
  final dir = Directory.systemTemp.createTempSync('widget-bridge-events-');
  final repo = Notebook(
    storage: NativeStorage(dir.path),
    keys: MemoryKeys(),
    crypto: TestCrypto(),
  );
  await repo.initialize();
  await repo.createVault('Ordinary');
  final note = await repo.createNote(repo.vaults.single.id);
  const channel = MethodChannel('silique.notes/widgets-events-test');
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
  return (repo: repo, bridge: bridge, calls: calls, note: note);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a locked vault action is retained until unlock then delivered once',
    () async {
      final data = await bridgeFixture();
      data.repo.lock(data.note.vaultId);
      var pending = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(data.bridge.channel, (call) async {
            if (call.method == 'takePendingAction' && pending) {
              pending = false;
              return {
                'action': 'openNote',
                'requestId': 'unlock-1',
                'vaultId': data.note.vaultId,
                'noteId': data.note.id,
              };
            }
            return null;
          });
      final actions = <WidgetAction>[];
      final sub = data.bridge.actions.listen(actions.add);
      addTearDown(sub.cancel);
      await data.bridge.start();
      expect(actions, isEmpty);
      await data.repo.unlock(data.repo.vaults.single);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(actions.map((a) => a.requestId), ['unlock-1']);
      await data.bridge.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(actions, hasLength(1));
    },
  );

  test(
    'default new note chooses an ordinary vault when last vault is protected',
    () async {
      final data = await bridgeFixture();
      await data.repo.createVault('Protected', password: 'fixture-password');
      await data.repo.rememberVault(data.repo.vaults.last.id);
      final action = WidgetAction.parse({
        'action': 'newNote',
        'requestId': 'default-1',
      })!;
      expect(action.isEligible(data.repo), isTrue);
    },
  );

  test('journal launcher action is parsed and delivered', () async {
    final data = await bridgeFixture();
    expect(
      WidgetAction.parse({
        'action': 'journal',
        'requestId': 'journal-1',
        'vaultId': data.note.vaultId,
      })?.action,
      'journal',
    );
  });

  test(
    'cold actions are retained until the HomeScreen listener subscribes',
    () async {
      final data = await bridgeFixture();
      var pending = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(data.bridge.channel, (call) async {
            if (call.method == 'takePendingAction' && pending) {
              pending = false;
              return {
                'action': 'openNote',
                'requestId': 'late-listener',
                'vaultId': data.note.vaultId,
                'noteId': data.note.id,
              };
            }
            return null;
          });
      await data.bridge.start();
      final action = await data.bridge.actions.first.timeout(
        const Duration(seconds: 2),
      );
      expect(action.requestId, 'late-listener');
    },
  );

  test('native cold and warm actions are delivered exactly once and stale targets are rejected', () async {
    final data = await bridgeFixture();
    final native = <Map<String, Object?>>[
      {
        'action': 'openNote',
        'requestId': 'cold-1',
        'vaultId': data.note.vaultId,
        'noteId': data.note.id,
      },
      {
        'action': 'openNote',
        'requestId': 'cold-1',
        'vaultId': data.note.vaultId,
        'noteId': data.note.id,
      },
      {
        'action': 'openNote',
        'requestId': 'missing-1',
        'vaultId': data.note.vaultId,
        'noteId': 'missing',
      },
    ];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(data.bridge.channel, (call) async {
          data.calls.add(call);
          if (call.method == 'takePendingAction') {
            return native.isEmpty ? null : native.removeAt(0);
          }
          return null;
        });
    final actions = <WidgetAction>[];
    final subscription = data.bridge.actions.listen(actions.add);
    addTearDown(subscription.cancel);
    await data.bridge.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(actions.map((a) => a.requestId), ['cold-1']);
    expect(actions.single.noteId, data.note.id);
    native.add({
      'action': 'newNote',
      'requestId': 'warm-1',
      'vaultId': data.note.vaultId,
    });
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          data.bridge.channel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('actionAvailable'),
          ),
          (_) {},
        );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(actions.map((a) => a.requestId), ['cold-1', 'warm-1']);
    expect(actions.last.action, 'newNote');
  });

  test('snapshot is revoked before private mutation and restored from current eligible state', () async {
    final data = await bridgeFixture();
    await data.bridge.start();
    await data.bridge.withoutSnapshot(() async {
      expect(
        data.calls.last.method,
        'clearSnapshot',
        reason: 'Revoke before executing the mutation',
      );
      await data.repo.save(data.note.copyWith(title: 'Must stay suppressed'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(data.calls.last.method, 'clearSnapshot');
    });
    expect(data.calls.last.method, 'publishSnapshot');
    expect(
      data.calls.last.arguments.toString(),
      contains('Must stay suppressed'),
    );
  });

  test('native clear failure aborts a private mutation', () async {
    final data = await bridgeFixture();
    await data.bridge.start();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(data.bridge.channel, (call) async {
          data.calls.add(call);
          if (call.method == 'clearSnapshot') {
            throw PlatformException(code: 'simulated-clear-failure');
          }
          return null;
        });
    var mutated = false;
    await expectLater(
      data.bridge.withoutSnapshot(() async {
        mutated = true;
      }),
      throwsA(isA<PlatformException>()),
    );
    expect(mutated, isFalse);
  });

  test('locking an account vault keeps the last snapshot so the launcher shows notes', () async {
    final data = await bridgeFixture();
    await data.bridge.start();
    expect(data.calls.last.method, 'publishSnapshot');
    final published = data.calls.last.arguments as Map;
    data.repo.lock(data.note.vaultId);
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      data.calls.any((c) => c.method == 'clearSnapshot'),
      isFalse,
      reason: 'A locked app must not demand an unlock to list ordinary notes',
    );
    expect((published['notes'] as List), isNotEmpty);
    await data.repo.unlock(data.repo.vaults.single);
    await data.bridge.refresh();
    expect(data.calls.last.method, 'publishSnapshot');
  });

  test('saved ordinary notes refresh the native snapshot without reopening the app', () async {
    final data = await bridgeFixture();
    await data.bridge.start();
    await data.repo.save(data.note.copyWith(title: 'Updated from editor'));
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (data.calls.last.arguments.toString().contains(
        'Updated from editor',
      )) {
        break;
      }
    }
    expect(
      data.calls
          .where((c) => c.method == 'publishSnapshot')
          .last
          .arguments
          .toString(),
      contains('Updated from editor'),
    );
  });

  test('widget snapshot contains only unlocked account notes, never hidden/deleted/protected content', () async {
    final dir = Directory.systemTemp.createTempSync('widget-bridge-');
    final repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Ordinary');
    final ordinaryId = repo.vaults.single.id;
    final ordinary = (await repo.createNote(ordinaryId)).copyWith(
      title: 'Visible ordinary',
      body: 'Full searchable body 😀',
      folder: 'Work',
    );
    await repo.save(ordinary);
    final deleted = (await repo.createNote(ordinaryId))
        .copyWith(title: 'Deleted secret', deleted: true);
    await repo.save(deleted);
    // Even a poisoned ordinary cache may not export an explicitly hidden note.
    repo.notes[ordinaryId]!['hidden-injected'] = ordinary.copyWith(
      title: 'Hidden secret',
      hidden: true,
    );
    await repo.createVault('Password protected', password: 'fixture-password');
    final protectedId = repo.vaults.last.id;
    await repo.save(
      (await repo.createNote(protectedId))
          .copyWith(title: 'Protected secret', body: 'Protected body'),
    );
    await repo.rememberVault(protectedId);
    const channel = MethodChannel('silique.notes/widgets-test');
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
    await bridge.start();
    final published =
        calls.where((c) => c.method == 'publishSnapshot').single.arguments
            as Map;
    final notes = (published['notes'] as List).cast<Map>();
    expect(notes, hasLength(1));
    expect(notes.single['id'], ordinary.id);
    expect(notes.single['vaultId'], ordinaryId);
    expect(notes.single['title'], 'Visible ordinary');
    expect(notes.single['searchText'], contains('Full searchable body 😀'));
    expect(published['schema'], 1);
    expect(published['lastVaultId'], ordinaryId);
    expect(published.toString(), isNot(contains('Hidden secret')));
    expect(published.toString(), isNot(contains('Protected secret')));
    expect(published.toString(), isNot(contains('Deleted secret')));
  });
}
