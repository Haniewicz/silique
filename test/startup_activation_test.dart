import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/contracts.dart';
import 'package:silique/core/server_trust.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/storage/startup_notebook.dart';

class _Keys implements KeyStore {
  _Keys(this.onRead);
  final Future<String?> Function(String) onRead;
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => await onRead(key) ?? values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  test(
    'an existing vault never creates a replacement installation key',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'silique-key-guard-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final originalKeys = _Keys((_) async => null);
      final root = '${directory.path}/notebook';
      final original = await openStartupNotebook(
        root,
        keys: originalKeys,
        trustStore: InMemoryTrustStore(),
      );
      await original.createVault('Existing vault');
      await original.close();
      final unavailableKeys = _Keys((_) async => null);
      Object? failure;
      final reopening = openStartupNotebook(
        root,
        keys: unavailableKeys,
        trustStore: InMemoryTrustStore(),
      );
      try {
        final unexpected = await reopening;
        await unexpected.close();
      } catch (error) {
        failure = error;
      }
      expect(
        unavailableKeys.values,
        isEmpty,
        reason: 'A missing key must not be replaced before vault unlock fails',
      );
      expect(failure, isA<StateError>());
      // The original still opens with its unchanged key and vault identity.
      final restored = await openStartupNotebook(
        root,
        keys: originalKeys,
        trustStore: InMemoryTrustStore(),
      );
      try {
        expect(restored.vaults.single.name, 'Existing vault');
      } finally {
        await restored.close();
      }
    },
  );

  test(
    'failed initialization never changes the recorded original root',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-activation-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final support = Directory('${dir.path}/support')..createSync();
      NativeStorage.persistChosenRoot(
        support.path,
        'original-authoritative-root',
      );
      final keys = _Keys(
        (_) async => throw StateError('key store unavailable'),
      );
      await expectLater(
        openStartupNotebook(
          '${dir.path}/candidate',
          keys: keys,
          applicationSupport: support.path,
        ),
        throwsStateError,
      );
      expect(
        NativeStorage.recordedRoot(support.path),
        'original-authoritative-root',
      );
      // The failed startup released its database handle (also verified on Windows).
      Directory('${dir.path}/candidate')
          .renameSync('${dir.path}/candidate-moved');
    },
  );

  test(
    'root activation happens only after key and notebook initialization',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-activation-ok-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final support = Directory('${dir.path}/support')..createSync();
      NativeStorage.persistChosenRoot(support.path, 'old-root');
      var reads = 0;
      final keys = _Keys((_) async {
        reads++;
        expect(NativeStorage.recordedRoot(support.path), 'old-root');
        return null;
      });
      final root = '${dir.path}/candidate';
      final repo = await openStartupNotebook(
        root,
        keys: keys,
        applicationSupport: support.path,
      );
      try {
        expect(reads, greaterThan(0));
        expect(NativeStorage.recordedRoot(support.path), root);
      } finally {
        await repo.close();
      }
    },
  );
}
