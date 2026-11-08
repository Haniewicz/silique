import 'dart:isolate';

import '../core/crypto.dart';

class NativeCrypto extends SiliqueCrypto {
  @override
  Future<List<int>> passwordKey(String password, List<int> salt) =>
      Isolate.run(() => SiliqueCrypto().passwordKey(password, salt));
}
