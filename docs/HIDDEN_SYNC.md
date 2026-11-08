# Hidden-note sync

## Security and wire format

Hidden notes are not local-only: they sync through the existing v1 opaque
revision-DAG/batch protocol, with no server schema, endpoint, deployment or
credential change. Enable ordinary vault sync to transport hidden data. An ordinary vault lock still prevents that vault
from syncing; the additional hidden lock does **not** prevent ciphertext sync.

Each hidden note retains its independent random 256-bit hidden key, wrapped with
the hidden password using the existing fixed Argon2id configuration (64 MiB,
three iterations, one lane) and AES-256-GCM. The full `Note` JSON—including title,
body, folder, tags, flags and dates—is inside that extra authenticated envelope,
with the existing `silique:1:hidden:<vault>:<local-note>` AAD. Hidden attachments
remain embedded inside this envelope, not ordinary image manifests/references.

The vault-key-encrypted revision contains a `silique.hidden.v1` routing envelope
with that ciphertext and its password-wrapped configuration. Possession of the
account/vault key alone does not reveal hidden note fields. Configuration-only
`silique.hidden.config.v1` records also propagate setup before the first note.
The hidden key itself is never account-wrapped or uploaded in plaintext.

Only opaque IDs, DAG edges, ciphertext sizes, vault association and traffic timing
remain visible to the server. There is no claim of padding, traffic analysis
resistance, forward secrecy or rollback protection beyond the existing protocol.
Clients with the vault key can see routing information/password-wrapped config,
but still require the extra password to open hidden fields. A weak hidden
password remains susceptible to offline guessing; account recovery alone cannot
recover a forgotten hidden password.

Local hidden documents remain in `hidden:<vault>`, not ordinary document maps,
Markdown mirrors, ordinary search/export or widget projections. Routing indices
and portable configurations use separate namespaces and local-key encryption.
The ordinary outbox contains only vault-key-encrypted revisions, never hidden
plaintext or user metadata. Locking drains previously captured saves, revokes
access immediately and best-effort zeroes all in-memory hidden-key domains.
Dart/OS memory and cryptography internals do not provide a guaranteed secure heap.

## Migration, password domains and conflicts

Legacy keystore slots and hidden ciphertext are preserved. First sync creates a
new opaque wire identity plus a pending encrypted revision, atomically recording
that identity so retry/restart does not create duplicates. Migration works while
the hidden section is locked; it does not need the plaintext or rotate the key.
The old server-visible ordinary identity of a moved note is still purged before
hidden upload; lost DELETE acknowledgements retain the encrypted recovery copy.

A clean device obtains the portable password configuration while remaining
locked. Enter the same extra password to unlock. A device that already has an
independent hidden password does not overwrite its existing credentials: each
password opens only its matching key domains. New hidden notes and moves use the
active unlocked password domain; existing notes retain their own domain. Settings
for inactivity/background locking remain device-local.

Concurrent distinct versions are preserved as hidden encrypted conflict copies,
including metadata differences; no automatic text merge discards alternatives.
Creation dates are preserved. Equivalent heads become parents of the next real
edit without merge-of-merge churn. A save parents only its last projected heads,
not competing heads downloaded while locked. Conflict-copy wire identities are
separate from local document identities, preserving history through vault reloads.

A hidden soft deletion travels inside the encrypted note. Permanent deletion
purges its opaque wire identity with the existing server API; stale uploads cannot
resurrect it. Explicit unhide atomically adds an ordinary revision and an encrypted
retirement record, so hidden history cannot silently recreate the hidden entry.
Unhide remains an intentional disclosure of the note to ordinary vault surfaces.

## Limits and compatibility

- This requires updated clients. Older releases do not understand the new
  encrypted record kinds and can fail their sync pass (rather than expose hidden
  fields). Upgrade every syncing device before relying on hidden-note sync.
- The existing server limit is 2,000,000 bytes per opaque revision. Double-envelope
  overhead and embedded images count toward it. Oversized synced edits fail
  explicitly without replacing the last durable content. An oversized legacy
  document remains encrypted locally and migration reports an error; it is not
  silently dropped or marked synced. Large hidden attachment chunking is not
  implemented in this change.
- Concurrent hidden edits favor preservation over text merging. Review conflict
  copies in the hidden section and delete unwanted alternatives explicitly.

## Automated verification

Use disposable loopback servers and synthetic accounts only:

```sh
SILIQUE_TEST_SERVER=http://127.0.0.1:18887 flutter test --no-pub \
  test/hidden_e2ee_sync_test.dart --reporter expanded
flutter test --no-pub test/hidden_sync_safety_test.dart --reporter expanded
```

The E2EE file creates five accounts. The default server permits five registrations
per minute; wait for the returned cooldown before running another integration
file (including `hidden_notes_sync_test.dart`). Do not weaken production limits.
Tests cover two real isolated SQLite/keystore clients, locked transport, portable
setup, independent passwords/moves, migration, encrypted conflicts/convergence,
soft/permanent deletion, unhide, missing ACK plus byte-identical outbox restart,
ordinary projection exclusion, encrypted user metadata and lock/size boundaries.
Repository tests deliberately use a reduced test-only KDF; production parameters
remain fixed in `SiliqueCrypto` and are covered by the existing crypto tests.
