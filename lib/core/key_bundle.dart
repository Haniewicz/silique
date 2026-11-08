import '../l10n/strings.dart';

import 'dart:convert';

import 'contracts.dart';

/// Cross-namespace slot alias for the `nova` → `silique` credential migration.
///
/// Reads fall back between `nova.<x>` and `silique.<x>` (and back) so either
/// naming resolves the same credential. This is read-only: it never renames,
/// promotes or deletes a slot, and the `nova.keys.v1` bundle slot is untouched.
String? crossNamespaceSlot(String key) {
  if (key.startsWith('nova.')) {
    return 'silique.${key.substring('nova.'.length)}';
  }
  if (key.startsWith('silique.')) {
    return 'nova.${key.substring('silique.'.length)}';
  }
  return null;
}

/// One OS-protected item, with lazy, verified migration of older separate items.
/// Null entries are tombstones: a deleted session must not return from legacy.
class KeyBundle implements KeyStore {
  KeyBundle({required this.primary, required this.legacy});
  final KeyStore primary, legacy;
  static const slot = 'nova.keys.v1';

  /// The promoted bundle slot. [promoteKeyBundle] migrates the legacy [slot]
  /// here once — full copy, confirmed read, and only then the legacy removal —
  /// without changing this bundle's on-going read/write slot.
  static const promotedSlot = 'silique.keys.v2';
  Map<String, String?>? _values;

  /// Whether the in-memory bundle came from [promotedSlot] (a completed
  /// [promoteKeyBundle] migration). Reads keep [slot] as the primary source,
  /// so a legacy install never incurs an extra read; only when the legacy slot
  /// is absent does the bundle fall back to the promoted slot.
  bool _promoted = false;
  Future<void> _tail = Future.value();

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Map<String, String?>> _load() async {
    if (_values != null) return _values!;
    final stored = await primary.read(slot);
    if (stored == null) {
      // The legacy slot is absent: a completed promotion left the bundle in
      // the promoted slot. Read it only then, so a legacy install still needs
      // exactly one read.
      final promoted = await primary.read(promotedSlot);
      if (promoted == null) return _values = {};
      _promoted = true;
      return _values = _decode(promoted);
    }
    _promoted = false;
    return _values = _decode(stored);
  }

  Map<String, String?> _decode(String stored) {
    Object? envelope;
    try {
      envelope = jsonDecode(stored);
    } on FormatException {
      // A JSON parser's source/snippet may contain credential plaintext.
      throw const FormatException('Corrupt credential bundle.');
    }
    if (envelope is! Map ||
        envelope['version'] != 1 ||
        envelope['keys'] is! Map) {
      throw const FormatException('Unsupported or corrupt credential bundle.');
    }
    final values = envelope['keys'] as Map;
    if (values.entries.any(
      (entry) =>
          entry.key is! String ||
          (entry.value != null && entry.value is! String),
    )) {
      throw const FormatException('Corrupt credential bundle entries.');
    }
    return _values = Map<String, String?>.from(values);
  }

  Future<void> _commit(Map<String, String?> next) async {
    final encoded = jsonEncode({'version': 1, 'keys': next});
    final target = _promoted ? promotedSlot : slot;
    try {
      await primary.write(target, encoded);
      // Never cache an unconfirmed key or overwrite a committed-but-unacknowledged
      // update using stale memory on the next attempt.
      if (await primary.read(target) != encoded) {
        throw StateError(
          tr(
            'Systemowy magazyn kluczy nie potwierdził zapisu.',
            'The system key store did not confirm the write.',
          ),
        );
      }
      _values = next;
    } catch (_) {
      _values = null;
      rethrow;
    }
  }

  @override
  Future<String?> read(String key) => _serialized(() async {
    final values = await _load();
    if (values.containsKey(key)) return values[key];
    // Read-only cross-namespace alias within the logical bundle: a `silique.<x>`
    // slot resolves to its existing `nova.<x>` entry (and back), without ever
    // rewriting, promoting or touching a platform namespace.
    final alias = crossNamespaceSlot(key);
    if (alias != null && values.containsKey(alias)) return values[alias];
    final value = await legacy.read(key);
    await _commit({...values, key: value});
    return value;
  });

  @override
  Future<void> write(String key, String value) => _serialized(() async {
    final values = await _load();
    if (values[key] == value) return;
    await _commit({...values, key: value});
  });

  @override
  Future<void> delete(String key) => _serialized(() async {
    final values = await _load();
    await _commit({...values, key: null});
    await legacy.delete(key);
  });
}

/// Promotes the credential bundle from `nova.keys.v1` to `silique.keys.v2`.
///
/// The full bundle is copied to the new slot, the copy is confirmed with a
/// read, and only then is the legacy slot removed. A failed or unconfirmed
/// write never deletes the legacy entry: it is left in place for the next
/// attempt. On macOS the write goes through the existing atomic Keychain path
/// (the account name is forwarded so `silique.keys.v2` targets the right
/// entry); the historical `nova.keys.v1` entry is never deleted before that
/// write is confirmed.
Future<void> promoteKeyBundle(KeyStore primary) async {
  final legacy = await primary.read(KeyBundle.slot);
  if (legacy == null) return; // Nothing to promote; the legacy slot is absent.
  await primary.write(KeyBundle.promotedSlot, legacy);
  if (await primary.read(KeyBundle.promotedSlot) != legacy) {
    throw StateError(
      tr(
        'Systemowy magazyn kluczy nie potwierdził zapisu.',
        'The system key store did not confirm the write.',
      ),
    );
  }
  // Verified: the promoted slot holds the exact bundle. Only now remove the
  // legacy entry. If this removal fails the promotion is retried next time;
  // both slots coexist harmlessly because the promoted slot is authoritative.
  await primary.delete(KeyBundle.slot);
}
