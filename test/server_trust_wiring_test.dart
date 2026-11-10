import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Regression guard for a defect that reached a published release: the
/// certificate-trust core and its dialogs existed, tests for both were green,
/// yet no construction site passed a `ServerTrust`. `SiliqueApi` then built a
/// plain `http.Client`, the platform rejected the self-signed certificate, and
/// the user saw `CERTIFICATE_VERIFY_FAILED` with no way to confirm the server.
///
/// Unit tests of the pinning core cannot catch that, because the core is
/// correct in isolation. This test asserts the wiring instead: every client
/// that talks to a user-supplied server must be given the trust decision.
void main() {
  test('every SiliqueApi construction receives a ServerTrust', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].contains('SiliqueApi(')) continue;
        // Annotations, class declarations and the constructor's own declaration
        // in api.dart are not construction sites.
        final head = lines[i].trimLeft();
        if (head.startsWith('class ') || head.startsWith('///')) continue;
        if (head == 'SiliqueApi(' || head.startsWith('SiliqueApi({')) continue;
        final window = lines.skip(i).take(8).join(' ');
        if (!window.contains('trust:')) {
          offenders.add('${entity.path}:${i + 1}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'A SiliqueApi built without trust: silently disables server pinning '
          'and makes every self-signed server unreachable.',
    );
  });
}
