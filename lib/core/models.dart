import 'dart:convert';

typedef Json = Map<String, dynamic>;

class Note {
  const Note({
    required this.id,
    required this.vaultId,
    required this.title,
    required this.body,
    required this.updatedAt,
    DateTime? createdAt,
    this.folder = '',
    this.deleted = false,
    this.favorite = false,
    this.journalDate,
    this.conflict = false,
    this.hidden = false,
    this.tags = const [],
  }) : createdAt = createdAt ?? updatedAt;
  final String id, vaultId, title, body, folder;
  final DateTime updatedAt;
  final DateTime createdAt;
  final bool deleted, favorite, conflict;

  /// Hidden plaintext lives only in the separately password-encrypted store.
  /// Sync transports an additional encrypted envelope, never ordinary note
  /// fields; only an explicit reveal creates a normal vault document.
  final bool hidden;
  final String? journalDate;
  final List<String> tags;
  Note copyWith({
    String? title,
    String? body,
    String? folder,
    bool? deleted,
    bool? favorite,
    bool? conflict,
    bool? hidden,
    List<String>? tags,
  }) => Note(
    id: id,
    vaultId: vaultId,
    title: title ?? this.title,
    body: body ?? this.body,
    folder: folder ?? this.folder,
    deleted: deleted ?? this.deleted,
    favorite: favorite ?? this.favorite,
    journalDate: journalDate,
    conflict: conflict ?? this.conflict,
    hidden: hidden ?? this.hidden,
    tags: tags ?? this.tags,
    updatedAt: DateTime.now().toUtc(),
    createdAt: createdAt,
  );
  Json toJson() => {
    'id': id,
    'vaultId': vaultId,
    'title': title,
    'body': body,
    'folder': folder,
    'updatedAt': updatedAt.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
    'deleted': deleted,
    'favorite': favorite,
    'journalDate': journalDate,
    'conflict': conflict,
    'hidden': hidden,
    'tags': tags,
  };
  factory Note.fromJson(Json j) => Note(
    id: j['id'] as String,
    vaultId: j['vaultId'] as String,
    title: j['title'] as String,
    body: j['body'] as String,
    folder: j['folder'] as String? ?? '',
    updatedAt: DateTime.parse(j['updatedAt'] as String),
    createdAt: DateTime.parse((j['createdAt'] ?? j['updatedAt']) as String),
    deleted: j['deleted'] as bool? ?? false,
    favorite: j['favorite'] as bool? ?? false,
    journalDate: j['journalDate'] as String?,
    conflict: j['conflict'] as bool? ?? false,
    hidden: j['hidden'] as bool? ?? false,
    tags: (j['tags'] as List? ?? []).cast<String>(),
  );
}

class Vault {
  Vault({
    required this.id,
    required this.name,
    required this.mode,
    required this.keyWrap,
    required this.localWrap,
    required this.metadata,
    this.version = 0,
    this.syncEnabled = false,
    this.owner,
    this.folderBase = '',
  });
  final String id, mode;
  String name, keyWrap, localWrap, metadata;
  int version;
  bool syncEnabled;
  String? owner;

  /// Encrypted snapshot of the folder list the server confirmed last.
  ///
  /// Folder names are never stored in clear text: protected vaults would leak
  /// them through the local database otherwise. An empty value means "unknown",
  /// which is treated as the server copy during the next merge.
  String folderBase;
  bool get protected => mode == 'password';
  Json toJson() => {
    'id': id,
    'name': protected ? 'Chroniony vault' : name,
    'mode': mode,
    'keyWrap': keyWrap,
    'localWrap': localWrap,
    'metadata': metadata,
    'version': version,
    'syncEnabled': syncEnabled,
    'owner': owner,
    'folderBase': folderBase,
  };
  factory Vault.fromJson(Json j) => Vault(
    id: j['id'] as String,
    name: j['name'] as String,
    mode: j['mode'] as String,
    keyWrap: j['keyWrap'] as String,
    localWrap: j['localWrap'] as String,
    metadata: j['metadata'] as String,
    version: j['version'] as int? ?? 0,
    syncEnabled: j['syncEnabled'] as bool? ?? false,
    owner: j['owner'] as String?,
    folderBase: j['folderBase'] as String? ?? '',
  );
}

/// The account id a `Vault.owner` value refers to, without any server
/// component. Historical values were `${server}|${userId}`; everything after
/// the first `|` is the account id. A value without a separator is already a
/// bare account id. `null` (never bound) yields the empty string.
String vaultOwnerUserId(String? owner) {
  if (owner == null) return '';
  final separator = owner.indexOf('|');
  return separator < 0 ? owner : owner.substring(separator + 1);
}

/// The server host recorded in a historical owner value, or `null` when the
/// value carries no server component (provenance only, never a sync gate).
String? vaultOwnerServer(String? owner) {
  if (owner == null) return null;
  final separator = owner.indexOf('|');
  return separator < 0 ? null : owner.substring(0, separator);
}

class Revision {
  const Revision({
    required this.id,
    required this.vaultId,
    required this.noteId,
    required this.parents,
    required this.payload,
    this.seq = 0,
  });
  final String id, vaultId, noteId, payload;
  final List<String> parents;
  final int seq;
  Json toWire() => {
    'id': id,
    'noteId': noteId,
    'parents': parents,
    'payload': payload,
  };
  String get aad => 'silique:2:note:$vaultId:$noteId:$id:${jsonEncode(parents)}';
  String get legacyAad =>
      'nova:1:note:$vaultId:$noteId:$id:${jsonEncode(parents)}';
}

class Session {
  Session({
    required this.server,
    required this.token,
    required this.userId,
    required this.email,
  });
  final String server, token, userId, email;

  /// Account identity without the server component. This is what `Vault.owner`
  /// stores: provenance of "which account this was last synced with", never a
  /// gate on the sync path. Switching the server is an ordinary destination
  /// change and must not change a vault's identity or its owner value.
  String get owner => userId;

  /// The server-qualified name that was historically used (and is still used)
  /// to derive the local account master-key slot. It intentionally keeps the
  /// `${server}|` prefix so the `nova.account.*` slot family stays stable for
  /// existing installs and the branding/pinning rules.
  String get accountSlotOwner => '$server|$userId';

  Json toJson() => {
    'server': server,
    'token': token,
    'userId': userId,
    'email': email,
  };
  factory Session.fromJson(Json j) => Session(
    server: j['server'] as String,
    token: j['token'] as String,
    userId: j['userId'] as String,
    email: j['email'] as String,
  );
}

/// Locally recorded outcome of the last sync pass per vault. Never synced to
/// the server: it exists so the UI can explain what the last pass actually did
/// for each vault instead of flattening every failure into "offline".
class VaultSyncStatus {
  VaultSyncStatus({
    this.lastSuccessAt,
    this.lastAttemptAt,
    this.lastError,
    this.lastErrorAt,
    this.sourceEpochApplied = 0,
    this.sourceHoldEpoch,
    this.sourceHoldDevice,
    this.sourceHoldAt,
  });

  final DateTime? lastSuccessAt;
  final DateTime? lastAttemptAt;
  final String? lastError;
  final DateTime? lastErrorAt;

  /// The highest source-of-truth epoch this device has applied (adopted or
  /// reset into). A pull that finds a marker with a higher epoch places the
  /// vault into the hold until the owner decides.
  final int sourceEpochApplied;

  /// The marker epoch the vault is currently held on, or null when not held.
  final int? sourceHoldEpoch;

  /// The device name (or id, as a fallback) carried by the held marker.
  final String? sourceHoldDevice;

  /// The ISO timestamp carried by the held marker's `at` field.
  final String? sourceHoldAt;

  /// True when the most recent recorded failure is newer than the most recent
  /// success (or there was never a success). A vault that has never attempted
  /// a sync is not "failing" yet — nothing has gone wrong.
  bool get failing =>
      lastError != null &&
      (lastSuccessAt == null ||
          (lastErrorAt != null && lastErrorAt!.isAfter(lastSuccessAt!)));

  /// True when a pull observed a source-of-truth marker newer than what this
  /// device has applied, and the owner has not yet decided. A held vault is
  /// waiting for a decision, not failing.
  bool get held => sourceHoldEpoch != null && sourceHoldEpoch! > sourceEpochApplied;

  Json toJson() => {
    'lastSuccessAt': lastSuccessAt?.toIso8601String(),
    'lastAttemptAt': lastAttemptAt?.toIso8601String(),
    'lastError': lastError,
    'lastErrorAt': lastErrorAt?.toIso8601String(),
    'sourceEpochApplied': sourceEpochApplied,
    'sourceHoldEpoch': sourceHoldEpoch,
    'sourceHoldDevice': sourceHoldDevice,
    'sourceHoldAt': sourceHoldAt,
  };

  factory VaultSyncStatus.fromJson(Json j) => VaultSyncStatus(
    lastSuccessAt: j['lastSuccessAt'] == null
        ? null
        : DateTime.parse(j['lastSuccessAt'] as String),
    lastAttemptAt: j['lastAttemptAt'] == null
        ? null
        : DateTime.parse(j['lastAttemptAt'] as String),
    lastError: j['lastError'] as String?,
    lastErrorAt: j['lastErrorAt'] == null
        ? null
        : DateTime.parse(j['lastErrorAt'] as String),
    sourceEpochApplied: j['sourceEpochApplied'] as int? ?? 0,
    sourceHoldEpoch: j['sourceHoldEpoch'] as int?,
    sourceHoldDevice: j['sourceHoldDevice'] as String?,
    sourceHoldAt: j['sourceHoldAt'] as String?,
  );
}

/// A vault that a sync pass decided not to push/pull, with the reason the UI
/// can show instead of the previous silent skip.
///
/// [owner] and [sessionOwner] carry both sides of an owner mismatch so the
/// account tab can name the account the vault still belongs to and the account
/// the app is currently signed in as.
class SyncIssue {
  const SyncIssue({
    required this.vaultId,
    required this.reason,
    this.owner,
    this.sessionOwner,
  });

  /// Reasons: `ownerMismatch`, `syncDisabled`, `locked`, `deletionPending`,
  /// `tombstoned`.
  static const ownerMismatch = 'ownerMismatch';
  static const syncDisabled = 'syncDisabled';
  static const locked = 'locked';
  static const deletionPending = 'deletionPending';

  /// The vault ID is permanently tombstones on the server (`410 vault_deleted`)
  /// or listed in `deletedVaults`. It must not be silently recreated; the UI
  /// offers an explicit, warned recreation instead.
  static const tombstoned = 'tombstoned';

  final String vaultId;
  final String reason;
  final String? owner;
  final String? sessionOwner;
}

/// Outcome of a source-of-truth reset (`resetToLocalSourceOfTruth`). Purely a
/// report — the operation itself mutates storage and pushes revisions; every
/// field here only summarises what happened so the UI can explain it.
class VaultResetReport {
  const VaultResetReport({
    required this.notesRewritten,
    required this.deletionsWritten,
    required this.copiesKept,
    required this.headsMerged,
    required this.remainingDiverged,
    required this.remainingPending,
    required this.hiddenSkipped,
  });

  /// Number of notes whose local (non-deleted) document was written as the new
  /// single source of truth over their former heads.
  final int notesRewritten;

  /// Number of deletion revisions written: locally deleted notes plus
  /// remote-only heads (heads with no local document).
  final int deletionsWritten;

  /// Number of losing-version copies materialised as conflict notes.
  final int copiesKept;

  /// Total number of former head revisions retired by the reset.
  final int headsMerged;

  /// Notes still showing more than one head after the final pull. A fully
  /// successful reset reports exactly zero.
  final int remainingDiverged;

  /// Revisions still pending after the reset's final drain. A fully successful
  /// reset reports exactly zero; a non-zero value means the reset is incomplete.
  final int remainingPending;

  /// Hidden notes that the reset deliberately left untouched.
  final int hiddenSkipped;
}

/// One journaled long sync operation (full pull, flush, reset, adopt). The row
/// is written before the operation starts and settled in `finally`, so a crash
/// or a process death leaves an observable `running` row that startup turns into
/// `interrupted`. Local-only; never synced to the server.
class SyncOperation {
  const SyncOperation({
    required this.id,
    required this.kind,
    required this.startedAt,
    required this.status,
    this.vaultId,
    this.data,
  });

  /// Journal kinds, matching the long operations the notebook journals.
  static const kindPull = 'pull';
  static const kindFlush = 'flush';
  static const kindReset = 'reset';
  static const kindAdopt = 'adopt';

  /// Journal status values.
  static const statusRunning = 'running';
  static const statusDone = 'done';
  static const statusFailed = 'failed';
  static const statusInterrupted = 'interrupted';

  final String id;
  final String kind;
  final String? vaultId;
  final String? data;
  final DateTime startedAt;
  final String status;

  bool get running => status == statusRunning;

  /// Resumable kinds resume automatically once the vault is unlocked and its
  /// owner is current, because each of them is idempotent. Adoption is never
  /// resumed: it always needs a fresh owner decision.
  bool get resumable =>
      kind == kindPull || kind == kindFlush || kind == kindReset;

  Json toJson() => {
    'id': id,
    'kind': kind,
    'vaultId': vaultId,
    'data': data,
    'startedAt': startedAt.toIso8601String(),
    'status': status,
  };

  factory SyncOperation.fromJson(Json j) => SyncOperation(
    id: j['id'] as String,
    kind: j['kind'] as String,
    vaultId: j['vaultId'] as String?,
    data: j['data'] as String?,
    startedAt: DateTime.parse(j['startedAt'] as String),
    status: j['status'] as String,
  );
}
