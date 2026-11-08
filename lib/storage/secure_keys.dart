import '../l10n/strings.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:win32/win32.dart';

import '../core/contracts.dart';
import '../core/credential_mode.dart';
import '../core/key_bundle.dart';

/// Enumerates the existing application collection, never the whole keyring.
abstract interface class SecureKeyCollection implements KeyStore {
  Future<Map<String, String>> readAll();
}

abstract interface class WindowsCredentialCiphertext {
  Future<T> locked<T>(Future<T> Function() operation);
  Future<Uint8List?> read();
  Future<void> write(Uint8List bytes);
}

abstract interface class WindowsCredentialCodec {
  Uint8List decrypt(Uint8List bytes);
  Uint8List encrypt(Uint8List bytes);
}

/// Uses the plugin's exact DPAPI file/format without its destructive loader.
/// Only the opaque file is replaced; no secondary credential store is created.
class WindowsSecureKeyCollection implements SecureKeyCollection {
  WindowsSecureKeyCollection()
    : this.forBackend(
        file: _WindowsCiphertext(getApplicationSupportDirectory),
        codec: const _DpapiCodec(),
      );
  WindowsSecureKeyCollection.inDirectory(Directory directory)
    : this.forBackend(
        file: _WindowsCiphertext(() async => directory),
        codec: const _DpapiCodec(),
      );
  WindowsSecureKeyCollection.forBackend({
    required WindowsCredentialCiphertext file,
    required WindowsCredentialCodec codec,
  }) : this._(file, codec);
  WindowsSecureKeyCollection._(this._file, this._codec);
  final WindowsCredentialCiphertext _file;
  final WindowsCredentialCodec _codec;

  Future<Map<String, String>> _load() async {
    final bytes = await _file.read();
    if (bytes == null) return {};
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(_codec.decrypt(bytes)));
    } on FormatException {
      throw const FormatException('Corrupt system credential collection.');
    }
    if (decoded is! Map ||
        decoded.entries.any((e) => e.key is! String || e.value is! String)) {
      throw const FormatException('Corrupt system credential collection.');
    }
    return Map<String, String>.from(decoded);
  }

  Future<void> _save(Map<String, String> values) async {
    await _file.write(
      _codec.encrypt(Uint8List.fromList(utf8.encode(jsonEncode(values)))),
    );
    final actual = await _load();
    if (actual.length != values.length ||
        values.entries.any((e) => actual[e.key] != e.value)) {
      throw StateError('System credential write was not confirmed.');
    }
  }

  @override
  Future<Map<String, String>> readAll() => _file.locked(_load);
  @override
  Future<String?> read(String key) =>
      _file.locked(() async => (await _load())[key]);
  @override
  Future<void> write(String key, String value) => _file.locked(() async {
    final values = await _load();
    values[key] = value;
    await _save(values);
  });
  @override
  Future<void> delete(String key) => _file.locked(() async {
    final values = await _load();
    if (!values.containsKey(key)) return;
    values.remove(key);
    await _save(values);
  });
}

class _DpapiCodec implements WindowsCredentialCodec {
  const _DpapiCodec();
  @override
  Uint8List decrypt(Uint8List bytes) => _transform(bytes, false);
  @override
  Uint8List encrypt(Uint8List bytes) => _transform(bytes, true);

  Uint8List _transform(Uint8List bytes, bool encrypting) {
    if (!Platform.isWindows) throw UnsupportedError('Windows DPAPI required');
    return using((arena) {
      final input = arena<Uint8>(max(1, bytes.length));
      input.asTypedList(bytes.length).setAll(0, bytes);
      final source = arena<CRYPT_INTEGER_BLOB>();
      source.ref.cbData = bytes.length;
      source.ref.pbData = input;
      final output = arena<CRYPT_INTEGER_BLOB>();
      // Exactly the plugin's DPAPI domain: current user, no entropy or flags.
      final result = encrypting
          ? CryptProtectData(source, null, null, null, 0, output)
          : CryptUnprotectData(source, null, null, null, 0, output);
      try {
        if (!result.value || output.ref.pbData.address == 0) {
          throw StateError(
            'Windows system credential protection is unavailable.',
          );
        }
        return Uint8List.fromList(
          output.ref.pbData.asTypedList(output.ref.cbData),
        );
      } finally {
        input.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
        if (output.ref.pbData.address != 0) {
          output.ref.pbData
              .asTypedList(output.ref.cbData)
              .fillRange(0, output.ref.cbData, 0);
          LocalFree(HLOCAL(output.ref.pbData.cast()));
        }
      }
    });
  }
}

/// This deliberately does not call DpapiJsonFileMapStorage.load: that loader
/// deletes ciphertext on decode errors and treats some read errors as empty.
class _WindowsCiphertext implements WindowsCredentialCiphertext {
  _WindowsCiphertext(this._directory);
  final Future<Directory> Function() _directory;
  File? _active;
  Future<void> _tail = Future.value();

  @override
  Future<T> locked<T>(Future<T> Function() operation) {
    final result = _tail.then((_) async {
      if (!Platform.isWindows) {
        throw UnsupportedError('Windows filesystem required');
      }
      final directory = await _directory();
      await directory.create(recursive: true);
      final lockFile = File(
        '${directory.path}/.silique-system-credentials.lock',
      );
      await _rejectLink(lockFile.path);
      final lock = await lockFile.open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.blockingExclusive);
        _active = File('${directory.path}/flutter_secure_storage.dat');
        await _rejectLink(_active!.path);
        return await operation();
      } finally {
        _active = null;
        await lock.close();
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _rejectLink(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw FileSystemException('Unsafe system credential file', path);
    }
  }

  @override
  Future<Uint8List?> read() async {
    final file = _active!;
    try {
      return await file.readAsBytes();
    } on FileSystemException catch (error) {
      // Only ERROR_FILE_NOT_FOUND means fresh. Access denied, sharing, I/O and
      // missing parent errors are not permission to create replacement keys.
      if (error.osError?.errorCode == 2) return null;
      rethrow;
    }
  }

  @override
  Future<void> write(Uint8List bytes) async {
    final file = _active!;
    final random = Random.secure();
    final suffix = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final staged = File('${file.path}.$suffix.tmp');
    try {
      // The staging file contains DPAPI ciphertext only, never plaintext.
      await staged.writeAsBytes(bytes, flush: true);
      await _rejectLink(file.path);
      using((arena) {
        final result = MoveFileEx(
          PCWSTR(staged.path.toNativeUtf16(allocator: arena)),
          PCWSTR(file.path.toNativeUtf16(allocator: arena)),
          MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        );
        if (!result.value) {
          throw FileSystemException(
            'Atomic system credential replacement failed',
            file.path,
          );
        }
      });
    } finally {
      if (await staged.exists()) await staged.delete();
    }
  }
}

class SecureKeys implements SystemCredentialBackend, ScopedSystemCredentials {
  const SecureKeys() : _injected = null;

  /// Exercises the production migration path without a platform keyring.
  SecureKeys.forBackend({
    required SecureKeyCollection legacy,
    KeyStore? primary,
  }) : _injected = _SecureBackend(legacy, primary);

  final _SecureBackend? _injected;
  static final _default = _SecureBackend(
    Platform.isWindows
        ? WindowsSecureKeyCollection()
        : const _SystemKeys(
            FlutterSecureStorage(
              aOptions: AndroidOptions(resetOnError: false),
              mOptions: MacOsOptions(usesDataProtectionKeychain: false),
            ),
          ),
    Platform.isMacOS
        ? const _SystemKeys(
            FlutterSecureStorage(
              mOptions: MacOsOptions(
                accountName: 'pl.novanotes.keys',
                usesDataProtectionKeychain: false,
              ),
            ),
            atomicMacWrite: true,
          )
        : null,
  );
  _SecureBackend get _backend => _injected ?? _default;

  @override
  Future<T> withCredentialScope<T>(Future<T> Function() operation) =>
      _backend.withCredentialScope(operation);

  @override
  Future<String?> read(String key) => _backend.read(key);
  @override
  Future<void> write(String key, String value) => _backend.write(key, value);
  @override
  Future<void> delete(String key) => _backend.delete(key);
  @override
  Future<Map<String, String>> snapshot() => _backend.snapshot();
  @override
  Future<void> replace(Map<String, String> values) =>
      _backend.replace(Map.of(values));
  @override
  Future<void> clear() => _backend.clear();
}

class _SecureScope {
  bool accepting = true;
  KeyStore? bundle;
  Future<void> pending = Future.value();
}

class _SecureBackend
    implements SystemCredentialBackend, ScopedSystemCredentials {
  _SecureBackend(this._collection, this._primary);
  final SecureKeyCollection _collection;
  final KeyStore? _primary;
  final Object _scopeKey = Object();
  Future<void> _tail = Future.value();

  _SecureScope? get _scope => Zone.current[_scopeKey] as _SecureScope?;

  @override
  Future<T> withCredentialScope<T>(Future<T> Function() operation) async {
    if (_scope case final scope?) {
      if (!scope.accepting) {
        throw StateError('Credential transaction has ended');
      }
      return operation();
    }
    final scope = _SecureScope();
    try {
      return await runZoned(() {
        _resetBundle();
        return operation();
      }, zoneValues: {_scopeKey: scope});
    } finally {
      scope.accepting = false;
      // Detached/late callbacks cannot extend the scope, but native calls
      // already in flight must finish before ManagedKeys releases its gate.
      await scope.pending;
      scope.bundle = null;
    }
  }

  void _resetBundle() {
    _scope!.bundle = _primary == null
        ? null
        : KeyBundle(primary: _primary, legacy: _collection);
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final scope = _scope;
    if (scope != null && !scope.accepting) {
      return Future.error(StateError('Credential transaction has ended'));
    }
    final result = _tail.then((_) async {
      // A scope is shared only inside one ManagedKeys cross-process gate.
      // Ungated/direct calls retain the old fresh-load-per-operation contract.
      if (scope == null) return withCredentialScope(operation);
      // Already admitted work drains under the gate even after admission closes.
      try {
        return await operation();
      } catch (_) {
        _resetBundle();
        rethrow;
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    if (scope != null) scope.pending = _tail;
    return result;
  }

  KeyStore get _store => _scope!.bundle ?? _collection;
  @override
  Future<String?> read(String key) => _serialized(() => _store.read(key));
  @override
  Future<void> write(String key, String value) =>
      _serialized(() => _store.write(key, value));
  @override
  Future<void> delete(String key) => _serialized(() => _store.delete(key));

  Future<Map<String, String?>> _bundle() async {
    final stored = await _primary?.read(KeyBundle.slot);
    if (stored == null) return {};
    Object? envelope;
    try {
      envelope = jsonDecode(stored);
    } on FormatException {
      throw const FormatException('Corrupt credential bundle.');
    }
    if (envelope is! Map ||
        envelope['version'] != 1 ||
        envelope['keys'] is! Map) {
      throw const FormatException('Unsupported or corrupt credential bundle.');
    }
    final values = envelope['keys'] as Map;
    if (values.entries.any(
      (e) => e.key is! String || (e.value != null && e.value is! String),
    )) {
      throw const FormatException('Corrupt credential bundle entries.');
    }
    return Map<String, String?>.from(values);
  }

  @override
  Future<Map<String, String>> snapshot() => _serialized(_snapshot);

  Future<Map<String, String>> _snapshot() async {
    // Decode first: invalid/unknown bundles never fall back to legacy.
    final bundle = await _bundle();
    final values = {
      for (final entry in (await _collection.readAll()).entries)
        if (_owned(entry.key)) entry.key: entry.value,
    };
    for (final entry in bundle.entries) {
      if (!_owned(entry.key)) continue;
      if (entry.value == null) {
        values.remove(entry.key);
      } else {
        values[entry.key] = entry.value!;
      }
    }
    return values;
  }

  static bool _owned(String key) =>
      const {
        'nova.localKey',
        'nova.session',
        'nova.deviceName',
        'nova.lastVault',
        'silique.hidden.salt',
        'silique.hidden.wrap',
        'silique.hidden.check',
        'silique.hidden.autoLock',
        'silique.hidden.lockOnBackground',
      }.contains(key) ||
      (key.startsWith('nova.account.') &&
          key.length > 'nova.account.'.length) ||
      (key.startsWith('nova.identity.') &&
          key.length > 'nova.identity.'.length);

  @override
  Future<void> replace(Map<String, String> values) => _serialized(() async {
    if (values.keys.any((key) => !_owned(key))) {
      throw ArgumentError('Replacement includes non-credential keys.');
    }
    final current = await _snapshot();
    try {
      if (_primary case final primary?) {
        final previous = await _bundle();
        final legacy = await _collection.readAll();
        final next = <String, String?>{
          ...previous,
          for (final key in {...previous.keys, ...legacy.keys})
            if (_owned(key)) key: null,
          ...values,
        };
        final encoded = jsonEncode({'version': 1, 'keys': next});
        await primary.write(KeyBundle.slot, encoded);
        if (await primary.read(KeyBundle.slot) != encoded) {
          throw StateError('System credential bundle write was not confirmed.');
        }
      } else {
        for (final entry in values.entries) {
          await _collection.write(entry.key, entry.value);
        }
        for (final key in current.keys) {
          if (!values.containsKey(key)) await _collection.delete(key);
        }
      }
      final actual = await _snapshot();
      if (actual.length != values.length ||
          values.entries.any((e) => actual[e.key] != e.value)) {
        throw StateError('System credential replacement was not confirmed.');
      }
    } finally {
      // Reload even after a lost acknowledgement of a committed replacement.
      _resetBundle();
    }
  });

  @override
  Future<void> clear() => _serialized(() async {
    try {
      final bundle = await _bundle();
      for (final key in (await _collection.readAll()).keys.where(_owned)) {
        await _collection.delete(key);
      }
      if ((await _collection.readAll()).keys.any(_owned)) {
        throw StateError('System credential cleanup was not confirmed.');
      }
      // Keep tombstones until stale legacy entries are verifiably absent.
      if (_primary case final primary?) {
        final foreign = Map<String, String?>.of(bundle)
          ..removeWhere((key, _) => _owned(key));
        final String? expected;
        if (foreign.isEmpty) {
          expected = null;
          await primary.delete(KeyBundle.slot);
        } else {
          expected = jsonEncode({'version': 1, 'keys': foreign});
          await primary.write(KeyBundle.slot, expected);
        }
        if (await primary.read(KeyBundle.slot) != expected) {
          throw StateError(
            'System credential bundle cleanup was not confirmed.',
          );
        }
      }
    } finally {
      _resetBundle();
    }
  });
}

class _SystemKeys implements SecureKeyCollection {
  const _SystemKeys(this._storage, {this.atomicMacWrite = false});
  final FlutterSecureStorage _storage;
  final bool atomicMacWrite;

  static const MethodChannel _keysChannel = MethodChannel('silique.notes/keys');

  /// At most one native relabel call per process. Combined with the native
  /// one-shot flag, this avoids repeated Keychain prompts on reads.
  static bool _relabelAttempted = false;

  /// Migrates the keychain entry's label in place. Non-critical and idempotent:
  /// a missing native method (older host) or any platform error must never turn
  /// a read into a failure, and it is a no-op off macOS.
  Future<void> _relabelIfMacOS() async {
    if (!Platform.isMacOS || _relabelAttempted) return;
    _relabelAttempted = true;
    try {
      await _keysChannel.invokeMethod<void>('relabelBundle');
    } on MissingPluginException {
      // Older native host does not expose relabelBundle; the write path still
      // migrates the label, so this is harmless.
    } on PlatformException {
      // Label is non-critical; never propagate a relabel failure.
    }
  }

  @override
  Future<Map<String, String>> readAll() async {
    if (!Platform.isMacOS) return _storage.readAll();
    // The file-based keychain rejects kSecMatchLimitAll combined with
    // kSecReturnData (errSecParam -50), and plugin readAll always requests both.
    // Enumerate attributes through the native channel, then read each key.
    final keys = await _keysChannel.invokeListMethod<String>('listKeys') ??
        const <String>[];
    final values = <String, String>{};
    for (final key in keys) {
      final value = await _storage.read(key: key);
      if (value != null) values[key] = value;
    }
    await _relabelIfMacOS();
    return values;
  }

  @override
  Future<String?> read(String key) async {
    final value = await _storage.read(key: key);
    await _relabelIfMacOS();
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    if (atomicMacWrite && Platform.isMacOS) {
      // The plugin retries failed updates by deleting the old item. Our key
      // bundle must preserve the existing item on EVERY failed update instead.
      // The account name is forwarded so a promoted `silique.keys.v2` bundle is
      // written to the right Keychain entry; legacy writes keep `nova.keys.v1`.
      await _keysChannel.invokeMethod<void>(
        'writeBundle',
        {'value': value, 'account': key},
      );
    } else {
      await _storage.write(key: key, value: value);
    }
    if (await _storage.read(key: key) != value) {
      throw StateError(
        tr(
          'Systemowy magazyn kluczy nie potwierdził zapisu. Dane nie będą zapisywane bez ochrony.',
          'The system key store did not confirm the write. Data will not be saved without protection.',
        ),
      );
    }
  }

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
