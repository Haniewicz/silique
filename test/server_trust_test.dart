import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/server_trust.dart';
import 'package:silique/core/spki.dart';
import 'package:silique/services/api.dart';

/// Loads a fixture certificate's DER bytes.
List<int> _der(String name) {
  final root = Directory.current.path;
  final pem = File('$root/test/fixtures/certs/$name.pem').readAsStringSync();
  final body = pem
      .split(RegExp(r'\r?\n'))
      .where((l) => !l.startsWith('-----'))
      .join();
  return const Base64Decoder().convert(body);
}

/// An [X509Certificate] backed by a fixture's DER plus an overridable expiry,
/// so `decide()` can be exercised against every trust branch without a live
/// TLS handshake.
class FakeX509Certificate implements X509Certificate {
  FakeX509Certificate(this._der, {DateTime? endValidity})
    : endValidity = endValidity ?? _endFromDer(_der);

  final List<int> _der;

  @override
  final DateTime endValidity;

  @override
  Uint8List get der => Uint8List.fromList(_der);

  @override
  String get issuer => 'CN=test.invalid';

  @override
  String get pem => '';

  @override
  Uint8List get sha1 => Uint8List(0);

  @override
  DateTime get startValidity => DateTime(2000);

  @override
  String get subject => 'CN=test.invalid';

  static DateTime _endFromDer(List<int> der) {
    // In real code we use X509Certificate.endValidity. Tests either pass an
    // explicit expiry or default to a far-future value; parsing notAfter out
    // of DER here is unnecessary, so default to a clearly valid date.
    return DateTime.now().add(const Duration(days: 365));
  }
}

void main() {
  group('spkiSha256', () {
    test('same key => same SPKI; different key => different SPKI', () {
      final a = _der('a');
      final aPrime = _der('a-prime');
      final b = _der('b');

      expect(spkiSha256(a), spkiSha256(aPrime));
      expect(spkiSha256(a), isNot(spkiSha256(b)));
    });

    test('expired cert shares A key so same SPKI', () {
      expect(spkiSha256(_der('a')), spkiSha256(_der('a-expired')));
    });
  });

  group('serverKeyOf', () {
    test('normalizes scheme, host case and default port', () {
      expect(serverKeyOf(Uri.parse('https://Host:443/')), 'https://host');
      expect(serverKeyOf(Uri.parse('https://host')), 'https://host');
      expect(serverKeyOf(Uri.parse('https://host:443')), 'https://host');
    });

    test('keeps non-default ports', () {
      expect(serverKeyOf(Uri.parse('https://host:8443')), 'https://host:8443');
      expect(serverKeyOf(Uri.parse('http://HOST:8787')), 'http://host:8787');
    });
  });

  group('ServerTrust.decide', () {
    late Directory dir;
    late FileTrustStore store;
    late ServerTrust trust;
    late String spkiA;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('server-trust-test-');
      store = FileTrustStore(File('${dir.path}/server-trust.json'));
      trust = ServerTrust(store: store);
      spkiA = spkiSha256(_der('a'));
    });

    tearDown(() => dir.deleteSync(recursive: true));

    X509Certificate certFor(String name, {DateTime? notAfter}) =>
        FakeX509Certificate(_der(name), endValidity: notAfter);

    test('no pin => unknownCertificate', () async {
      final decision = await trust.decide(
        cert: certFor('a'),
        base: Uri.parse('https://host'),
      );
      expect(decision, TrustDecision.unknownCertificate);
    });

    test('pin A + cert A => allow', () async {
      await store.write('https://host', {'spki': spkiA});
      final decision = await trust.decide(
        cert: certFor('a'),
        base: Uri.parse('https://host'),
      );
      expect(decision, TrustDecision.allow);
    });

    test('pin A + cert B => pinMismatch', () async {
      await store.write('https://host', {'spki': spkiA});
      final decision = await trust.decide(
        cert: certFor('b'),
        base: Uri.parse('https://host'),
      );
      expect(decision, TrustDecision.pinMismatch);
    });

    test('pin A + cert A (expired) => expired', () async {
      await store.write('https://host', {'spki': spkiA});
      final decision = await trust.decide(
        cert: certFor('a-expired', notAfter: DateTime(2021)),
        base: Uri.parse('https://host'),
      );
      expect(decision, TrustDecision.expired);
    });
  });

  group('FileTrustStore', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('server-trust-store-');
      file = File('${dir.path}/server-trust.json');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('missing file reads as no pin', () async {
      final store = FileTrustStore(file);
      expect(await store.read('https://host'), isNull);
    });

    test('round-trips a pin and writes atomically', () async {
      final store = FileTrustStore(file);
      await store.write('https://host', {'spki': 'abc'});
      expect((await store.read('https://host'))?['spki'], 'abc');
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });
  });

  group('SiliqueApi without ServerTrust (regression)', () {
    test('validates servers as before and accepts no trust arg', () {
      expect(
        SiliqueApi.validateServer('https://notes.example.com').host,
        'notes.example.com',
      );
      expect(
        () => SiliqueApi.validateServer('http://example.com'),
        throwsFormatException,
      );
      // Constructor still works without a trust/custom client.
      final api = SiliqueApi('https://notes.example.com');
      expect(api.base.host, 'notes.example.com');
      api.close();
    });
  });

  group('exceptions', () {
    test('carry metadata', () {
      final e = UntrustedServerCertificate(
        spki: 'spki',
        subject: 'CN=x',
        notAfter: DateTime(2030),
      );
      expect(e.spki, 'spki');
      expect(e.subject, 'CN=x');

      final mismatch = ServerCertificatePinMismatch(expected: 'e', actual: 'a');
      expect(mismatch.expected, 'e');
      expect(mismatch.actual, 'a');

      expect(ServerCertificateExpired(DateTime(2000)).notAfter.year, 2000);
    });
  });
}
