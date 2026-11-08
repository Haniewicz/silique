import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/key_bundle.dart';
import 'package:silique/storage/secure_keys.dart';

class _Collection implements SecureKeyCollection {
  final values = <String, String>{};
  bool deny = false, dropWrites = false, dropDeletes = false;
  bool loseNextAcknowledgement = false, failNextRead = false;

  @override
  Future<Map<String, String>> readAll() async {
    if (deny) throw StateError('Access denied');
    return Map.of(values);
  }

  @override
  Future<String?> read(String key) async {
    if (failNextRead) {
      failNextRead = false;
      throw StateError('Lost acknowledgement');
    }
    if (deny) throw StateError('Access denied');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (deny) throw StateError('Access denied');
    if (!dropWrites) values[key] = value;
    if (loseNextAcknowledgement) {
      loseNextAcknowledgement = false;
      failNextRead = true;
    }
  }

  @override
  Future<void> delete(String key) async {
    if (deny) throw StateError('Access denied');
    if (!dropDeletes) values.remove(key);
  }
}

class _WindowsFile implements WindowsCredentialCiphertext {
  Uint8List? bytes;
  bool denyRead = false, denyWrite = false, dropWrites = false;
  int writes = 0;
  @override
  Future<T> locked<T>(Future<T> Function() operation) => operation();
  @override
  Future<Uint8List?> read() async {
    if (denyRead) throw StateError('Read denied');
    return bytes == null ? null : Uint8List.fromList(bytes!);
  }

  @override
  Future<void> write(Uint8List value) async {
    writes++;
    if (denyWrite) throw StateError('Write denied');
    if (!dropWrites) bytes = Uint8List.fromList(value);
  }
}

class _WindowsCodec implements WindowsCredentialCodec {
  bool denyDecode = false, denyEncode = false;
  @override
  Uint8List decrypt(Uint8List bytes) {
    if (denyDecode) throw StateError('DPAPI denied');
    return Uint8List.fromList(bytes.map((byte) => byte ^ 0x5a).toList());
  }

  @override
  Uint8List encrypt(Uint8List bytes) {
    if (denyEncode) throw StateError('DPAPI denied');
    return Uint8List.fromList(bytes.map((byte) => byte ^ 0x5a).toList());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'native Windows DPAPI round trip and corrupt-file preservation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'silique-system-keys-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final keys = SecureKeys.forBackend(
        legacy: WindowsSecureKeyCollection.inDirectory(directory),
      );
      await keys.write('nova.localKey', 'synthetic-test-master');
      expect(await keys.read('nova.localKey'), 'synthetic-test-master');
      final ciphertext = File('${directory.path}/flutter_secure_storage.dat');
      final encoded = await ciphertext.readAsBytes();
      expect(
        utf8.decode(encoded, allowMalformed: true),
        isNot(contains('synthetic-test-master')),
      );
      final reopened = SecureKeys.forBackend(
        legacy: WindowsSecureKeyCollection.inDirectory(directory),
      );
      expect(await reopened.snapshot(), {
        'nova.localKey': 'synthetic-test-master',
      });
      final corrupt = Uint8List.fromList([0, 1, 2, 3]);
      await ciphertext.writeAsBytes(corrupt, flush: true);
      await expectLater(reopened.read('nova.localKey'), throwsStateError);
      await expectLater(
        reopened.write('nova.localKey', 'replacement'),
        throwsStateError,
      );
      expect(await ciphertext.readAsBytes(), corrupt);
    },
    skip: !Platform.isWindows
        ? 'Requires native Windows DPAPI/filesystem'
        : false,
  );

  test(
    'Windows read DPAPI and encryption denial never destroy opaque ciphertext',
    () async {
      final file = _WindowsFile(), codec = _WindowsCodec();
      file.bytes = codec.encrypt(
        Uint8List.fromList(utf8.encode('{"nova.localKey":"master"}')),
      );
      final original = List<int>.of(file.bytes!);
      final keys = SecureKeys.forBackend(
        legacy: WindowsSecureKeyCollection.forBackend(file: file, codec: codec),
      );
      for (final failure in ['read', 'decrypt', 'encrypt', 'write']) {
        file.denyRead = failure == 'read';
        codec.denyDecode = failure == 'decrypt';
        codec.denyEncode = failure == 'encrypt';
        file.denyWrite = failure == 'write';
        await expectLater(
          keys.write('nova.localKey', 'replacement'),
          throwsStateError,
        );
        expect(file.bytes, original);
      }
      file.denyWrite = false;
      await keys.write('nova.session', 'session');
      expect(await keys.read('nova.localKey'), 'master');
    },
  );

  test(
    'Windows dropped writes are rejected rather than acknowledged',
    () async {
      final file = _WindowsFile(), codec = _WindowsCodec();
      file.bytes = codec.encrypt(
        Uint8List.fromList(utf8.encode('{"nova.localKey":"master"}')),
      );
      final original = List<int>.of(file.bytes!);
      final keys = SecureKeys.forBackend(
        legacy: WindowsSecureKeyCollection.forBackend(file: file, codec: codec),
      );
      file.dropWrites = true;
      await expectLater(
        keys.write('nova.session', 'session'),
        throwsStateError,
      );
      await expectLater(keys.delete('nova.localKey'), throwsStateError);
      expect(file.bytes, original);
      file.dropWrites = false;
      await keys.write('nova.session', 'session');
      expect(await keys.read('nova.session'), 'session');
    },
  );

  test('Windows corrupt decrypt and JSON errors preserve opaque bytes on every operation', () async {
    final codec = _WindowsCodec();
    for (final plaintext in [
      'not-json',
      '[]',
      '{"nova.localKey":17}',
      '{"nova.localKey":null}',
    ]) {
      final file = _WindowsFile()
        ..bytes = codec.encrypt(Uint8List.fromList(utf8.encode(plaintext)));
      final original = List<int>.of(file.bytes!);
      final keys = SecureKeys.forBackend(
        legacy: WindowsSecureKeyCollection.forBackend(file: file, codec: codec),
      );
      await expectLater(keys.read('nova.localKey'), throwsFormatException);
      await expectLater(keys.snapshot(), throwsFormatException);
      await expectLater(
        keys.write('nova.localKey', 'replacement'),
        throwsFormatException,
      );
      await expectLater(
        keys.replace({'nova.localKey': 'replacement'}),
        throwsFormatException,
      );
      await expectLater(keys.delete('nova.localKey'), throwsFormatException);
      await expectLater(keys.clear(), throwsFormatException);
      expect(file.bytes, original);
      expect(file.writes, 0);
    }
  });

  test('Windows adapter preserves the existing encrypted collection and foreign entries', () async {
    final file = _WindowsFile(), codec = _WindowsCodec();
    file.bytes = codec.encrypt(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({'nova.localKey': 'master', 'foreign.key': 'foreign'}),
        ),
      ),
    );
    final keys = SecureKeys.forBackend(
      legacy: WindowsSecureKeyCollection.forBackend(file: file, codec: codec),
    );
    expect(await keys.snapshot(), {'nova.localKey': 'master'});
    await keys.write('nova.session', 'session');
    expect(await keys.read('nova.localKey'), 'master');
    await keys.clear();
    expect(await keys.snapshot(), isEmpty);
    final raw = jsonDecode(utf8.decode(codec.decrypt(file.bytes!)));
    expect(raw, {'foreign.key': 'foreign'});
  });

  test(
    'Android disables destructive reset without changing storage namespaces',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final calls = <MethodCall>[];
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await const SecureKeys().read('nova.localKey');
      final options = (calls.single.arguments as Map)['options'] as Map;
      expect(options, {
        ...AndroidOptions.defaultOptions.toMap(),
        'resetOnError': 'false',
      });
    },
    skip: Platform.isWindows || Platform.isMacOS
        ? 'Host adapter uses native desktop credentials'
        : false,
  );

  test(
    'lost replacement acknowledgement reloads committed mac credentials',
    () async {
      final legacy = _Collection()..values['nova.localKey'] = 'old-master';
      final primary = _Collection();
      final keys = SecureKeys.forBackend(legacy: legacy, primary: primary);
      expect(await keys.read('nova.localKey'), 'old-master');
      primary.loseNextAcknowledgement = true;
      await expectLater(
        keys.replace({'nova.localKey': 'new-master'}),
        throwsStateError,
      );
      expect(await keys.read('nova.localKey'), 'new-master');
      await keys.write('nova.deviceName', 'device');
      expect(await keys.snapshot(), {
        'nova.localKey': 'new-master',
        'nova.deviceName': 'device',
      });
      expect(legacy.values['nova.localKey'], 'old-master');
      primary.dropWrites = true;
      await expectLater(
        keys.replace({'nova.localKey': 'not-written'}),
        throwsStateError,
      );
      expect(await keys.read('nova.localKey'), 'new-master');
      primary.dropWrites = false;
      await keys.replace({'nova.localKey': 'new-master'});
    },
  );

  test(
    'denied enumeration and primary access fail without replacing credentials',
    () async {
      for (final primary in [null, _Collection()]) {
        final legacy = _Collection()..values['nova.localKey'] = 'master';
        final keys = SecureKeys.forBackend(legacy: legacy, primary: primary);
        legacy.deny = true;
        await expectLater(keys.snapshot(), throwsStateError);
        await expectLater(
          keys.replace({'nova.localKey': 'replacement'}),
          throwsStateError,
        );
        await expectLater(keys.clear(), throwsStateError);
        legacy.deny = false;
        if (primary != null) {
          primary.deny = true;
          await expectLater(keys.snapshot(), throwsStateError);
          await expectLater(
            keys.replace({'nova.localKey': 'replacement'}),
            throwsStateError,
          );
          await expectLater(keys.clear(), throwsStateError);
          primary.deny = false;
          expect(primary.values, isEmpty);
        }
        expect(await keys.snapshot(), {'nova.localKey': 'master'});
        await keys.replace({'nova.localKey': 'master'});
      }
    },
  );

  test(
    'decode failures never include credential plaintext in their errors',
    () async {
      const corrupt = '{"nova.localKey":"synthetic-private-sentinel", broken';
      final primary = _Collection()..values[KeyBundle.slot] = corrupt;
      final codec = _WindowsCodec();
      final file = _WindowsFile()
        ..bytes = codec.encrypt(Uint8List.fromList(utf8.encode(corrupt)));
      final stores = [
        SecureKeys.forBackend(legacy: _Collection(), primary: primary),
        SecureKeys.forBackend(
          legacy: WindowsSecureKeyCollection.forBackend(
            file: file,
            codec: codec,
          ),
        ),
      ];
      for (final keys in stores) {
        await expectLater(
          keys.snapshot(),
          throwsA(
            isA<FormatException>()
                .having((e) => e.source, 'source', isNull)
                .having(
                  (e) => e.toString(),
                  'message',
                  isNot(contains('synthetic-private-sentinel')),
                ),
          ),
        );
      }
    },
  );

  test('replace snapshots its input before asynchronous staging', () async {
    final legacy = _Collection();
    final keys = SecureKeys.forBackend(legacy: legacy);
    final values = {'nova.localKey': 'master'};
    final staging = keys.replace(values);
    values.clear();
    values['foreign.key'] = 'forbidden';
    await staging;
    expect(await keys.snapshot(), {'nova.localKey': 'master'});
    expect(legacy.values.containsKey('foreign.key'), isFalse);
  });

  test('replace rejects foreign keys before any write', () async {
    for (final primary in [null, _Collection()]) {
      final legacy = _Collection()..values['nova.localKey'] = 'master';
      final keys = SecureKeys.forBackend(legacy: legacy, primary: primary);
      await expectLater(
        keys.replace({'foreign.key': 'forbidden'}),
        throwsArgumentError,
      );
      expect(legacy.values, {'nova.localKey': 'master'});
      expect(primary?.values ?? {}, isEmpty);
    }
  });

  test(
    'corrupt and unsupported bundles block snapshot replacement and cleanup',
    () async {
      for (final encoded in [
        'broken',
        jsonEncode({'version': 2, 'keys': {}}),
        jsonEncode({
          'version': 1,
          'keys': {'nova.localKey': 17},
        }),
        jsonEncode({'version': 1, 'keys': []}),
      ]) {
        final primary = _Collection()..values[KeyBundle.slot] = encoded;
        final legacy = _Collection()..values['nova.localKey'] = 'legacy';
        final keys = SecureKeys.forBackend(legacy: legacy, primary: primary);
        await expectLater(keys.snapshot(), throwsFormatException);
        await expectLater(
          keys.replace({'nova.localKey': 'replacement'}),
          throwsFormatException,
        );
        await expectLater(keys.clear(), throwsFormatException);
        expect(primary.values[KeyBundle.slot], encoded);
        expect(legacy.values, {'nova.localKey': 'legacy'});
      }
    },
  );

  test(
    'ordinary reads reload mac cache after replacement and cleanup',
    () async {
      final legacy = _Collection()..values['nova.localKey'] = 'old-master';
      final primary = _Collection();
      final keys = SecureKeys.forBackend(legacy: legacy, primary: primary);
      expect(await keys.read('nova.localKey'), 'old-master');
      expect(legacy.values['nova.localKey'], 'old-master');
      await keys.replace({'nova.localKey': 'new-master'});
      expect(await keys.read('nova.localKey'), 'new-master');
      await keys.clear();
      expect(await keys.read('nova.localKey'), isNull);
      await keys.write('nova.localKey', 'third-master');
      expect(await keys.read('nova.localKey'), 'third-master');
      await keys.delete('nova.localKey');
      expect(await keys.read('nova.localKey'), isNull);
    },
  );

  test('mac clear preserves foreign bundle values and tombstones', () async {
    final legacy = _Collection()
      ..values.addAll({'nova.session': 'stale', 'foreign.legacy': 'legacy'});
    final foreign = <String, String?>{
      'foreign.key': 'foreign',
      'foreign.deleted': null,
      'nova.account.': 'not-owned',
    };
    final primary = _Collection()
      ..values[KeyBundle.slot] = jsonEncode({
        'version': 1,
        'keys': {...foreign, 'nova.localKey': 'master', 'nova.session': null},
      });
    final keys = SecureKeys.forBackend(legacy: legacy, primary: primary);

    primary.dropWrites = true;
    primary.dropDeletes = true;
    await expectLater(keys.clear(), throwsStateError);
    expect(jsonDecode(primary.values[KeyBundle.slot]!)['keys'], {
      ...foreign,
      'nova.localKey': 'master',
      'nova.session': null,
    });
    primary.dropWrites = false;
    primary.dropDeletes = false;
    await keys.clear();

    expect(primary.values[KeyBundle.slot], isNotNull);
    expect(jsonDecode(primary.values[KeyBundle.slot]!), {
      'version': 1,
      'keys': foreign,
    });
    expect(legacy.values, {'foreign.legacy': 'legacy'});
    expect(await keys.snapshot(), isEmpty);
    await keys.clear();
    expect(jsonDecode(primary.values[KeyBundle.slot]!)['keys'], foreign);
  });

  test('mac clear retains tombstones until legacy cleanup verifies then deletes bundle', () async {
    final legacy = _Collection()
      ..values.addAll({
        'nova.session': 'stale',
        'nova.account.inactive': 'account',
        'foreign.key': 'foreign',
      });
    final primary = _Collection()
      ..values.addAll({
        KeyBundle.slot: jsonEncode({
          'version': 1,
          'keys': {'nova.session': null, 'nova.localKey': 'master'},
        }),
        'foreign.primary': 'foreign',
      });
    final keys = SecureKeys.forBackend(legacy: legacy, primary: primary);
    legacy.dropDeletes = true;
    await expectLater(keys.clear(), throwsStateError);
    expect(primary.values.containsKey(KeyBundle.slot), isTrue);
    expect((await keys.snapshot()).containsKey('nova.session'), isFalse);
    legacy.dropDeletes = false;
    primary.dropDeletes = true;
    await expectLater(keys.clear(), throwsStateError);
    primary.dropDeletes = false;
    await keys.clear();
    expect(primary.values, {'foreign.primary': 'foreign'});
    expect(legacy.values, {'foreign.key': 'foreign'});
    expect(await keys.snapshot(), isEmpty);
  });

  test(
    'clear removes only owned legacy entries and verifies deletion for retry',
    () async {
      final legacy = _Collection()
        ..values.addAll({
          'nova.localKey': 'master',
          'nova.account.inactive': 'account',
          'silique.hidden.wrap': 'wrap',
          'foreign.key': 'foreign',
        });
      final keys = SecureKeys.forBackend(legacy: legacy);
      legacy.dropDeletes = true;
      await expectLater(keys.clear(), throwsStateError);
      legacy.dropDeletes = false;
      await keys.clear();
      expect(legacy.values, {'foreign.key': 'foreign'});
      await keys.clear();
    },
  );

  test(
    'mac replace stages one bundle and suppresses every omitted legacy slot',
    () async {
      final legacy = _Collection()
        ..values.addAll({
          'nova.localKey': 'master',
          'nova.session': 'stale-session',
          'nova.account.inactive': 'old-account',
          'foreign.key': 'foreign',
        });
      final primary = _Collection()
        ..values[KeyBundle.slot] = jsonEncode({
          'version': 1,
          'keys': {
            'nova.identity.inactive': 'old-identity',
            'nova.session': null,
          },
        });
      final keys = SecureKeys.forBackend(legacy: legacy, primary: primary);
      final next = {
        'nova.localKey': 'master',
        'silique.hidden.wrap': 'password-wrap',
      };
      await keys.replace(next);
      expect(await keys.snapshot(), next);
      expect(legacy.values['nova.session'], 'stale-session');
      expect(legacy.values['nova.account.inactive'], 'old-account');
      final reopened = SecureKeys.forBackend(legacy: legacy, primary: primary);
      expect(await reopened.snapshot(), next);
    },
  );

  test(
    'replace rejects dropped writes and dropped stale-slot deletion',
    () async {
      final legacy = _Collection()..values['nova.localKey'] = 'old';
      final keys = SecureKeys.forBackend(legacy: legacy);
      legacy.dropWrites = true;
      await expectLater(
        keys.replace({'nova.localKey': 'new'}),
        throwsStateError,
      );
      expect(legacy.values['nova.localKey'], 'old');
      legacy.dropWrites = false;
      legacy.dropDeletes = true;
      await expectLater(keys.replace({}), throwsStateError);
      legacy.dropDeletes = false;
      await keys.replace({'nova.localKey': 'new'});
      expect(await keys.snapshot(), {'nova.localKey': 'new'});
    },
  );

  test(
    'replace verifies exact owned values without touching foreign keys',
    () async {
      final legacy = _Collection()
        ..values.addAll({
          'nova.localKey': 'master',
          'nova.session': 'old',
          'nova.account.inactive': 'inactive',
          'foreign.key': 'foreign',
        });
      final keys = SecureKeys.forBackend(legacy: legacy);
      final next = {
        'nova.localKey': 'master',
        'silique.hidden.wrap': 'unchanged-wrap',
      };
      await keys.replace(next);
      expect(await keys.snapshot(), next);
      expect(legacy.values, {...next, 'foreign.key': 'foreign'});
    },
  );

  test(
    'mac snapshot merges bundle over legacy including null tombstones',
    () async {
      final legacy = _Collection(), primary = _Collection();
      legacy.values.addAll({
        'nova.localKey': 'old-master',
        'nova.session': 'stale-session',
        'nova.account.inactive': 'inactive',
        'silique.hidden.wrap': 'wrap',
      });
      primary.values[KeyBundle.slot] = jsonEncode({
        'version': 1,
        'keys': {
          'nova.localKey': 'master',
          'nova.session': null,
          'nova.identity.inactive': 'identity',
          'foreign.key': 'foreign',
        },
      });
      final keys = SecureKeys.forBackend(legacy: legacy, primary: primary);
      expect(await keys.snapshot(), {
        'nova.localKey': 'master',
        'nova.account.inactive': 'inactive',
        'nova.identity.inactive': 'identity',
        'silique.hidden.wrap': 'wrap',
      });
      expect(legacy.values['nova.session'], 'stale-session');
    },
  );

  test(
    'snapshot includes inactive credentials but excludes foreign slots',
    () async {
      final legacy = _Collection();
      final owned = {
        'nova.localKey': 'master',
        'nova.session': 'session',
        'nova.account.inactive': 'account',
        'nova.identity.inactive': 'identity',
        'nova.deviceName': 'device',
        'nova.lastVault': 'vault',
        'silique.hidden.salt': 'salt',
        'silique.hidden.wrap': 'password-wrap',
        'silique.hidden.check': 'check',
        'silique.hidden.autoLock': '60',
        'silique.hidden.lockOnBackground': 'true',
      };
      legacy.values.addAll({
        ...owned,
        'foreign.key': 'foreign',
        'nova.account.': 'foreign',
        'silique.hidden.unknown': 'foreign',
      });
      final keys = SecureKeys.forBackend(legacy: legacy);
      expect(await keys.snapshot(), owned);
      expect(legacy.values.length, owned.length + 3);
    },
  );
}
