import 'package:flutter_test/flutter_test.dart';
import 'package:silique/storage/native_crypto.dart';

void main() {
  test(
    'production Argon2id adapter derives a 256-bit key in a worker isolate',
    () async {
      final key = await NativeCrypto().passwordKey(
        'a production parameter check',
        List<int>.generate(16, (i) => i),
      );
      expect(key.length, 32);
      expect(key.toSet().length, greaterThan(1));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
