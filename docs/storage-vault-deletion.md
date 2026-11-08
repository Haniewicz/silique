# Native whole-vault deletion storage contract

`NoteStorage` exposes:

```dart
Future<Map<String, String>> deletionIntents();
Future<void> beginVaultDeletion(String vaultId, String payload);
Future<void> cancelVaultDeletion(String vaultId);
Future<void> eraseVault(String vaultId);
bool isVaultDeleted(String vaultId);
```

## Admission and remote acknowledgement

The caller must fence new domain work and **await already accepted writes and
mirror Futures before `beginVaultDeletion`**. Storage does not drain Notebook,
sync, editor, crypto or HTTP queues. A pending intent is not an acknowledgement
of remote deletion, and it never causes local content erasure on open.

The payload is an opaque caller-owned string; JSON can record non-secret remote
server/owner identity, exact expected version and recovery state. Do not store
plaintext note content or credentials in it. `beginVaultDeletion` upserts the
payload in `vault_deletion_intents`; `deletionIntents` returns a detached map.
`cancelVaultDeletion` removes an uncommitted intent and permits writes again.
Only the caller can decide that a remote rejection is definitive enough to
cancel; a timeout after a possible remote commit is not proof of rejection.

`isVaultDeleted` is a synchronous tombstone lookup, not a pending-intent check.
Both begin and cancel reject an already tombstoned UUID. Only `putVault` can
create a new base identity. All other scoped writers require an existing base
vault. All ordinary low-level mutators reject a pending or tombstoned base ID,
including its exact hidden document namespaces. Reads remain available while
pending so recovery can inspect retained content.

## Irreversible local erasure

Call `eraseVault` only for an authorized local-only deletion or after an
authoritative remote acknowledgement/tombstone. The storage layer neither
performs remote requests nor makes that authorization decision. It accepts a
well-formed UUID even when this device never had the vault, reserving that
retired identity against a delayed import.

One SQLite transaction inserts `deleted_vaults` and `vault_deletion_cleanup`,
then removes the vault row and **all** documents, revisions/outbox, batches,
cursors, image assets and chunks for these exact namespaces:

- `<vaultId>`
- `hidden:<vaultId>`
- `hidden-sync:<vaultId>`
- `hidden-config:<vaultId>`
- `hidden-retired:<vaultId>`

There is no prefix/LIKE match and no live-note enumeration. Wrapped vault keys
and encrypted metadata disappear with the vault row; orphan/partial attachments
are included. Explicit chunk cleanup also handles any orphaned legacy rows.
SQLite `secure_delete=ON` is retained. Persistent INSERT/UPDATE triggers fence
pending/deleted identities in all seven content tables, including positional
SQL from an older writer and another connection racing an API preflight check.
Public mutators normally throw `StateError`; a cross-connection race caught by
a trigger can instead produce `SqliteException`. No recovery may drop these
triggers or tombstones to make a stale write succeed.

After SQL commit, cleanup removes only the UUID child of the **current** root's
`markdown` directory, including interrupted/nested files. IDs are validated
before any deletion mutation. A symlink or non-directory markdown parent fails
closed; child/nested links are unlinked without following their targets.
This does not defend against a hostile process replacing filesystem entries
concurrently with cleanup (Dart filesystem APIs do not expose `openat`-style
race-free relative deletion). Callers must own the managed directory.

Checked `wal_checkpoint(TRUNCATE)` runs before journal removal and again after
the journal transaction. A busy reader is a cleanup failure, not success.
If the final checkpoint fails, both the caller intent payload and cleanup
marker are restored for retry; the permanent tombstone remains authoritative.
Successful completion leaves no WAL frames, removes the pending intent and
cleanup marker, but keeps the tombstone permanently.

## Failure and restart semantics

- SQL failure rolls back retirement and scoped removal together; the pending
  intent and mirrors survive for retry.
- Mirror/checkpoint failure can happen **after irreversible SQL commit**. The
  exception does not mean the vault was restored. Consult `isVaultDeleted`,
  retain the caller's deletion fence, and retry `eraseVault`.
- NativeStorage open retries cleanup for every tombstone, including completed
  ones. This covers a crash between cleanup-marker deletion and final WAL
  truncation, and interrupted mirror artifacts. Pending remote intents without
  tombstones are never auto-erased.
- If startup cleanup fails, construction throws after closing that database
  handle. Repair the filesystem condition or release the busy reader and reopen;
  never create a fresh replacement store.
- Repeated erase is idempotent. Cancel/begin cannot clear a tombstone.

## Preservation and limits

Unrelated vaults and namespace-prefix neighbors are untouched. This primitive
never accesses the keychain, shared hidden password configuration, account or
installation keys, session tokens, global settings, `.env`, location pointers,
or unrelated root files. Domain/UI/widget/cache cleanup is a separate caller
responsibility.

Old relocation roots, manual exports/import sources, backups, offline/legacy
clients, OS snapshots and physical media remnants are outside this guarantee.
An old database restore must retain/reapply tombstones. Do not claim forensic
SSD erasure. Raw database access is not a supported application writer API;
triggers defend content admission, not arbitrary schema/tombstone tampering.

## Disposable verification

`test/native_vault_deletion_test.dart` uses only real disposable NativeStorage
SQLite databases and mirror files under `Directory.systemTemp` (honoring
`TMPDIR`). It covers exact complete cleanup/isolation, restart, pending intent,
all mutator fences, two open connections, older SQL writers, rollback via a real
SQLite trigger, real pinned WAL readers at both checkpoint boundaries, symlink-parent failure/recovery,
child/nested/broken links, interrupted files, unknown remote tombstones,
invalid paths, integrity/FK checks and synthetic plaintext-byte removal.

Run with the release task's shared Flutter lock to avoid asset/build races.
