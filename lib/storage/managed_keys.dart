import 'dart:convert';

import '../core/contracts.dart';
import '../core/credential_mode.dart';
import '../core/key_bundle.dart';

/// One authoritative credential collection, selected by a private durable state.
/// Local JSON is private app data, not OS-backed encrypted secret storage.
class ManagedKeys implements KeyStore, CredentialModeControl {
  ManagedKeys({required this._files, required this._system});

  static const stateFile = 'state.json';
  static const localFile = 'local.json';
  final CredentialFiles _files;
  final SystemCredentialBackend _system;
  bool _ready = false;
  Map<String, dynamic>? _state;

  @override
  CredentialMode get mode =>
      CredentialMode.values.byName(_state!['active'] as String);
  @override
  bool get cleanupPending => _state?['pending'] != null;

  Future<T> _locked<T>(Future<T> Function() operation) => _files.locked(() {
    if (_system case final ScopedSystemCredentials system) {
      return system.withCredentialScope(operation);
    }
    return operation();
  });

  Future<void> initialize({
    CredentialMode? firstRunMode,
    bool requireExistingKey = false,
  }) => _locked(() async {
    _ready = false;
    final raw = await _files.read(stateFile);
    if (raw == null) {
      if (await _files.read(localFile) != null) {
        throw StateError(
          'Credential authority is missing; recovery is required',
        );
      }
      final values = await _system.snapshot();
      if (requireExistingKey && !values.containsKey('nova.localKey')) {
        throw StateError('Existing installation key is required');
      }
      await _save({
        'version': 1,
        'active': 'system',
        'established': values.containsKey('nova.localKey'),
        if (firstRunMode == CredentialMode.local) 'initialChoice': 'local',
      });
    } else {
      _state = _decodeState(raw);
    }
    if (_state!['initialChoice'] == 'local') {
      // Keep the explicit first-run choice durable even before staging starts.
      // A partial target can be discarded, but the choice survives that cleanup.
      if (cleanupPending) await _finishCleanup();
      await _migrate(CredentialMode.local);
    }
    await _validateActive();
    if (requireExistingKey) {
      // Existing startup needs one key, not a migration snapshot that rereads
      // every preserved legacy Keychain item (including inactive accounts).
      final key = mode == CredentialMode.system
          ? await _system.read('nova.localKey')
          : (await _snapshot(mode))['nova.localKey'];
      if (key == null) {
        throw StateError('Existing installation key is required');
      }
    }
    _ready = true;
  });

  Map<String, dynamic> _decodeState(String? raw) {
    try {
      final state = Map<String, dynamic>.from(jsonDecode(raw!) as Map);
      if (state['version'] != 1 ||
          !['local', 'system'].contains(state['active']) ||
          state['established'] is! bool) {
        throw const FormatException();
      }
      final pending = state['pending'];
      if (pending != null &&
          (pending is! Map ||
              !['local', 'system'].contains(pending['from']) ||
              !['local', 'system'].contains(pending['to']) ||
              pending['from'] == pending['to'] ||
              !['staging', 'cleanup'].contains(pending['phase']) ||
              state['active'] !=
                  pending[pending['phase'] == 'staging' ? 'from' : 'to'])) {
        throw const FormatException();
      }
      if (state.containsKey('initialChoice') &&
          (state['initialChoice'] != 'local' ||
              state['active'] != 'system' ||
              (pending != null &&
                  (pending['to'] != 'local' ||
                      pending['phase'] != 'staging')))) {
        throw const FormatException();
      }
      return state;
    } catch (_) {
      throw StateError('Credential authority is missing or invalid');
    }
  }

  Future<void> _validateActive() async {
    final String? key;
    if (mode == CredentialMode.local) {
      key = (await _snapshot(mode))['nova.localKey'];
    } else if (_state!['established'] == true) {
      key = await _system.read('nova.localKey');
    } else {
      return;
    }
    if (_state!['established'] == true && key == null) {
      throw StateError(
        'Established installation key is missing; recovery is required',
      );
    }
  }

  Future<void> _save(Map<String, dynamic> state) async {
    final encoded = jsonEncode(state);
    try {
      await _files.write(stateFile, encoded);
      final durable = await _files.read(stateFile);
      _state = _decodeState(durable);
      if (durable != encoded) {
        throw StateError('Credential authority replacement was not verified');
      }
    } catch (_) {
      // A replacement can commit and then lose its acknowledgment. Never
      // report the old mode or perform source cleanup based on volatile intent.
      try {
        _state = _decodeState(await _files.read(stateFile));
      } catch (_) {
        _ready = false;
      }
      rethrow;
    }
  }

  Future<T> _operation<T>(
    Future<T> Function() operation, {
    bool allowStaging = false,
  }) => _locked(() async {
    if (!_ready) throw StateError('Credential storage is not initialized');
    _state = _decodeState(await _files.read(stateFile));
    await _validateActive();
    if (!allowStaging && (_state!['pending'] as Map?)?['phase'] == 'staging') {
      throw StateError(
        'Interrupted migration must be discarded with retryCleanup',
      );
    }
    return operation();
  });

  Future<Map<String, String>> _snapshot(CredentialMode source) async {
    if (source == CredentialMode.system) return _system.snapshot();
    try {
      final raw = await _files.read(localFile);
      return Map<String, String>.from(jsonDecode(raw!) as Map);
    } catch (_) {
      throw StateError('Active local credential file is missing or invalid');
    }
  }

  Future<void> _replace(
    CredentialMode target,
    Map<String, String> values,
  ) async {
    if (target == CredentialMode.system) {
      await _system.replace(values);
    } else {
      await _files.write(localFile, jsonEncode(values));
    }
    final copied = await _snapshot(target);
    if (values.length != copied.length ||
        values.entries.any((entry) => copied[entry.key] != entry.value)) {
      throw StateError('Credential replacement verification failed');
    }
  }

  Future<void> _clear(CredentialMode source) async {
    if (source == CredentialMode.system) {
      await _system.clear();
      if ((await _system.snapshot()).isNotEmpty) {
        throw StateError('System credential cleanup was not verified');
      }
    } else {
      await _files.remove(localFile);
      if (await _files.read(localFile) != null) {
        throw StateError('Local credential cleanup was not verified');
      }
    }
  }

  Future<void> _migrate(CredentialMode target) async {
    if (cleanupPending) {
      throw StateError(
        'Resolve pending credential cleanup before switching again',
      );
    }
    final source = mode;
    if (target == source) return;
    final pending = {
      'from': source.name,
      'to': target.name,
      'phase': 'staging',
    };
    await _save({..._state!, 'pending': pending});
    final values = await _snapshot(source);
    if (_state!['established'] == true &&
        !values.containsKey('nova.localKey')) {
      throw StateError('Source snapshot is missing the installation key');
    }
    await _replace(target, values);
    await _save(
      {
        ..._state!,
        'active': target.name,
        'pending': {...pending, 'phase': 'cleanup'},
      }..remove('initialChoice'),
    );
    await _finishCleanup();
  }

  Future<void> _finishCleanup() async {
    final pending = _state!['pending'] as Map?;
    if (pending == null) return;
    final phase = pending['phase'];
    await _clear(
      CredentialMode.values.byName(
        pending[phase == 'staging' ? 'to' : 'from'] as String,
      ),
    );
    await _save({..._state!}..remove('pending'));
  }

  @override
  Future<String?> read(String key) => _operation(() async {
    if (mode == CredentialMode.system) return _system.read(key);
    final snapshot = await _snapshot(mode);
    final value = snapshot[key];
    if (value != null) return value;
    // Read-only cross-namespace alias within the local snapshot: a `silique.<x>`
    // slot resolves to its existing `nova.<x>` entry (and back). The local JSON
    // slot names are never rewritten, promoted or deleted.
    final alias = crossNamespaceSlot(key);
    return alias == null ? null : snapshot[alias];
  });
  @override
  Future<void> write(String key, String value) => _operation(() async {
    if (key == 'nova.localKey' && _state!['established'] != true) {
      // Fence key creation first. An interrupted creation requires recovery,
      // rather than letting a later start mint a different installation key.
      await _save({..._state!, 'established': true});
    }
    if (mode == CredentialMode.system) return _system.write(key, value);
    await _replace(mode, {...await _snapshot(mode), key: value});
  });
  @override
  Future<void> delete(String key) => _operation(() async {
    if (key == 'nova.localKey' && _state!['established'] == true) {
      throw StateError('The installation key cannot be deleted');
    }
    if (mode == CredentialMode.system) return _system.delete(key);
    await _replace(mode, {...await _snapshot(mode)}..remove(key));
  });
  @override
  Future<void> changeMode(CredentialMode mode) =>
      _operation(() => _migrate(mode));
  @override
  Future<void> retryCleanup() => _operation(_finishCleanup, allowStaging: true);
}
