import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/api.dart';

void main() {
  test('HTTP is confined to loopback and explicit Tailscale address space', () {
    for (final server in [
      'http://127.0.0.1:8787',
      'http://localhost:8787',
      'https://notes.example.com',
      'http://100.64.0.1:8787',
    ]) {
      expect(SiliqueApi.validateServer(server).host, isNotEmpty);
    }
    for (final server in [
      'http://example.com',
      'http://192.0.2.10:8787',
      'http://100.128.0.1',
      'http://100.63.255.255',
      'https://user:password@example.com',
      'https://example.com/path',
      'https://example.com?token=secret',
      'http://100.999.0.1',
    ]) {
      expect(() => SiliqueApi.validateServer(server), throwsFormatException);
    }
  });
}
