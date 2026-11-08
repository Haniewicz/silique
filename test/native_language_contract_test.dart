import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native English/Polish language contracts', () async {
    String? python;
    for (final candidate
        in Platform.isWindows ? ['python', 'python3'] : ['python3', 'python']) {
      try {
        if ((await Process.run(candidate, ['--version'])).exitCode == 0) {
          python = candidate;
          break;
        }
      } on ProcessException {
        // Minimal builders may not carry Python; report the missing dependency.
      }
    }
    if (python == null) {
      markTestSkipped('Native language contracts require Python 3');
      return;
    }
    final result = await Process.run(python, [
      '-m',
      'unittest',
      'tool.test_native_language',
      '-v',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
