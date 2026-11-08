import 'models.dart';

abstract interface class KeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

abstract interface class CryptoProvider {
  List<int> randomKey();
  Future<String> seal(List<int> key, String plaintext, String context);
  Future<String> open(List<int> key, String envelope, String context);
  Future<String> openCompat(
    List<int> key,
    String envelope,
    String context,
    String legacyContext,
  );
  Future<List<int>> passwordKey(String password, List<int> salt);
  Future<String> stableId(List<int> key, String value);
  Future<Json> createIdentity();
  Future<List<int>> pairingKey(Json identity, String peerKey, String context);
}

abstract interface class SyncTransport {
  Future<Json> request(String method, String path, {Json? body});
}

/// Native adapters implement persistence; a future OPFS/IndexedDB adapter can
/// implement the same interface without importing dart:io into the domain.
abstract interface class NoteStorage {
  /// Durable caller-owned deletion intents; pending intent is not a tombstone.
  Future<Map<String, String>> deletionIntents();

  /// Call only after fencing new work and draining already accepted writers.
  Future<void> beginVaultDeletion(String vaultId, String payload);

  /// Cancels pending intent, never an irreversible tombstone.
  Future<void> cancelVaultDeletion(String vaultId);
  bool isVaultDeleted(String vaultId);

  /// Irreversible, idempotent local retirement; may throw after SQL commit.
  /// Retry after cleanup failure; pending remote intents alone are not erased.
  Future<void> eraseVault(String vaultId);
  List<Vault> vaults();
  void putVault(Vault vault);
  Map<String, String> documents(String vaultId);
  void putDocument(String vaultId, String noteId, String document);
  void removeDocument(String vaultId, String noteId);
  List<Revision> revisions(String vaultId, {String? noteId});
  void putRevision(Revision revision, {bool pending = false});
  List<Revision> pending(String vaultId);
  Json? batch(String vaultId);
  void putBatch(String vaultId, Json batch);
  void acknowledge(String vaultId, List<String> ids);
  int cursor(String vaultId);
  void setCursor(String vaultId, int cursor);
  void atomic(void Function() operation);
  Future<void> mirror(Note note);
  Future<void> eraseNote(
    String vaultId,
    String noteId, {
    List<String> retainImages = const [],
    String? hiddenDocument,
  });
  Json? imageAsset(String vaultId, String id);
  List<Json> pendingImages(String vaultId);
  void putImageAsset(
    String vaultId,
    String noteId,
    String id,
    String manifest, {
    required bool uploaded,
  });
  void putImageChunk(String vaultId, String id, int index, String payload);
  String? imageChunk(String vaultId, String id, int index);
  void markImageUploaded(String vaultId, String id);
  Future<void> close();
}

abstract interface class UpdateProvider {
  Future<Uri> releasePage();
}
