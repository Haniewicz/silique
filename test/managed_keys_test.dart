import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/credential_mode.dart';
import 'package:silique/storage/managed_keys.dart';
import 'package:silique/storage/secure_keys.dart';

class SimulatedCrash extends Error {}

class Boundaries {
  final trace = <String>[];
  int? crashAt;
  void hit(String label) {
    trace.add(label);
    if (trace.length == crashAt) throw SimulatedCrash();
  }
}

class MemoryFiles implements CredentialFiles {
  MemoryFiles([this.boundaries]);
  final Boundaries? boundaries;
  final values = <String, String>{};
  bool Function(String, String)? dropWrite;
  void Function(String, String)? beforeWrite;
  void Function(String, String)? afterWrite;
  bool dropRemove = false;
  Future<void> _tail = Future<void>.value();

  @override
  Future<T> locked<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  Future<String?> read(String name) async => values[name];
  @override
  Future<void> write(String name, String value) async {
    beforeWrite?.call(name, value);
    if (dropWrite?.call(name, value) != true) values[name] = value;
    afterWrite?.call(name, value);
    boundaries?.hit('write:$name');
  }

  @override
  Future<void> remove(String name) async {
    if (!dropRemove) values.remove(name);
    boundaries?.hit('remove:$name');
  }
}

class MemorySystem implements SystemCredentialBackend {
  MemorySystem([this.boundaries]);
  final Boundaries? boundaries;
  final values = <String, String>{};
  int calls = 0;
  bool denied = false;
  bool failCleanup = false;
  bool dropClear = false;
  bool omitSnapshotKey = false;
  bool partialReplace = false;

  void check() {
    calls++;
    if (denied) throw StateError('OS access denied');
  }

  @override
  Future<String?> read(String key) async {
    check();
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    check();
    values[key] = value;
    boundaries?.hit('system:write');
  }

  @override
  Future<void> delete(String key) async {
    check();
    values.remove(key);
    boundaries?.hit('system:delete');
  }

  @override
  Future<Map<String, String>> snapshot() async {
    check();
    final copy = Map.of(values);
    if (omitSnapshotKey) copy.remove('nova.localKey');
    return copy;
  }

  @override
  Future<void> replace(Map<String, String> entries) async {
    check();
    values.clear();
    boundaries?.hit('system:replace-clear');
    for (final entry in entries.entries) {
      values[entry.key] = entry.value;
      boundaries?.hit('system:replace-entry');
      if (partialReplace) break;
    }
  }

  @override
  Future<void> clear() async {
    check();
    if (failCleanup) throw StateError('Cleanup denied');
    if (!dropClear) values.clear();
    boundaries?.hit('system:clear');
  }
}

class _SystemCollection extends MemorySystem implements SecureKeyCollection {
  @override
  Future<Map<String, String>> readAll() => snapshot();
}

void main() {
  for (final operation in ['read', 'write', 'delete']) {
    test(
      'independent mac backends reload before $operation after a local round trip',
      () async {
        final files = MemoryFiles();
        final legacy = _SystemCollection()
          ..values.addAll({
            'nova.localKey': 'original',
            'nova.session': 'stale',
            'nova.deviceName': 'old-device',
          });
        final primary = _SystemCollection();
        SecureKeys backend() =>
            SecureKeys.forBackend(legacy: legacy, primary: primary);
        final firstBackend = backend();
        final first = ManagedKeys(files: files, system: firstBackend);
        final second = ManagedKeys(files: files, system: backend());
        await first.initialize();
        // Warm a distinct KeyBundle cache before the other controller migrates.
        expect(await first.read('nova.session'), 'stale');
        expect(await first.read('nova.deviceName'), 'old-device');
        await second.initialize();
        await second.changeMode(CredentialMode.local);
        await second.write('nova.session', 'latest');
        await second.write('nova.identity.inactive', 'new-identity');
        await second.delete('nova.deviceName');
        await second.changeMode(CredentialMode.system);

        switch (operation) {
          case 'read':
            expect(await first.read('nova.session'), 'latest');
            expect(await first.read('nova.deviceName'), isNull);
          case 'write':
            await first.write('nova.lastVault', 'new-vault');
          case 'delete':
            await first.delete('nova.session');
        }
        expect(await firstBackend.snapshot(), {
          'nova.localKey': 'original',
          if (operation != 'delete') 'nova.session': 'latest',
          'nova.identity.inactive': 'new-identity',
          if (operation == 'write') 'nova.lastVault': 'new-vault',
        });
      },
    );
  }

  test('interrupted first key creation is either committed or fenced against regeneration', () async {
    for (final mode in CredentialMode.values) {
      for (final crashAt in [1, 2]) {
        final boundaries = Boundaries();
        final files = MemoryFiles(boundaries);
        final system = MemorySystem(boundaries);
        final keys = ManagedKeys(files: files, system: system);
        await keys.initialize(firstRunMode: mode);
        boundaries.trace.clear();
        boundaries.crashAt = crashAt;
        await expectLater(
          keys.write('nova.localKey', 'first'),
          throwsA(isA<SimulatedCrash>()),
        );
        boundaries.crashAt = null;
        final reopened = ManagedKeys(files: files, system: system);
        if (crashAt == 1) {
          await expectLater(reopened.initialize(), throwsA(isA<StateError>()));
          await expectLater(
            reopened.write('nova.localKey', 'replacement'),
            throwsA(isA<StateError>()),
          );
        } else {
          await reopened.initialize(requireExistingKey: true);
          expect(await reopened.read('nova.localKey'), 'first');
        }
      }
    }
  });

  test(
    'first-run local migration restarts safely after every durable boundary',
    () async {
      final baseline = Boundaries();
      final baseFiles = MemoryFiles(baseline);
      final baseSystem = MemorySystem(baseline)
        ..values['nova.localKey'] = 'original';
      await ManagedKeys(
        files: baseFiles,
        system: baseSystem,
      ).initialize(firstRunMode: CredentialMode.local);
      for (var boundary = 1; boundary <= baseline.trace.length; boundary++) {
        final faults = Boundaries()..crashAt = boundary;
        final files = MemoryFiles(faults);
        final system = MemorySystem(faults)
          ..values['nova.localKey'] = 'original';
        await expectLater(
          ManagedKeys(
            files: files,
            system: system,
          ).initialize(firstRunMode: CredentialMode.local),
          throwsA(isA<SimulatedCrash>()),
        );
        faults.crashAt = null;
        final keys = ManagedKeys(files: files, system: system);
        await keys.initialize(requireExistingKey: true);
        expect(keys.mode, CredentialMode.local, reason: 'boundary $boundary');
        if (keys.cleanupPending) await keys.retryCleanup();
        expect(await keys.read('nova.localKey'), 'original');
        expect(system.values, isEmpty);
        expect(keys.cleanupPending, isFalse);
      }
    },
  );

  test('invalid initial credential choices fail closed before touching either collection', () async {
    for (final state in [
      {'active': 'system', 'initialChoice': 'cloud'},
      {'active': 'system', 'initialChoice': null},
      {'active': 'local', 'initialChoice': 'local'},
      {
        'active': 'system',
        'initialChoice': 'local',
        'pending': {'from': 'local', 'to': 'system', 'phase': 'cleanup'},
      },
    ]) {
      final files = MemoryFiles()
        ..values.addAll({
          ManagedKeys.stateFile: jsonEncode({
            'version': 1,
            'established': false,
            ...state,
          }),
          ManagedKeys.localFile: '{"nova.localKey":"original"}',
        });
      final before = Map.of(files.values);
      final system = MemorySystem()..denied = true;
      final keys = ManagedKeys(files: files, system: system);
      await expectLater(keys.initialize(), throwsStateError, reason: '$state');
      expect(files.values, before);
      expect(system.calls, 0);
    }
  });

  test(
    'denied or incomplete targets never cause a source fallback or retirement',
    () async {
      for (final failure in [
        'denied system',
        'partial system',
        'dropped local',
      ]) {
        final files = MemoryFiles();
        final system = MemorySystem()
          ..values.addAll({
            'nova.localKey': 'original',
            'hidden.wrap': 'preserved',
          });
        var keys = ManagedKeys(files: files, system: system);
        final source = failure == 'dropped local'
            ? CredentialMode.system
            : CredentialMode.local;
        final target = source == CredentialMode.system
            ? CredentialMode.local
            : CredentialMode.system;
        await keys.initialize(firstRunMode: source);
        system.denied = failure == 'denied system';
        system.partialReplace = failure == 'partial system';
        files.dropWrite = (name, _) =>
            failure == 'dropped local' && name == ManagedKeys.localFile;
        await expectLater(keys.changeMode(target), throwsA(isA<StateError>()));
        expect(keys.mode, source);
        expect(keys.cleanupPending, isTrue);
        keys = ManagedKeys(files: files, system: system);
        final calls = system.calls;
        await keys.initialize(requireExistingKey: true);
        if (source == CredentialMode.local) expect(system.calls, calls);
        await expectLater(
          keys.read('nova.localKey'),
          throwsA(isA<StateError>()),
        );
        system.denied = false;
        system.partialReplace = false;
        files.dropWrite = null;
        await keys.retryCleanup();
        expect(await keys.read('nova.localKey'), 'original');
        expect(await keys.read('hidden.wrap'), 'preserved');
        await keys.changeMode(target);
        expect(await keys.read('hidden.wrap'), 'preserved');
      }
    },
  );

  test(
    'corrupt activated target never reads the retained source as fallback',
    () async {
      final files = MemoryFiles();
      final system = MemorySystem()..values['nova.localKey'] = 'original';
      final keys = ManagedKeys(files: files, system: system);
      await keys.initialize();
      system.failCleanup = true;
      await expectLater(
        keys.changeMode(CredentialMode.local),
        throwsA(isA<StateError>()),
      );
      files.values[ManagedKeys.localFile] = '{}';
      final calls = system.calls;
      await expectLater(keys.read('nova.localKey'), throwsA(isA<StateError>()));
      await expectLater(
        keys.write('nova.localKey', 'replacement'),
        throwsA(isA<StateError>()),
      );
      await expectLater(keys.retryCleanup(), throwsA(isA<StateError>()));
      expect(system.calls, calls);
      expect(system.values['nova.localKey'], 'original');
    },
  );

  test('shared file gate serializes both controllers mutations with both migrations', () async {
    final files = MemoryFiles();
    final system = MemorySystem()..values['nova.localKey'] = 'original';
    final first = ManagedKeys(files: files, system: system);
    final second = ManagedKeys(files: files, system: system);
    await first.initialize(firstRunMode: CredentialMode.local);
    await second.initialize();
    await Future.wait([
      first.write('before', 'retained'),
      second.changeMode(CredentialMode.system),
      first.write('after', 'retained too'),
      second.delete('before'),
      first.changeMode(CredentialMode.local),
      second.write('last', 'retained three'),
    ]);
    expect(await first.read('before'), isNull);
    expect(await first.read('after'), 'retained too');
    expect(await second.read('last'), 'retained three');
    expect(await second.read('nova.localKey'), 'original');
    expect(system.values, isEmpty);
    expect(first.mode, CredentialMode.local);
    expect(second.mode, CredentialMode.local);
  });

  test(
    'denied mode-less startup never silently creates local storage',
    () async {
      final files = MemoryFiles();
      final system = MemorySystem()..denied = true;
      final keys = ManagedKeys(files: files, system: system);
      await expectLater(keys.initialize(), throwsA(isA<StateError>()));
      expect(files.values, isEmpty);
      await expectLater(
        keys.write('nova.localKey', 'replacement'),
        throwsA(isA<StateError>()),
      );
    },
  );
  test(
    'dropped local mutations are detected rather than reported durable',
    () async {
      final files = MemoryFiles();
      final system = MemorySystem()..values['nova.localKey'] = 'original';
      final keys = ManagedKeys(files: files, system: system);
      await keys.initialize(firstRunMode: CredentialMode.local);
      await keys.write('session', 'old');
      files.dropWrite = (name, _) => name == ManagedKeys.localFile;
      await expectLater(
        keys.write('session', 'new'),
        throwsA(isA<StateError>()),
      );
      await expectLater(keys.delete('session'), throwsA(isA<StateError>()));
      expect(await keys.read('session'), 'old');
    },
  );
  test(
    'incomplete source snapshot cannot retire an established installation key',
    () async {
      final files = MemoryFiles();
      final system = MemorySystem()..values['nova.localKey'] = 'original';
      final keys = ManagedKeys(files: files, system: system);
      await keys.initialize();
      system.omitSnapshotKey = true;
      await expectLater(
        keys.changeMode(CredentialMode.local),
        throwsA(isA<StateError>()),
      );
      expect(keys.mode, CredentialMode.system);
      expect(system.values['nova.localKey'], 'original');
      system.omitSnapshotKey = false;
      await keys.retryCleanup();
      expect(await keys.read('nova.localKey'), 'original');
    },
  );
  test(
    'unacknowledged source deletion remains pending until verified cleanup',
    () async {
      for (final source in CredentialMode.values) {
        final target = source == CredentialMode.local
            ? CredentialMode.system
            : CredentialMode.local;
        final files = MemoryFiles();
        final system = MemorySystem()..values['nova.localKey'] = 'original';
        final keys = ManagedKeys(files: files, system: system);
        await keys.initialize(firstRunMode: source);
        files.dropRemove = true;
        system.dropClear = true;
        await expectLater(keys.changeMode(target), throwsA(isA<StateError>()));
        expect(keys.mode, target);
        expect(keys.cleanupPending, isTrue);
        expect(await keys.read('nova.localKey'), 'original');
        files.dropRemove = false;
        system.dropClear = false;
        await keys.retryCleanup();
        expect(keys.cleanupPending, isFalse);
        expect(await keys.read('nova.localKey'), 'original');
      }
    },
  );
  test('failed dropped and ack-lost activation never delete the authoritative source', () async {
    for (final source in CredentialMode.values) {
      final target = source == CredentialMode.local
          ? CredentialMode.system
          : CredentialMode.local;
      for (final failure in ['failed', 'dropped', 'ack-lost']) {
        final files = MemoryFiles();
        final system = MemorySystem()
          ..values.addAll({
            'nova.localKey': 'original',
            'hidden.wrap': 'private wrap',
          });
        var keys = ManagedKeys(files: files, system: system);
        await keys.initialize(firstRunMode: source);
        bool activation(String name, String value) =>
            name == ManagedKeys.stateFile &&
            (jsonDecode(value) as Map)['active'] == target.name &&
            ((jsonDecode(value) as Map)['pending'] as Map?)?['phase'] ==
                'cleanup';
        if (failure == 'failed') {
          files.beforeWrite = (name, value) {
            if (activation(name, value)) throw StateError('Failed replace');
          };
        } else if (failure == 'dropped') {
          files.dropWrite = activation;
        } else {
          files.afterWrite = (name, value) {
            if (activation(name, value)) {
              throw StateError('Lost acknowledgment');
            }
          };
        }
        await expectLater(
          keys.changeMode(target),
          throwsA(isA<StateError>()),
          reason: failure,
        );
        expect(
          keys.mode,
          failure == 'ack-lost' ? target : source,
          reason: failure,
        );
        expect(keys.cleanupPending, isTrue);
        final sourceValues = source == CredentialMode.local
            ? jsonDecode(files.values[ManagedKeys.localFile]!)
            : system.values;
        expect(sourceValues, {
          'nova.localKey': 'original',
          'hidden.wrap': 'private wrap',
        });
        files.beforeWrite = null;
        files.dropWrite = null;
        files.afterWrite = null;
        keys = ManagedKeys(files: files, system: system);
        await keys.initialize(requireExistingKey: true);
        await keys.retryCleanup();
        if (keys.mode != target) await keys.changeMode(target);
        expect(await keys.read('nova.localKey'), 'original');
        expect(await keys.read('hidden.wrap'), 'private wrap');
      }
    }
  });
  test('restart after every persistent migration boundary keeps exactly one authority', () async {
    for (final source in CredentialMode.values) {
      final target = source == CredentialMode.local
          ? CredentialMode.system
          : CredentialMode.local;
      final baseline = Boundaries();
      Future<(MemoryFiles, MemorySystem, ManagedKeys)> prepare(
        Boundaries boundaries,
      ) async {
        final files = MemoryFiles(boundaries);
        final system = MemorySystem(boundaries)
          ..values.addAll({
            'nova.localKey': 'original',
            'hidden.wrap': 'preserved',
            'inactive.account': 'retained',
          });
        final keys = ManagedKeys(files: files, system: system);
        await keys.initialize(firstRunMode: source);
        boundaries.trace.clear();
        return (files, system, keys);
      }

      final (_, _, normal) = await prepare(baseline);
      await normal.changeMode(target);
      expect(baseline.trace, isNotEmpty);
      for (var boundary = 1; boundary <= baseline.trace.length; boundary++) {
        final faults = Boundaries();
        final (files, system, keys) = await prepare(faults);
        faults.crashAt = boundary;
        await expectLater(
          keys.changeMode(target),
          throwsA(isA<SimulatedCrash>()),
        );
        faults.crashAt = null;
        final state = jsonDecode(files.values[ManagedKeys.stateFile]!) as Map;
        final active = CredentialMode.values.byName(state['active'] as String);
        final staging = (state['pending'] as Map?)?['phase'] == 'staging';
        final reopened = ManagedKeys(files: files, system: system);
        await reopened.initialize(requireExistingKey: true);
        expect(reopened.mode, active);
        if (staging) {
          await expectLater(
            reopened.read('nova.localKey'),
            throwsA(isA<StateError>()),
          );
          await expectLater(
            reopened.write('session', 'must not write'),
            throwsA(isA<StateError>()),
          );
          await expectLater(
            reopened.delete('hidden.wrap'),
            throwsA(isA<StateError>()),
          );
        } else {
          expect(await reopened.read('nova.localKey'), 'original');
          await reopened.write('session', 'latest');
        }
        if (reopened.cleanupPending) {
          await expectLater(
            reopened.changeMode(source),
            throwsA(isA<StateError>()),
          );
          await reopened.retryCleanup();
        }
        if (reopened.mode != target) await reopened.changeMode(target);
        expect(await reopened.read('nova.localKey'), 'original');
        expect(await reopened.read('hidden.wrap'), 'preserved');
        expect(await reopened.read('inactive.account'), 'retained');
        expect(await reopened.read('session'), staging ? isNull : 'latest');
        expect(reopened.cleanupPending, isFalse);
        if (target == CredentialMode.local) {
          expect(system.values, isEmpty);
        } else {
          expect(files.values.containsKey(ManagedKeys.localFile), isFalse);
        }
      }
    }
  });
  test('failed source cleanup leaves local active without OS calls until explicit retry', () async {
    final files = MemoryFiles();
    final system = MemorySystem()..values['nova.localKey'] = 'original';
    var keys = ManagedKeys(files: files, system: system);
    await keys.initialize();
    system.failCleanup = true;
    await expectLater(
      keys.changeMode(CredentialMode.local),
      throwsA(isA<StateError>()),
    );
    expect(keys.mode, CredentialMode.local);
    expect(keys.cleanupPending, isTrue);
    system.denied = true;
    final calls = system.calls;
    keys = ManagedKeys(files: files, system: system);
    await keys.initialize(requireExistingKey: true);
    expect(await keys.read('nova.localKey'), 'original');
    await keys.write('session', 'latest');
    await keys.delete('unused');
    await expectLater(
      keys.changeMode(CredentialMode.system),
      throwsA(isA<StateError>()),
    );
    expect(keys.mode, CredentialMode.local);
    expect(system.calls, calls);
    system.denied = false;
    system.failCleanup = false;
    await keys.retryCleanup();
    expect(keys.cleanupPending, isFalse);
    expect(system.values, isEmpty);
    await keys.changeMode(CredentialMode.system);
    expect(system.values, {'nova.localKey': 'original', 'session': 'latest'});
  });
  test('existing-key guard rejects empty recovery but permits genuinely new first write', () async {
    for (final mode in CredentialMode.values) {
      final files = MemoryFiles();
      final system = MemorySystem();
      var keys = ManagedKeys(files: files, system: system);
      await expectLater(
        keys.initialize(firstRunMode: mode, requireExistingKey: true),
        throwsA(isA<StateError>()),
      );
      expect(files.values, isEmpty);
      await keys.initialize(firstRunMode: mode);
      await keys.write('nova.localKey', 'first');
      await expectLater(
        keys.delete('nova.localKey'),
        throwsA(isA<StateError>()),
      );
      if (mode == CredentialMode.local) {
        files.values[ManagedKeys.localFile] = '{}';
      } else {
        system.values.clear();
      }
      keys = ManagedKeys(files: files, system: system);
      await expectLater(keys.initialize(), throwsA(isA<StateError>()));
    }
  });
  test('lost or corrupt authority fails closed without generating a replacement key', () async {
    for (final corruption in [
      'missing local',
      'bad local',
      'missing key',
      'bad state',
      'unknown mode',
      'missing state',
    ]) {
      final files = MemoryFiles();
      final system = MemorySystem()..values['nova.localKey'] = 'original';
      final keys = ManagedKeys(files: files, system: system);
      await keys.initialize(firstRunMode: CredentialMode.local);
      switch (corruption) {
        case 'missing local':
          files.values.remove(ManagedKeys.localFile);
        case 'bad local':
          files.values[ManagedKeys.localFile] = '{broken';
        case 'missing key':
          files.values[ManagedKeys.localFile] = '{}';
        case 'bad state':
          files.values[ManagedKeys.stateFile] = '{}';
        case 'unknown mode':
          files.values[ManagedKeys.stateFile] = jsonEncode({
            'version': 1,
            'active': 'cloud',
            'established': true,
          });
        case 'missing state':
          files.values.remove(ManagedKeys.stateFile);
      }
      system.denied = true;
      final calls = system.calls;
      final reopened = ManagedKeys(files: files, system: system);
      await expectLater(
        reopened.initialize(),
        throwsA(isA<StateError>()),
        reason: corruption,
      );
      expect(system.calls, calls, reason: corruption);
      await expectLater(
        reopened.write('nova.localKey', 'replacement'),
        throwsA(isA<StateError>()),
      );
    }
  });
  test('local choice migrates every credential and routes offline through restart and back', () async {
    final files = MemoryFiles();
    final collection = <String, String>{
      'nova.localKey': 'original',
      'hidden.password.wrap': ' nul\u0000 unicode 🔐\n',
      'account.inactive.key': '',
      'pair.identity': '{unchanged}',
    };
    final system = MemorySystem()..values.addAll(collection);
    var keys = ManagedKeys(files: files, system: system);
    await keys.initialize(firstRunMode: CredentialMode.local);
    expect(keys.mode, CredentialMode.local);
    expect(system.values, isEmpty);
    expect(keys.cleanupPending, isFalse);
    system.denied = true;
    final calls = system.calls;
    keys = ManagedKeys(files: files, system: system);
    await keys.initialize(requireExistingKey: true);
    for (final entry in collection.entries) {
      expect(await keys.read(entry.key), entry.value);
    }
    await keys.write('session', 'new');
    await keys.delete('session');
    await keys.write('session', 'latest');
    expect(system.calls, calls);
    system.denied = false;
    await keys.changeMode(CredentialMode.system);
    expect(keys.mode, CredentialMode.system);
    expect(system.values, {...collection, 'session': 'latest'});
    expect(files.values.containsKey(ManagedKeys.localFile), isFalse);
    keys = ManagedKeys(files: files, system: system);
    await keys.initialize(requireExistingKey: true);
    expect(
      await keys.read('hidden.password.wrap'),
      collection['hidden.password.wrap'],
    );
  });
  test(
    'mode-less installation stays system and preserves its existing key',
    () async {
      final files = MemoryFiles();
      final system = MemorySystem()..values['nova.localKey'] = 'original';
      final keys = ManagedKeys(files: files, system: system);
      await keys.initialize(requireExistingKey: true);
      expect(keys.mode, CredentialMode.system);
      expect(await keys.read('nova.localKey'), 'original');
      await keys.write('session', 'session bytes');
      expect(system.values['session'], 'session bytes');
      await keys.delete('session');
      expect(system.values.containsKey('session'), isFalse);
      expect(keys.cleanupPending, isFalse);
      expect(files.values.containsKey(ManagedKeys.stateFile), isTrue);
    },
  );
}
