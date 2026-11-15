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
  });

  final DateTime? lastSuccessAt;
  final DateTime? lastAttemptAt;
  final String? lastError;
  final DateTime? lastErrorAt;

  /// True when the most recent recorded failure is newer than the most recent
  /// success (or there was never a success). A vault that has never attempted
  /// a sync is not "failing" yet — nothing has gone wrong.
  bool get failing =>
      lastError != null &&
      (lastSuccessAt == null ||
          (lastErrorAt != null && lastErrorAt!.isAfter(lastSuccessAt!)));

  Json toJson() => {
    'lastSuccessAt': lastSuccessAt?.toIso8601String(),
    'lastAttemptAt': lastAttemptAt?.toIso8601String(),
    'lastError': lastError,
    'lastErrorAt': lastErrorAt?.toIso8601String(),
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

  /// Hidden notes that the reset deliberately left untouched.
  final int hiddenSkipped;
}
