import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native file-keychain preserves missing and existing credentials',
    () async {
      if (!Platform.isMacOS) {
        markTestSkipped('Requires real macOS Security framework and xcrun');
        return;
      }
      final result = await Process.run('python3', [
        'tool/run_macos_keychain_probe.py',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(
        result.stdout,
        contains('Native Keychain probe: checks=6, failures=0'),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
