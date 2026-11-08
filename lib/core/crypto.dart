import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'contracts.dart';
import 'models.dart';

class SiliqueCrypto implements CryptoProvider {
  @override
  Future<Json> createIdentity() async {
    final pair = await X25519().newKeyPair();
    final data = await pair.extract();
    return {
      'private': base64Encode(data.bytes),
      'public': base64Encode(data.publicKey.bytes),
    };
  }

  @override
  Future<List<int>> pairingKey(
    Json identity,
    String peerKey,
    String context,
  ) async {
    final pair = SimpleKeyPairData(
      base64Decode(identity['private'] as String),
      publicKey: SimplePublicKey(
        base64Decode(identity['public'] as String),
        type: KeyPairType.x25519,
      ),
      type: KeyPairType.x25519,
    );
    final shared = await X25519().sharedSecretKey(
      keyPair: pair,
      remotePublicKey: SimplePublicKey(
        base64Decode(peerKey),
        type: KeyPairType.x25519,
      ),
    );
    return (await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared,
      nonce: utf8.encode('nova:1:pairing'),
      info: utf8.encode(context),
    )).extractBytes();
  }

  final _aes = AesGcm.with256bits();
  @override
  List<int> randomKey() =>
      List<int>.generate(32, (_) => Random.secure().nextInt(256));
  @override
  Future<String> seal(List<int> key, String plaintext, String context) async {
    if (key.length != 32) throw ArgumentError('A 256-bit key is required');
    final box = await _aes.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(key),
      aad: utf8.encode(context),
    );
    return jsonEncode({
      'v': 1,
      'n': base64Encode(box.nonce),
      'c': base64Encode(box.cipherText),
      'm': base64Encode(box.mac.bytes),
    });
  }

  @override
  Future<String> open(List<int> key, String envelope, String context) async {
    final j = jsonDecode(envelope) as Json;
    if (j['v'] != 1) {
      throw const FormatException('Unsupported encryption version');
    }
    final box = SecretBox(
      base64Decode(j['c'] as String),
      nonce: base64Decode(j['n'] as String),
      mac: Mac(base64Decode(j['m'] as String)),
    );
    return utf8.decode(
      await _aes.decrypt(
        box,
        secretKey: SecretKey(key),
        aad: utf8.encode(context),
      ),
    );
  }

  @override
  Future<String> openCompat(
    List<int> key,
    String envelope,
    String context,
    String legacyContext,
  ) async {
    try {
      return await open(key, envelope, context);
    } on SecretBoxAuthenticationError {
      return open(key, envelope, legacyContext);
    }
  }

  @override
  Future<List<int>> passwordKey(String password, List<int> salt) async =>
      (await Argon2id(
            memory: 65536,
            iterations: 3,
            parallelism: 1,
            hashLength: 32,
          ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt))
          .extractBytes();
  @override
  Future<String> stableId(List<int> key, String value) async => base64UrlEncode(
    (await Hmac.sha256().calculateMac(
      utf8.encode(value),
      secretKey: SecretKey(key),
    )).bytes,
  ).replaceAll('=', '');
}
