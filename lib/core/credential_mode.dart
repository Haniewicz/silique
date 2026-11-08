import 'contracts.dart';

/// Device-local credential placement. This never changes notebook encryption.
enum CredentialMode { local, system }

/// UI capability; implemented by the one active credential store.
abstract interface class CredentialModeControl {
  CredentialMode get mode;
  bool get cleanupPending;
  Future<void> changeMode(CredentialMode mode);
  Future<void> retryCleanup();
}

/// Durable, private files outside the user-selected notebook location.
/// Implementations serialize processes and publish replacements durably before
/// returning. Names are fixed basenames, never user-provided paths.
abstract interface class CredentialFiles {
  Future<T> locked<T>(Future<T> Function() operation);
  Future<String?> read(String name);
  Future<void> write(String name, String value);
  Future<void> remove(String name);
}

/// The existing OS store, with scoped snapshot/migration support. Snapshots
/// contain effective owned values: tombstones override stale legacy entries.
/// Never enumerate/delete another application's keys or use blanket deleteAll.
abstract interface class SystemCredentialBackend implements KeyStore {
  Future<Map<String, String>> snapshot();
  Future<void> replace(Map<String, String> values);
  Future<void> clear();
}

/// Optional cache lifetime, entered ONLY while holding CredentialFiles.locked.
/// Reuse is confined to that gate acquisition; no authority survives its exit.
abstract interface class ScopedSystemCredentials {
  Future<T> withCredentialScope<T>(Future<T> Function() operation);
}
