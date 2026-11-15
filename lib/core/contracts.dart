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

  /// Re-marks every locally known revision of [vaultId] as pending upload, in
  /// insertion (DAG parent-before-child) order. Used when a vault is re-created
  /// on a new server so the whole history — not only the not-yet-acked tail —
  /// is re-uploaded.
  void markAllPending(String vaultId);

  /// Re-marks every locally known image of [vaultId] as pending upload, so a
  /// vault re-created on a fresh server (which has none of its image manifests)
  /// re-uploads its images once more. Idempotent: the server treats a repeated
  /// chunk/manifest PUT as a no-op, so re-uploading an already-acknowledged
  /// image is safe.
  void markAllImagesPending(String vaultId);
  List<Revision> pending(String vaultId);

  /// Every revision id of [vaultId] still marked `pending=1`, in insertion
  /// (DAG parent-before-child) order, without the batch-sized cap of [pending].
  /// The reset retires the whole stuck queue at once, not only one page of it.
  List<String> pendingIds(String vaultId);

  Json? batch(String vaultId);
  void putBatch(String vaultId, Json batch);
  void acknowledge(String vaultId, List<String> ids);
  int cursor(String vaultId);
  void setCursor(String vaultId, int cursor);

  /// Locally recorded sync outcome for [vaultId], or `null` when the vault has
  /// never recorded a pass. Local-only; never synced to the server.
  VaultSyncStatus? syncStatus(String vaultId);

  /// Persists [status] for [vaultId]. Local-only; never synced to the server.
  void putSyncStatus(String vaultId, VaultSyncStatus status);

  /// Number of revisions of [vaultId] still marked `pending=1` (not yet
  /// acknowledged by the server). The UI shows it as "changes waiting to sync".
  int pendingCount(String vaultId);

  /// Number of notes in [vaultId] whose local head count is greater than one.
  /// Computed from the same revision-parent graph the sync pass uses, so the
  /// dialog reports real divergence instead of a SQL storage detail.
  int divergedNoteCount(String vaultId);

  /// Begins a journaled long operation: writes a `running` row for [operation]
  /// before the operation's first step. Local-only; never synced.
  Future<void> startOperation(SyncOperation operation);

  /// Returns every journaled operation, newest first.
  List<SyncOperation> loadOperations();

  /// Settles [operationId] to [status] (`done` or `failed`). Settling an
  /// already-interrupted or settled row is a no-op, never a throw.
  Future<void> settleOperation(String operationId, String status);

  /// Turns every leftover `running` row into `interrupted`. Called once on
  /// [initialize] before the resumable ones are offered for automatic resume.
  Future<void> markInterruptedOperations();

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
