# Sync recovery: observable status, forced resync, source-of-truth reset

Status: design for 0.2.56. Client-only change — the server contract is unchanged.

## Why

Two different failures looked identical from the UI:

1. **Replication stall.** A vault pass throws in the push phase. Ordering inside one
   pass is `push -> pull(cursor) -> reconcile/merge -> cache images -> push`
   (`lib/services/notebook.dart`), and an exception escapes the whole per-pass
   vault loop, so *no* vault pulls. On a device in this state nothing new appears
   and no conflict can be detected, because merging never runs.
2. **Real divergence.** Two or more heads for one note that the three-way merge
   cannot join. The client already materialises these deterministically as
   `<title> (kopia konfliktowa)` notes (`conflict: true`), but nothing summarises
   it and the user has no repair action.

Only the second is a merge problem. The first is a visibility and recovery
problem, which is what this change adds.

A third, independent stall was found while testing the recovery path:
`_cacheImages` runs after the pull and before the final push, and it used to
propagate every image failure. The server answers a manifest request for an image
it never received with `404 Image not found` — the natural consequence of the
0.2.54/0.2.55 lost-attachment class — so a single note whose body cited such an
image aborted the whole vault pass, before its own edits were ever pushed. One
unavailable attachment is now skipped (the image stays remote-only and the editor
keeps its placeholder); every other image failure stays fatal.

## Server contract (verified in `silique-server-public/src/app.ts`)

- `GET /v1/vaults/:id/changes?cursor=N&limit=L` returns revisions with
  `seq > N`, ordered by `seq`, `L <= 100`. `seq` is `AUTOINCREMENT` starting at 1,
  so **`cursor=0` replays the whole vault**. Replaying is idempotent for the
  client (`putRevision` upserts).
- `POST /v1/vaults/:id/batches` accepts at most 100 revisions; each revision
  accepts at most **32 parents**; every parent must already exist in the same
  vault *and* the same note, else `409 Parent revision missing`. Duplicate
  parents are `400`. Retrying the same `batchId` with the same body is
  idempotent; the same revision id with different content is `409`.
- Revisions for a purged note are silently skipped. `images` ids must have an
  uploaded manifest, else `409 Image not uploaded yet`.
- A revision may list parents created by **another device**. This is what makes
  the source-of-truth reset possible without any server change: the chosen
  device retires every head by becoming their child.
- The server is a dumb immutable store: it never detects or reports conflicts.

## Feature 1 — observable sync status

New local-only table, never synced:

```sql
CREATE TABLE IF NOT EXISTS sync_state(vault_id TEXT PRIMARY KEY, data TEXT NOT NULL)
```

`VaultSyncStatus` (`lib/core/models.dart`): `lastSuccessAt`, `lastAttemptAt`,
`lastError`, `lastErrorAt`; `failing` is true when an error is newer than the last
success (or there was never a success).

Recording happens in `_sync`: one success/failure per vault per pass. **Failures
must be isolated per vault** — the pass records the error, continues with the
remaining vaults, and rethrows the first error once the loop is finished so the
existing UI error surface is preserved. A `410` tombstone inside the loop keeps
its current handling.

Counts exposed by `NoteStorage` for the dialog: `pendingCount(vaultId)` (revisions
with `pending=1`) and the number of notes whose local head count is greater than
one (computed from existing revision APIs, no new SQL JSON tricks).

## Feature 2 — forced resync

- `forceFullPull({vaultId})`: set the cursor to `0` for the target vault(s) and
  replay the whole changelog. Nothing is pushed and the durable batch is left
  untouched, so the server is never modified. The replayed history is then
  materialised through the normal reconcile and image cache, exactly as a
  regular pass would — it can therefore create the same local merge/conflict
  revisions a regular pass creates. This is the only recovery path for a vault
  whose push phase keeps failing, because a regular pass never reaches its pull.
- `forceFlushPending({vaultId})`: drain the durable batch and the pending queue
  with repeated bounded `_push` calls until the queue is empty or a bounded
  iteration count is reached. Reports how many revisions remain.

Both are safe to interrupt: they never rewrite existing payloads.

## Feature 3 — "this device is the new source of truth"

`resetToLocalSourceOfTruth(vaultId, {keepLosingCopies})`.

Preconditions: vault unlocked, sync enabled, owner is the current account, not
tombstoned, server reachable. Otherwise throw a readable `StateError`.

Steps:

1. **Full pull first** (cursor `0`). A reset revision must cite heads the server
   already has, and stale cursors are exactly how a device ends up blind to them.
2. Snapshot the local materialised state (`documents` = current view per note) and
   the local head set per note.
3. For every note id known locally or remotely:
   - note present locally and not deleted: new revision whose content is the
     local document, parents = **all** heads of that note;
   - note deleted locally: the same with `deleted: true`;
   - heads exist but no local document (purged or unknown): a deletion revision
     over those heads — this is how the chosen device wins over content it does
     not have. Purged note ids are skipped (the server ignores them).
   Parents are capped at 32 per revision, so a note with more heads is retired
   through a **chain**: each revision retires up to 31 heads plus the previous
   revision in the chain, and the content of every link is the chosen content.
   The chain therefore terminates with exactly one head.
4. `keepLosingCopies` (default true): before overwriting, every distinct
   non-chosen head content becomes a normal note titled
   `<title> (kopia przed scaleniem)` with `conflict: true`, created through
   `crypto.stableId(key, 'pre-reset:<noteId>:<revisionId>')` so a re-run is
   idempotent and every device derives the same id. Copies are capped (e.g. 5 per
   note) to avoid an explosion.
5. Retire the stuck queue: acknowledge the old pending revisions and delete the
   durable batch. Their content is already reflected in `documents`, and the reset
   revisions supersede them — keeping them would resurrect the exact
   parent/image references that caused the stall.
6. Push the reset revisions with the normal image filtering (`_batchWithAvailableImages`
   path), then run one more full pull and report the remaining diverged count.
   A successful reset ends with zero notes having more than one head.

### Explicit non-goals

- No server change, no new route, no new revision field.
- No cross-device atomic fence: two devices resetting simultaneously can produce
  fresh heads that turn into conflict copies. That is visible and recoverable, and
  it is documented in the confirmation dialog rather than silently "resolved".
- Hidden notes are not covered by the reset (separate encrypted channel,
  `notebook_hidden_sync.dart`); the dialog says so and the report carries
  `hiddenSkipped`.
- No change to merge semantics or to the existing conflict-copy behaviour.

## UI

One dialog, `lib/ui/sync_status_dialog.dart`, reachable from the vault menu and
from the failing status line of the active vault:

- last successful sync (relative time), last error text, pending count, diverged
  note count;
- actions: "Wymuś pełne ściągnięcie", "Wyślij oczekujące zmiany";
- destructive action "Ustaw to urządzenie jako źródło prawdy…" behind a second
  confirmation that lists counts, states the consequences, offers
  "zachowaj przegrywające wersje jako kopie" and warns about hidden notes.

Every string goes through the existing `tr(pl, en)` helper. No real IO in widget
tests.

## Tests required

- `sync_state` round-trip and `failing` semantics.
- Per-vault failure isolation: one failing vault does not stop the other, error
  survives as status, pass still reports the failure.
- Full pull from cursor `0` picks up revisions that a stale cursor skipped.
- Force flush drains a queue larger than one batch.
- Reset: union parents for ordinary notes, chain for more than 32 heads, deletions
  for locally deleted notes and for remote-only heads, deterministic idempotent
  copies, purged ids skipped, image filtering, `hiddenSkipped`, final zero
  divergence.
- UI: dialog renders counts and requires the explicit confirmation; fail-fast
  before IO.
- Whole suite green, `flutter analyze` clean.