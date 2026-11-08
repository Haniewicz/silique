// Runs only in a disposable native macOS app with a random Keychain service.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:silique/core/contracts.dart';
import 'package:silique/storage/credential_files.dart';
import 'package:silique/storage/managed_keys.dart';
import 'package:silique/storage/secure_keys.dart';

class _UnusedLegacy implements SecureKeyCollection {
  @override
  Future<String?> read(String key) =>
      throw StateError('Unexpected legacy lookup');
  @override
  Future<Map<String, String>> readAll() =>
      throw StateError('Unexpected legacy enumeration');
  @override
  Future<void> write(String key, String value) =>
      throw StateError('Unexpected legacy write');
  @override
  Future<void> delete(String key) =>
      throw StateError('Unexpected legacy deletion');
}

class _NativePrimary implements KeyStore {
  _NativePrimary(this.storage);
  final FlutterSecureStorage storage;
  int reads = 0;
  @override
  Future<String?> read(String key) async {
    reads++;
    return storage.read(key: key);
  }

  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => storage.delete(key: key);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native macOS Keychain reads share only the existing credential gate',
    (tester) async {
      expect(
        Platform.isMacOS && const bool.fromEnvironment('SILIQUE_ISOLATED_TEST'),
        isTrue,
      );
      final root = Directory(
        (await Directory.systemTemp.createTemp('silique-keychain-scope-'))
            .resolveSymbolicLinksSync(),
      );
      final service =
          'silique-isolated-scope-${DateTime.now().microsecondsSinceEpoch}';
      final storage = FlutterSecureStorage(
        mOptions: MacOsOptions(
          accountName: service,
          usesDataProtectionKeychain: false,
        ),
      );
      final primary = _NativePrimary(storage);
      final backend = SecureKeys.forBackend(
        legacy: _UnusedLegacy(),
        primary: primary,
      );
      final files = NativeCredentialFiles(
        Directory('${root.path}/credentials'),
      );
      const slot = 'nova.keys.v1';
      String bundle(String? session) => jsonEncode({
        'version': 1,
        'keys': {'nova.localKey': 'synthetic-master', 'nova.session': session},
      });
      try {
        await tester.runAsync(() async {
          await storage.write(key: slot, value: bundle('first'));
          await files.write(
            ManagedKeys.stateFile,
            jsonEncode({'version': 1, 'active': 'system', 'established': true}),
          );
          final keys = ManagedKeys(files: files, system: backend);
          await keys.initialize(requireExistingKey: true);
          expect(primary.reads, 1);
          primary.reads = 0;
          expect(await keys.read('nova.session'), 'first');
          expect(primary.reads, 1);
          // A separate native write between gate acquisitions is authoritative.
          await storage.write(key: slot, value: bundle(null));
          primary.reads = 0;
          expect(await keys.read('nova.session'), isNull);
          expect(primary.reads, 1);
          expect(await keys.read('nova.localKey'), 'synthetic-master');
        });
      } finally {
        await tester.runAsync(() async {
          await storage.delete(key: slot); // This random service/slot only.
          root.deleteSync(recursive: true);
        });
      }
    },
  );
}
