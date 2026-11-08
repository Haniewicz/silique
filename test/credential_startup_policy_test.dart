import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/credential_mode.dart';
import 'package:silique/main.dart' show credentialStartupGate;
import 'package:silique/storage/credential_startup.dart';
import 'package:silique/storage/managed_keys.dart';
import 'package:silique/ui/android_credential_migration.dart';
import 'package:silique/ui/credential_recovery.dart';

class _System implements SystemCredentialBackend {
  final values = <String, String>{};
  bool failReplacement = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<Map<String, String>> snapshot() async => {...values};
  @override
  Future<void> replace(Map<String, String> next) async {
    if (failReplacement) {
      throw StateError('synthetic unavailable system storage');
    }
    values
      ..clear()
      ..addAll(next);
  }

  @override
  Future<void> clear() async => values.clear();
}

class _Files implements CredentialFiles {
  final values = <String, String>{};
  @override
  Future<T> locked<T>(Future<T> Function() operation) => operation();
  @override
  Future<String?> read(String name) async => values[name];
  @override
  Future<void> write(String name, String value) async => values[name] = value;
  @override
  Future<void> remove(String name) async => values.remove(name);
}

void main() {
  test(
    'interrupted Android migration reaches recovery before any new offer',
    () async {
      final files = _Files();
      final system = _System();
      var keys = ManagedKeys(files: files, system: system);
      await keys.initialize(firstRunMode: CredentialMode.local);
      await keys.write('nova.localKey', 'original-key');
      system.failReplacement = true;
      await expectLater(
        keys.changeMode(CredentialMode.system),
        throwsStateError,
      );
      keys = ManagedKeys(files: files, system: system);
      final policy = CredentialStartupPolicy(
        files: files,
        platform: TargetPlatform.android,
      );
      await policy.initialize(keys, requireExistingKey: true);
      final before = {...files.values};
      final gate = await credentialStartupGate(
        keys,
        policy,
        onContinue: () async => fail('must not open'),
      );
      expect(gate, isA<CredentialRecoveryScreen>());
      expect(keys.mode, CredentialMode.local);
      expect(keys.cleanupPending, isTrue);
      expect(await policy.shouldOfferAndroidMigration(keys), isFalse);
      expect(files.values, before);
      expect(system.values, isEmpty);
    },
  );

  test('startup gates the legacy Android notebook with a one-time offer before opening', () async {
    final files = _Files();
    final system = _System();
    var keys = ManagedKeys(files: files, system: system);
    await keys.initialize(firstRunMode: CredentialMode.local);
    await keys.write('nova.localKey', 'original-key');
    keys = ManagedKeys(files: files, system: system);
    final policy = CredentialStartupPolicy(
      files: files,
      platform: TargetPlatform.android,
    );
    await policy.initialize(keys, requireExistingKey: true);
    var opens = 0;
    final gate = await credentialStartupGate(
      keys,
      policy,
      onContinue: () async => opens++,
    );
    expect(gate, isA<AndroidCredentialMigrationScreen>());
    expect(opens, 0);
    expect(keys.mode, CredentialMode.local);
    await (gate! as AndroidCredentialMigrationScreen).onKeepLocal();
    expect(
      await credentialStartupGate(
        keys,
        policy,
        onContinue: () async => opens++,
      ),
      isNull,
    );
    expect(opens, 0);
    expect(keys.mode, CredentialMode.local);
  });

  test(
    'desktop startup keeps its existing local choice and has no Android offer',
    () async {
      for (final platform in [
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.windows,
      ]) {
        final files = _Files();
        final keys = ManagedKeys(files: files, system: _System());
        final policy = CredentialStartupPolicy(
          files: files,
          platform: platform,
        );
        await policy.initialize(keys, firstRunMode: CredentialMode.local);
        expect(keys.mode, CredentialMode.local);
        final before = {...files.values};
        expect(await policy.shouldOfferAndroidMigration(keys), isFalse);
        expect(files.values, before);
      }
    },
  );

  test('Android offers local migration once without changing credentials on decline', () async {
    final files = _Files();
    final system = _System();
    var keys = ManagedKeys(files: files, system: system);
    await keys.initialize(firstRunMode: CredentialMode.local);
    await keys.write('nova.localKey', 'original-key');
    await keys.write('nova.account.inactive', 'original-account-key');
    final originalLocal = files.values['local.json'];
    var policy = CredentialStartupPolicy(
      files: files,
      platform: TargetPlatform.android,
    );
    keys = ManagedKeys(files: files, system: system);
    await policy.initialize(keys, requireExistingKey: true);
    final originalFiles = {...files.values};
    expect(await policy.shouldOfferAndroidMigration(keys), isTrue);
    expect(
      files.values,
      originalFiles,
      reason: 'Checking the offer is read-only',
    );
    expect(keys.mode, CredentialMode.local);
    expect(system.values, isEmpty);
    await policy.keepLocalCredentials();
    policy = CredentialStartupPolicy(
      files: files,
      platform: TargetPlatform.android,
    );
    keys = ManagedKeys(files: files, system: system);
    await policy.initialize(keys, requireExistingKey: true);
    expect(await policy.shouldOfferAndroidMigration(keys), isFalse);
    expect(keys.mode, CredentialMode.local);
    expect(files.values['local.json'], originalLocal);
    expect(await keys.read('nova.localKey'), 'original-key');
    expect(await keys.read('nova.account.inactive'), 'original-account-key');
    expect(system.values, isEmpty);
  });

  test(
    'Android startup cannot select local credentials for a fresh install',
    () async {
      final files = _Files();
      final keys = ManagedKeys(files: files, system: _System());
      final policy = CredentialStartupPolicy(
        files: files,
        platform: TargetPlatform.android,
      );
      await policy.initialize(keys, firstRunMode: CredentialMode.local);
      expect(keys.mode, CredentialMode.system);
      expect(files.values.containsKey('local.json'), isFalse);
      expect(await policy.shouldOfferAndroidMigration(keys), isFalse);
    },
  );

  test('only mode-less fresh setup asks for a credential choice', () async {
    final files = _Files();
    expect(await credentialChoiceRequired(files, recovering: false), isTrue);
    expect(
      files.values,
      isEmpty,
      reason: 'Showing the choice must not persist it',
    );
    expect(await credentialChoiceRequired(files, recovering: true), isFalse);
    files.values['state.json'] = '{"version":1,"active":"system"}';
    expect(await credentialChoiceRequired(files, recovering: false), isFalse);
    files.values['state.json'] = '{"version":1,"active":"local"}';
    expect(await credentialChoiceRequired(files, recovering: false), isFalse);
  });

  test(
    'a lost mode marker cannot turn local credentials into a new install',
    () async {
      final files = _Files()..values['local.json'] = 'existing credentials';
      await expectLater(
        credentialChoiceRequired(files, recovering: false),
        throwsFormatException,
      );
      expect(files.values['local.json'], 'existing credentials');
    },
  );
}
