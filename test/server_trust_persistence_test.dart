import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/contracts.dart';
import 'package:silique/core/server_trust.dart';
import 'package:silique/core/spki.dart';
import 'package:silique/storage/startup_notebook.dart';

/// Loads a fixture certificate's DER bytes (same loader as
/// `test/server_trust_test.dart`, duplicated here to keep the file standalone).
List<int> _der(String name) {
  final pem = File('test/fixtures/certs/$name.pem').readAsStringSync();
  final body = pem
      .split(RegExp(r'\r?\n'))
      .where((l) => !l.startsWith('-----'))
      .join();
  return const Base64Decoder().convert(body);
}

/// A fixture-backed [X509Certificate] whose expiry defaults to far in the
/// future, so `decideSync` can be exercised without a live TLS handshake.
class _FakeCert implements X509Certificate {
  _FakeCert(this._der);

  final List<int> _der;

  @override
  Uint8List get der => Uint8List.fromList(_der);

  @override
  DateTime get endValidity => DateTime.now().add(const Duration(days: 365));

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
}

class _Keys implements KeyStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

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
    'a confirmed pin survives a process restart via the startup notebook',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-pin-restart-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final support = Directory('${dir.path}/support')..createSync();
      final root = '${dir.path}/root';
      final base = Uri.parse('https://silique.example');

      final notebook = await openStartupNotebook(
        root,
        keys: _Keys(),
        applicationSupport: support.path,
      );
      try {
        // The production startup path must wire a durable store, not memory.
        expect(notebook.trust.store, isA<FileTrustStore>());
        // `ServerTrust.confirm` is the same path `guardServerTrust` uses after
        // the user agrees to trust the server.
        await notebook.trust.confirm(base, certInfoOf(_FakeCert(_der('a'))));
      } finally {
        await notebook.close();
      }

      // A brand-new instance over the same file simulates a process restart:
      // no shared store, everything re-read from disk.
      final restarted = ServerTrust(
        store: FileTrustStore(File('${support.path}/server-trust.json')),
      );
      expect(
        restarted.decideSync(cert: _FakeCert(_der('a')), base: base),
        TrustDecision.allow,
        reason: 'the confirmed pin must be read back after a restart',
      );
      expect(
        restarted.decideSync(cert: _FakeCert(_der('b')), base: base),
        TrustDecision.pinMismatch,
        reason: 'a different key must still be a hard mismatch',
      );
    },
  );

  test('a legacy bare-SPKI server-trust.json still reads as a confirmed pin',
      () async {
    final dir = Directory.systemTemp.createTempSync('silique-pin-legacy-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/server-trust.json');
    // The original format stored a bare base64 SPKI string as the value.
    await file.writeAsString(
      jsonEncode({'https://silique.example': spkiSha256(_der('a'))}),
    );

    final trust = ServerTrust(store: FileTrustStore(file));
    expect(
      trust.decideSync(
        cert: _FakeCert(_der('a')),
        base: Uri.parse('https://silique.example'),
      ),
      TrustDecision.allow,
    );
    expect(
      trust.decideSync(
        cert: _FakeCert(_der('b')),
        base: Uri.parse('https://silique.example'),
      ),
      TrustDecision.pinMismatch,
    );
  });

  test('no pin never silently allows (security regression guard)', () async {
    final dir = Directory.systemTemp.createTempSync('silique-pin-nopin-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final trust = ServerTrust(store: FileTrustStore(File('${dir.path}/s.json')));
    final base = Uri.parse('https://silique.example');
    expect(
      trust.decideSync(cert: _FakeCert(_der('a')), base: base),
      TrustDecision.unknownCertificate,
      reason: 'a missing pin must never turn into a silent allow',
    );
  });

  test('in-memory store is reachable only through the explicit trustStore '
      'parameter', () async {
    final dir = Directory.systemTemp.createTempSync('silique-explicit-mem-');
    addTearDown(() => dir.deleteSync(recursive: true));

    final notebook = await openStartupNotebook(
      '${dir.path}/root',
      keys: _Keys(),
      trustStore: InMemoryTrustStore(),
    );
    try {
      expect(notebook.trust.store, isA<InMemoryTrustStore>());
    } finally {
      await notebook.close();
    }
  });
}