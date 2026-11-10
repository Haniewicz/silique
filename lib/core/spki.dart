import 'dart:convert';

import 'package:cryptography/dart.dart' show DartSha256;

/// Minimal DER walker that extracts the `subjectPublicKeyInfo` (SPKI) block
/// from an X.509 certificate and hashes it with SHA-256.
///
/// Certificate pinning works on the *public key*, not the whole certificate:
/// renewing a certificate with the same `key.pem` produces a different DER
/// (new serial, dates, signature) but an identical SPKI, so a previously
/// confirmed pin keeps working across routine renewals. Rotating the key pair
/// changes the SPKI and therefore requires re-confirmation — exactly the
/// security property we want.
///
/// This is deliberately a hand-rolled walker rather than a full ASN.1 library:
/// an X.509 v3 certificate is a nested SEQUENCE whose subjectPublicKeyInfo is
/// identified structurally (a SEQUENCE whose last child is a BIT STRING), and
/// we only ever parse structure, never trust data. No new dependency is needed
/// for that.
class SpkiExtractException implements Exception {
  SpkiExtractException(this.message);
  final String message;
  @override
  String toString() => 'SpkiExtractException: $message';
}

/// Returns the SHA-256 of the certificate's subjectPublicKeyInfo.
///
/// The result is the base64 (with `=` padding) encoding of the 32-byte digest,
/// consistent with how fingerprints are represented elsewhere in the app.
///
/// Throws [SpkiExtractException] when [der] is not a well-formed certificate
/// with a parsable SPKI block.
String spkiSha256(List<int> der) =>
    base64Encode(const DartSha256().hashSync(_extractSpki(der)).bytes);

/// Returns the raw DER bytes of the subjectPublicKeyInfo block.
///
/// `SubjectPublicKeyInfo ::= SEQUENCE { algorithm AlgorithmIdentifier,
/// subjectPublicKey BIT STRING }`. Within `tbsCertificate` it is the SEQUENCE
/// whose last child element is a BIT STRING — structurally distinct from the
/// issuer/validity/subject SEQUENCEs that precede it.
List<int> _extractSpki(List<int> der) {
  final tbs = _DerReader(_tbs(der));
  while (!tbs.atEnd) {
    final element = tbs.readElement();
    if (element.isEmpty || element.first != 0x30) continue;
    final body = _DerReader(element);
    final content = body.readConstructed();
    // Walk the SEQUENCE's children; the SPKI ends with the public-key
    // BIT STRING (0x03).
    final children = _DerReader(content);
    int? lastTag;
    while (!children.atEnd) {
      lastTag = children.readElement().first;
    }
    if (lastTag == 0x03) return element;
  }
  throw SpkiExtractException('subjectPublicKeyInfo not found');
}

/// Returns the to-be-signed certificate structure bytes.
List<int> _tbs(List<int> der) {
  final reader = _DerReader(der);
  reader.expectTag(0x30); // Certificate ::= SEQUENCE
  final cert = reader.readConstructed();
  final certBody = _DerReader(cert);
  certBody.expectTag(0x30);
  return certBody.readConstructed();
}

/// Best-effort extraction of the subjectAlternativeName extension (OID
/// 2.5.29.17) from a certificate. Returns a comma-joined string of the
/// GeneralName values, or null when the extension is absent or unparsable.
///
/// `dart:io`'s [X509Certificate] does not expose SANs, so a confirmed cert's
/// hostnames have to be read out of the DER. This is informational metadata
/// shown to the user at confirm time only; it never participates in any trust
/// decision (the SPKI pin is the sole source of truth).
String? extractSan(List<int> der) {
  const sanOid = [0x55, 0x1d, 0x11]; // 2.5.29.17
  try {
    final tbs = _DerReader(_tbs(der));
    // Walk tbsCertificate fields until the [3] extensions tag (0xa3), which
    // follows the subjectPublicKeyInfo. The SPKI itself is a SEQUENCE (0x30)
    // and is skipped below by readElement() like any other unknown field.
    while (!tbs.atEnd) {
      final tag = _peekTag(tbs);
      if (tag == 0xa3) {
        // [3] EXPLICIT extensions
        final wrapped = tbs.readElement();
        final inner = _DerReader(_contentOfContext(wrapped));
        inner.expectTag(0x30);
        final exts = _DerReader(inner.readConstructed());
        while (!exts.atEnd) {
          final ext = _DerReader(exts.readElement());
          ext.expectTag(0x30);
          final extBody = _DerReader(ext.readConstructed());
          final oid = _oidBytes(extBody.readElement());
          if (_equals(oid, sanOid)) {
            final octets = extBody.readElement();
            final payload = _DerReader(_contentOfRest(octets));
            return _parseGeneralNames(payload);
          }
        }
        break; // extensions examined, SAN not found
      }
      tbs.readElement();
    }
  } catch (_) {
    return null;
  }
  return null;
}

int _peekTag(_DerReader reader) =>
    reader.atEnd ? -1 : reader._data[reader._pos];

/// Returns the inner bytes of an EXPLICIT context tag `[n]` (`0xa0`-`0xbf`).
List<int> _contentOfContext(List<int> element) {
  if (element.isEmpty) return const [];
  final reader = _DerReader(element);
  final tag = reader._data[reader._pos];
  if ((tag & 0xc0) == 0x80) {
    reader._pos++; // context tag
    reader._readLength();
    return reader._data.sublist(reader._pos);
  }
  return element;
}

/// Extracts the primitive content of an OCTET STRING or a held element.
List<int> _contentOfRest(List<int> element) {
  final reader = _DerReader(element);
  final tag = reader._data[reader._pos];
  if (tag == 0x04) {
    reader._pos++; // OCTET STRING
    reader._readLength();
    return reader._data.sublist(reader._pos);
  }
  return element;
}

List<int> _oidBytes(List<int> element) {
  final reader = _DerReader(element);
  final tag = reader._data[reader._pos];
  if (tag != 0x06) return const [];
  reader._pos++;
  reader._readLength();
  return reader._data.sublist(reader._pos);
}

bool _equals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String? _parseGeneralNames(_DerReader payload) {
  try {
    payload.expectTag(0x30);
    final names = _DerReader(payload.readConstructed());
    final out = <String>[];
    while (!names.atEnd) {
      final name = _DerReader(names.readElement());
      final tag = name._data[name._pos];
      name._pos++; // tag
      final length = name._readLength();
      final value = name._data.sublist(name._pos, name._pos + length);
      // dNSName [2] -> 0x82, iPAddress [7] -> 0x87, URI [6] -> 0x86
      if (tag == 0x82) {
        out.add(utf8.decode(value));
      } else if (tag == 0x87) {
        out.add(value.join('.'));
      }
    }
    return out.isEmpty ? null : out.join(', ');
  } catch (_) {
    return null;
  }
}

/// A cursor over one DER structure (the bytes between a tag and its length).
class _DerReader {
  _DerReader(List<int> bytes) : _data = bytes, _pos = 0;

  final List<int> _data;
  int _pos;

  bool get atEnd => _pos == _data.length;

  void expectTag(int tag) {
    if (atEnd) {
      throw SpkiExtractException('unexpected end of DER');
    }
    if (_data[_pos] != tag) {
      throw SpkiExtractException(
        'expected tag 0x${tag.toRadixString(16)} but found '
        '0x${_data[_pos].toRadixString(16)} at offset $_pos',
      );
    }
  }

  int _readLength() {
    if (atEnd) {
      throw SpkiExtractException('missing DER length');
    }
    final first = _data[_pos++];
    if (first & 0x80 == 0) return first;
    final count = first & 0x7f;
    if (count == 0 || count > 4) {
      throw SpkiExtractException('unsupported DER length ($count bytes)');
    }
    if (_pos + count > _data.length) {
      throw SpkiExtractException('DER length exceeds available data');
    }
    var value = 0;
    for (var i = 0; i < count; i++) {
      value = (value << 8) | _data[_pos++];
    }
    return value;
  }

  /// Reads a constructed (SEQUENCE) element and returns its content bytes.
  List<int> readConstructed() {
    if (atEnd || _data[_pos] != 0x30) {
      throw SpkiExtractException('expected SEQUENCE (0x30)');
    }
    _pos++; // SEQUENCE tag
    final length = _readLength();
    if (_pos + length > _data.length) {
      throw SpkiExtractException('SEQUENCE length exceeds available data');
    }
    final content = _data.sublist(_pos, _pos + length);
    _pos += length;
    return content;
  }

  /// Reads one element (tag, length, content) and returns its encoded bytes.
  List<int> readElement() {
    final start = _pos;
    if (atEnd) {
      throw SpkiExtractException('unexpected end of DER');
    }
    _pos++; // tag byte
    final length = _readLength();
    final end = _pos + length;
    if (end > _data.length) {
      throw SpkiExtractException('element length exceeds available data');
    }
    _pos = end;
    return _data.sublist(start, end);
  }
}
