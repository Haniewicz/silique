import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/contracts.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/storage/startup_notebook.dart';

class _DelayedKeys implements KeyStore {
  final entered = Completer<void>();
  final resume = Completer<void>();
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async {
    if (!entered.isCompleted) {
      entered.complete();
      await resume.future;
    }
    return values[key];
  }

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
    'a stale successful initialization never replaces a newer root',
    () async {
      final dir = Directory.systemTemp.createTempSync(
        'silique-stale-activation-',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final support = Directory('${dir.path}/support')..createSync();
      NativeStorage.persistChosenRoot(support.path, 'root-A');
      final keys = _DelayedKeys();
      final opening = openStartupNotebook(
        '${dir.path}/recovered-A',
        keys: keys,
        applicationSupport: support.path,
      );
      await keys.entered.future;
      NativeStorage.persistChosenRoot(support.path, 'root-B');
      keys.resume.complete();
      await expectLater(opening, throwsStateError);
      expect(NativeStorage.recordedRoot(support.path), 'root-B');
      Directory('${dir.path}/recovered-A')
          .renameSync('${dir.path}/candidate-preserved');
    },
  );
}
