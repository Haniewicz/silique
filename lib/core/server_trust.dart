import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'spki.dart';

/// Metadata about the certificate a server presented during a failed chain
/// validation, exposed so a UI layer can show the user what they would be
/// confirming before it ever stores a pin.
class CertInfo {
  const CertInfo({
    required this.spki,
    required this.subject,
    this.san,
    required this.notAfter,
    this.pemNiepotrzebny = false,
  });

  /// SHA-256 (base64) of the certificate's subjectPublicKeyInfo.
  final String spki;

  /// Human-readable subject from the certificate.
  final String subject;

  /// Subject Alternative Name entries, when present (informational only).
  final String? san;

  /// Certificate expiry (the X.509 notAfter field).
  final DateTime notAfter;

  /// The SPKI carries the key identity, so a PEM copy is never required.
  /// This flag exists to keep the API shape explicit and self-documenting.
  final bool pemNiepotrzebny;
}

/// Extracts pin metadata from an [X509Certificate].
CertInfo certInfoOf(X509Certificate cert) => CertInfo(
  spki: spkiSha256(cert.der),
  subject: cert.subject,
  san: extractSan(cert.der),
  notAfter: cert.endValidity,
);

enum TrustDecision { allow, unknownCertificate, pinMismatch, expired }

/// Normalizes a server URI to a stable pin key: `scheme://host:port`, with the
/// host lowercased and the default port (443 for https, 80 for http) omitted,
/// so `https://Host:443/`, `https://host` and `https://host:443` map to one
/// key.
String serverKeyOf(Uri base) {
  final scheme = base.scheme.toLowerCase();
  final host = base.host.toLowerCase();
  final port = base.hasPort ? base.port : _defaultPort(scheme);
  final portPart = port == _defaultPort(scheme) ? '' : ':$port';
  return '$scheme://$host$portPart';
}

int _defaultPort(String scheme) => scheme == 'http' ? 80 : 443;

/// Decides whether a server certificate is trusted.
///
/// A *public-key pin*, not a certificate pin: confirmed once, it survives
/// routine certificate renewals (same `key.pem` → same SPKI) and only breaks
/// when the key pair rotates. Pins are plain digests of a public key — not
/// secrets — so they live outside the encrypted vault and can be read before
/// it unlocks.
class ServerTrust {
  ServerTrust({required this.store});

  final ServerTrustStore store;

  /// The pin most recently consulted by [decideSync], for diagnostics when a
  /// mismatch is detected (the callback cannot carry it out itself).
  String? lastExpectedPin;

  Future<Map<String, String>?> _record(Uri base) async =>
      store.read(serverKeyOf(base));

  /// Reads the stored SPKI pin for [base], or null when none is confirmed.
  Future<String?> pinFor(Uri base) async => (await _record(base))?['spki'];

  /// Persists a confirmed [cert] pin for [base].
  Future<void> confirm(Uri base, CertInfo cert) async {
    await store.write(serverKeyOf(base), {
      'spki': cert.spki,
      'subject': cert.subject,
      'savedAt': DateTime.now().toUtc().toIso8601String(),
      'notAfter': cert.notAfter.toUtc().toIso8601String(),
    });
  }

  /// Decides whether [cert], seen while connecting to [base], is trusted.
  ///
  /// IMPORTANT: call this only from `badCertificateCallback`, i.e. after the
  /// platform's own CA/name/expiry validation already failed. A certificate
  /// that the platform validates normally must never be compared against a pin
  /// here — otherwise a later migration to a publicly-trusted CA (Tailscale,
  /// Cloudflare, …) would pin the OLD key and hard-block the user. The pin
  /// path is exclusively the trust fallback for otherwise-untrusted certs.
  Future<TrustDecision> decide({
    required X509Certificate cert,
    required Uri base,
  }) async {
    if (store is SynchronousServerTrustStore) {
      final key = serverKeyOf(base);
      return _decideWith(
        cert,
        (store as SynchronousServerTrustStore).readSync(key),
      );
    }
    return _decideWith(cert, await _record(base));
  }

  /// Synchronous variant for `badCertificateCallback`, which cannot await the
  /// store. Requires a [SynchronousServerTrustStore]-backed store; throws
  /// [UnsupportedError] otherwise.
  TrustDecision decideSync({required X509Certificate cert, required Uri base}) {
    if (store is! SynchronousServerTrustStore) {
      throw UnsupportedError(
        'ServerTrust.decideSync requires a SynchronousServerTrustStore',
      );
    }
    final key = serverKeyOf(base);
    return _decideWith(
      cert,
      (store as SynchronousServerTrustStore).readSync(key),
    );
  }

  TrustDecision _decideWith(X509Certificate cert, Map<String, String>? record) {
    final info = certInfoOf(cert);
    final expected = record?['spki'];
    lastExpectedPin = expected;

    // No pin means no consent: never silently accept a certificate nobody
    // confirmed. The caller surfaces the fingerprint for an informed choice.
    if (expected == null) return TrustDecision.unknownCertificate;

    // A different key is a hard mismatch: no "trust anyway" escape hatch.
    if (info.spki != expected) return TrustDecision.pinMismatch;

    // The pin matched, but `badCertificateCallback` does not say *why* chain
    // validation failed. A matching pin alone would admit an expired cert,
    // so check notAfter ourselves before allowing the connection.
    if (!info.notAfter.isAfter(DateTime.now())) return TrustDecision.expired;

    return TrustDecision.allow;
  }
}

/// Persistence of pins, scoped per normalized server key. Implementations must
/// tolerate a missing file as "no pin" and write atomically.
abstract class ServerTrustStore {
  Future<Map<String, String>?> read(String serverKey);
  Future<void> write(String serverKey, Map<String, String> record);
}

/// Marker for stores that can also read synchronously, which
/// `badCertificateCallback` requires.
abstract class SynchronousServerTrustStore implements ServerTrustStore {
  Map<String, String>? readSync(String serverKey);
}

/// JSON-file backed store.
///
/// A missing file reads as "no pin" (first run, or a deleted store). Writes go
/// to a `*.tmp` sibling and are renamed into place, so a crash mid-write cannot
/// corrupt the only copy of a user's confirmed pins.
class FileTrustStore implements SynchronousServerTrustStore {
  FileTrustStore(this._file);

  /// Default location: `server-trust.json` in the application support
  /// directory — outside the vault database, readable before unlock.
  static Future<FileTrustStore> inApplicationSupport() async {
    final support = await getApplicationSupportDirectory();
    return FileTrustStore(
      File('${support.path}${Platform.pathSeparator}server-trust.json'),
    );
  }

  final File _file;

  File get file => _file;

  Map<String, dynamic> _loadAllSync() {
    try {
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! Map) return <String, dynamic>{};
      return decoded.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<Map<String, dynamic>> _loadAll() async {
    try {
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is! Map) return <String, dynamic>{};
      return decoded.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// Normalizes a stored value into a `{spki, subject, savedAt, notAfter}`
  /// record. Legacy files stored a bare SPKI string; those read as a record
  /// with only the pin present, so the trust decision keeps working while the
  /// UI metadata (date/expiry) simply remains unknown.
  static Map<String, String>? _recordOf(dynamic value) {
    if (value is String) return {'spki': value};
    if (value is! Map) return null;
    final out = <String, String>{};
    for (final entry in value.entries) {
      final key = entry.key.toString();
      final valueText = entry.value?.toString();
      if (valueText != null) out[key] = valueText;
    }
    return out.isEmpty ? null : out;
  }

  @override
  Map<String, String>? readSync(String serverKey) =>
      _recordOf(_loadAllSync()[serverKey]);

  @override
  Future<Map<String, String>?> read(String serverKey) async =>
      _recordOf((await _loadAll())[serverKey]);

  @override
  Future<void> write(String serverKey, Map<String, String> record) async {
    final all = await _loadAll();
    all[serverKey] = record;
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(all));
    await tmp.rename(_file.path);
  }
}
