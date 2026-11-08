import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/credential_mode.dart';
import 'package:silique/core/key_bundle.dart';
import 'package:silique/core/contracts.dart';
import 'package:silique/storage/credential_files.dart';
import 'package:silique/storage/managed_keys.dart';
import 'package:silique/storage/secure_keys.dart';

class _GateFiles implements CredentialFiles {
  final values = <String, String>{
    ManagedKeys.stateFile: jsonEncode({
      'version': 1,
      'active': 'system',
      'established': true,
    }),
  };
  Future<void> _tail = Future.value();
  bool held = false;

  @override
  Future<T> locked<T>(Future<T> Function() operation) {
    final result = _tail.then((_) async {
      held = true;
      try {
        return await operation();
      } finally {
        held = false;
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  Future<String?> read(String name) async => values[name];
  @override
  Future<void> write(String name, String value) async => values[name] = value;
  @override
  Future<void> remove(String name) async => values.remove(name);
}

class _CountingKeys implements SecureKeyCollection {
  final values = <String, String>{};
  int reads = 0, enumerations = 0, writes = 0, deletes = 0;
  bool deny = false, dropWrite = false, loseAcknowledgement = false;
  bool Function()? gateHeld;
  Completer<void>? readBarrier;
  Completer<void>? readStarted;
  void _check() {
    if (gateHeld != null) expect(gateHeld!(), isTrue);
    if (deny) throw StateError('Authorization denied');
  }

  @override
  Future<String?> read(String key) async {
    reads++;
    _check();
    readStarted?.complete();
    readStarted = null;
    await readBarrier?.future;
    return values[key];
  }

  @override
  Future<Map<String, String>> readAll() async {
    enumerations++;
    _check();
    return Map.of(values);
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    _check();
    if (!dropWrite) values[key] = value;
    if (loseAcknowledgement) {
      loseAcknowledgement = false;
      throw StateError('Lost acknowledgement');
    }
  }

  @override
  Future<void> delete(String key) async {
    deletes++;
    _check();
    values.remove(key);
  }
}

String _bundle(Map<String, String?> keys) =>
    jsonEncode({'version': 1, 'keys': keys});

// Synthetic transport only: the process test exercises the real credential
// gate, not Security.framework or a production plaintext credential backend.
class _SyntheticDiskPrimary implements KeyStore {
  _SyntheticDiskPrimary(this.file);
  final File file;
  int reads = 0;
  @override
  Future<String?> read(String key) async {
    expect(key, KeyBundle.slot);
    reads++;
    return file.readAsString();
  }

  @override
  Future<void> write(String key, String value) async {
    expect(key, KeyBundle.slot);
    await file.writeAsString(value, flush: true);
  }

  @override
  Future<void> delete(String key) async => file.delete();
}

void main() {
  registerCredentialScopeTests();
  registerHostProcessGateTests();
}

/// Scope contracts safe to register in the sandboxed native app as well as the
/// headless runner. Keep host subprocess creation in the separate registrar.
void registerCredentialScopeTests() {
  test(
    'scope drains an admitted read before releasing the native gate',
    () async {
      final files = _GateFiles();
      final started = Completer<void>(), release = Completer<void>();
      final primary = _CountingKeys()
        ..gateHeld = (() => files.held)
        ..values[KeyBundle.slot] = _bundle({'nova.localKey': 'master'})
        ..readStarted = started
        ..readBarrier = release;
      final system = SecureKeys.forBackend(
        legacy: _CountingKeys(),
        primary: primary,
      );
      late Future<String?> admitted;
      late Future<void> queued;
      final scope = files.locked(
        () => system.withCredentialScope(() async {
          admitted = system.read('nova.localKey');
          queued = system.write('nova.deviceName', 'queued-device');
          // Observe the error so a RED run reports the assertion, not an
          // unrelated unhandled-future failure.
          unawaited(queued.catchError((Object _) {}));
          await started.future;
          // Deliberately return with an admitted operation still in flight.
        }),
      );
      await started.future;
      await Future<void>.delayed(Duration.zero);
      try {
        expect(
          files.held,
          isTrue,
          reason: 'The gate must outlive every admitted native credential call',
        );
      } finally {
        release.complete();
        await scope;
        expect(await admitted, 'master');
        await queued;
      }
      expect(files.held, isFalse);
      expect(
        jsonDecode(primary.values[KeyBundle.slot]!)['keys']['nova.deviceName'],
        'queued-device',
      );
    },
  );

  test(
    'corrupt bundled reads redact plaintext and never consult legacy',
    () async {
      final files = _GateFiles();
      final legacy = _CountingKeys()
        ..values['nova.localKey'] = 'historical-master';
      final primary = _CountingKeys()
        ..values[KeyBundle.slot] =
            '{"nova.localKey":"synthetic-private-sentinel", broken';
      final keys = ManagedKeys(
        files: files,
        system: SecureKeys.forBackend(legacy: legacy, primary: primary),
      );
      await expectLater(
        keys.initialize(),
        throwsA(
          isA<FormatException>()
              .having((error) => error.source, 'source', isNull)
              .having(
                (error) => error.toString(),
                'message',
                isNot(contains('synthetic-private-sentinel')),
              ),
        ),
      );
      expect(legacy.reads, 0);
      expect(primary.writes, 0);
      expect(legacy.deletes, 0);
    },
  );

  test('existing startup checks only the bundled installation key', () async {
    final files = _GateFiles();
    final legacy = _CountingKeys()
      ..values.addAll({
        'nova.localKey': 'historical-master',
        'nova.account.inactive': 'historical-account',
        'nova.identity.inactive': 'historical-identity',
      });
    final primary = _CountingKeys()
      ..gateHeld = (() => files.held)
      ..values[KeyBundle.slot] = _bundle({
        'nova.localKey': 'synthetic-master',
        'nova.session': null,
      });
    final keys = ManagedKeys(
      files: files,
      system: SecureKeys.forBackend(legacy: legacy, primary: primary),
    );
    await keys.initialize(requireExistingKey: true);
    expect(
      legacy.enumerations,
      0,
      reason: 'Normal startup must not reread every preserved legacy item',
    );
    expect(primary.reads, 1);
    expect(primary.writes, 0);
    expect(legacy.values['nova.identity.inactive'], 'historical-identity');
  });

  test(
    'managed read loads the bundle once inside the cross-process gate',
    () async {
      final files = _GateFiles();
      final legacy = _CountingKeys();
      final primary = _CountingKeys()
        ..gateHeld = (() => files.held)
        ..values[KeyBundle.slot] = _bundle({
          'nova.localKey': 'synthetic-master',
          'nova.session': 'synthetic-session',
        });
      final keys = ManagedKeys(
        files: files,
        system: SecureKeys.forBackend(legacy: legacy, primary: primary),
      );
      await keys.initialize();
      primary.reads = 0;
      expect(await keys.read('nova.session'), 'synthetic-session');
      expect(
        primary.reads,
        1,
        reason: 'Validation and lookup must share one gate-scoped bundle load',
      );
      expect(legacy.reads, 0);
      expect(primary.writes, 0);
    },
  );

  test(
    'next gate reloads external changes and tombstones before mutations',
    () async {
      final files = _GateFiles();
      final legacy = _CountingKeys()..values['nova.session'] = 'stale-session';
      final primary = _CountingKeys()
        ..values[KeyBundle.slot] = _bundle({
          'nova.localKey': 'master',
          'nova.session': 'old-session',
        });
      final system = SecureKeys.forBackend(legacy: legacy, primary: primary);
      final keys = ManagedKeys(files: files, system: system);
      await keys.initialize();
      expect(await keys.read('nova.session'), 'old-session');
      await files.locked(() async {
        primary.values[KeyBundle.slot] = _bundle({
          'nova.localKey': 'master',
          'nova.session': null,
          'nova.identity.inactive': 'external-identity',
        });
      });
      expect(await keys.read('nova.session'), isNull);
      await keys.write('nova.deviceName', 'new-device');
      final stored = jsonDecode(primary.values[KeyBundle.slot]!)['keys'] as Map;
      expect(stored['nova.session'], isNull);
      expect(stored['nova.identity.inactive'], 'external-identity');
      expect(stored['nova.localKey'], 'master');
      expect(legacy.reads, 0);
      expect(legacy.values['nova.session'], 'stale-session');
    },
  );

  test(
    'warm authorization and corrupt bundle failures never become missing keys',
    () async {
      final files = _GateFiles();
      final legacy = _CountingKeys()..values['nova.localKey'] = 'legacy-master';
      final original = _bundle({
        'nova.localKey': 'master',
        'nova.session': 'session',
      });
      final primary = _CountingKeys()..values[KeyBundle.slot] = original;
      final keys = ManagedKeys(
        files: files,
        system: SecureKeys.forBackend(legacy: legacy, primary: primary),
      );
      await keys.initialize();
      expect(await keys.read('nova.session'), 'session');
      primary.deny = true;
      await expectLater(keys.read('nova.session'), throwsStateError);
      await expectLater(
        keys.write('nova.localKey', 'replacement'),
        throwsStateError,
      );
      primary.deny = false;
      for (final corrupt in [
        'broken',
        '[]',
        '{"version":2,"keys":{}}',
        '{"version":1,"keys":{"nova.localKey":17}}',
      ]) {
        primary.values[KeyBundle.slot] = corrupt;
        await expectLater(keys.read('nova.session'), throwsFormatException);
        await expectLater(
          keys.write('nova.localKey', 'replacement'),
          throwsFormatException,
        );
        expect(primary.values[KeyBundle.slot], corrupt);
      }
      primary.values[KeyBundle.slot] = _bundle({'nova.localKey': null});
      await expectLater(
        keys.write('nova.localKey', 'replacement'),
        throwsStateError,
      );
      expect(legacy.reads, 0);
      expect(primary.writes, 0);
      expect(primary.deletes, 0);
      primary.values[KeyBundle.slot] = original;
      expect(await keys.read('nova.localKey'), 'master');
    },
  );

  test(
    'failed writes invalidate the scoped cache without losing committed keys',
    () async {
      final files = _GateFiles();
      final legacy = _CountingKeys();
      final primary = _CountingKeys()
        ..values[KeyBundle.slot] = _bundle({'nova.localKey': 'master'});
      final system = SecureKeys.forBackend(legacy: legacy, primary: primary);
      final keys = ManagedKeys(files: files, system: system);
      await keys.initialize();
      primary.loseAcknowledgement = true;
      await expectLater(
        keys.write('nova.session', 'committed'),
        throwsStateError,
      );
      expect(await keys.read('nova.session'), 'committed');
      primary.dropWrite = true;
      await expectLater(
        keys.write('nova.session', 'dropped'),
        throwsStateError,
      );
      expect(await keys.read('nova.session'), 'committed');
      primary.dropWrite = false;
      await keys.write('nova.deviceName', 'device');
      expect(await keys.read('nova.localKey'), 'master');
      expect(legacy.writes, 0);
      expect(legacy.deletes, 0);
    },
  );

  test(
    'an error invalidates a warm cache inside the same still-open gate',
    () async {
      final files = _GateFiles();
      final primary = _CountingKeys()
        ..gateHeld = (() => files.held)
        ..values[KeyBundle.slot] = _bundle({
          'nova.localKey': 'master',
          'nova.session': 'old',
        });
      final system = SecureKeys.forBackend(
        legacy: _CountingKeys(),
        primary: primary,
      );
      await files.locked(
        () => system.withCredentialScope(() async {
          expect(await system.read('nova.session'), 'old');
          primary.loseAcknowledgement = true;
          await expectLater(
            system.write('nova.session', 'committed'),
            throwsStateError,
          );
          final readsBeforeRetry = primary.reads;
          expect(await system.read('nova.session'), 'committed');
          expect(primary.reads, greaterThan(readsBeforeRetry));
          expect(await system.read('nova.localKey'), 'master');
        }),
      );
    },
  );

  test(
    'queued managed reads cannot share a cache across gate acquisitions',
    () async {
      final files = _GateFiles();
      final primary = _CountingKeys()
        ..gateHeld = (() => files.held)
        ..values[KeyBundle.slot] = _bundle({
          'nova.localKey': 'master',
          'nova.session': 'session',
        });
      final keys = ManagedKeys(
        files: files,
        system: SecureKeys.forBackend(
          legacy: _CountingKeys(),
          primary: primary,
        ),
      );
      await keys.initialize();
      primary.reads = 0;
      final started = Completer<void>();
      final release = Completer<void>();
      primary.readStarted = started;
      primary.readBarrier = release;
      final first = keys.read('nova.session');
      await started.future;
      final second = keys.read('nova.session');
      await Future<void>.delayed(Duration.zero);
      expect(primary.reads, 1);
      release.complete();
      expect(await Future.wait([first, second]), ['session', 'session']);
      expect(primary.reads, 2);
    },
  );

  test('late callbacks cannot use an ended credential scope', () async {
    final files = _GateFiles();
    final primary = _CountingKeys()
      ..gateHeld = (() => files.held)
      ..values[KeyBundle.slot] = _bundle({'nova.localKey': 'master'});
    final system = SecureKeys.forBackend(
      legacy: _CountingKeys(),
      primary: primary,
    );
    late Future<String?> Function() lateRead;
    await files.locked(
      () => system.withCredentialScope(() async {
        expect(await system.read('nova.localKey'), 'master');
        lateRead = Zone.current.bindCallback(
          () => system.read('nova.localKey'),
        );
      }),
    );
    await expectLater(lateRead(), throwsStateError);
    expect(primary.reads, 1);
    await files.locked(() => system.read('nova.localKey'));
    expect(primary.reads, 2);
  });
}

/// Host-only regression: macOS App Sandbox cannot launch the Python contender.
/// The default `flutter test` run registers this real cross-process test before
/// CI runs the sandboxed integration target. Do not replace it with an in-process
/// fake, catch EPERM, or weaken the contention and next-acquisition assertions.
void registerHostProcessGateTests() {
  test(
    'real POSIX process gate fences a writer and reloads its next bundle',
    () async {
      if (!Platform.isLinux && !Platform.isMacOS) {
        markTestSkipped('Requires native POSIX flock and python3');
        return;
      }
      final python = await Process.run('python3', ['--version']);
      expect(python.exitCode, 0);
      final raw = await Directory.systemTemp.createTemp(
        'silique-keychain-gate-',
      );
      final root = Directory(await raw.resolveSymbolicLinks());
      addTearDown(() => root.delete(recursive: true));
      final files = NativeCredentialFiles(
        Directory('${root.path}/credentials'),
      );
      await files.write(
        ManagedKeys.stateFile,
        jsonEncode({'version': 1, 'active': 'system', 'established': true}),
      );
      final fixture = File('${root.path}/synthetic-bundle.json');
      await fixture.writeAsString(
        _bundle({'nova.localKey': 'master', 'nova.session': 'before'}),
      );
      final primary = _SyntheticDiskPrimary(fixture);
      final legacy = _CountingKeys()..values['nova.session'] = 'stale-session';
      final keys = ManagedKeys(
        files: files,
        system: SecureKeys.forBackend(legacy: legacy, primary: primary),
      );
      await keys.initialize(requireExistingKey: true);
      expect(await keys.read('nova.session'), 'before');
      late Process child;
      await files.locked(() async {
        child = await Process.start('python3', [
          '-c',
          r'''
import fcntl, json, os, sys
with open(sys.argv[1], 'r+b') as gate:
    try:
        fcntl.flock(gate, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print('blocked-by-credential-gate', flush=True)
    else:
        sys.exit('writer was not fenced by the credential gate')
    fcntl.flock(gate, fcntl.LOCK_EX)
    path = sys.argv[2]
    with open(path + '.next', 'w') as target:
        json.dump({'version': 1, 'keys': {
            'nova.localKey': 'master', 'nova.session': None,
            'nova.identity.inactive': 'external-identity'}}, target)
        target.flush()
        os.fsync(target.fileno())
    os.replace(path + '.next', path)
''',
          '${files.directory.path}/lock',
          fixture.path,
        ]);
        addTearDown(() => child.kill());
        expect(
          await child.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 10)),
          'blocked-by-credential-gate',
        );
      });
      final errors = child.stderr.transform(utf8.decoder).join();
      expect(
        await child.exitCode.timeout(const Duration(seconds: 10)),
        0,
        reason: await errors,
      );
      primary.reads = 0;
      expect(await keys.read('nova.session'), isNull);
      expect(primary.reads, 1);
      await keys.write('nova.deviceName', 'device');
      final stored = jsonDecode(await fixture.readAsString())['keys'] as Map;
      expect(stored['nova.identity.inactive'], 'external-identity');
      expect(stored['nova.localKey'], 'master');
      expect(stored['nova.session'], isNull);
      expect(legacy.reads, 0);
    },
  );
}
