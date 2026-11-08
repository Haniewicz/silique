# Credential placement — implementation contract

## Current Android policy (0.2.29)

Android fresh installs use system/Keystore only, without a selector in setup or
Settings. Legacy local installs get one explicit migration offer before notebook
opening. Declining stores a separate `android-system-offer-v1` marker, retains
local authority and never accesses the system backend. Accepting uses the same
verified migration controller; interrupted moves enter explicit recovery. Other
platform choices remain unchanged. See [0.2.29](0.2.29.md) for current evidence.
The original 0.2.27 implementation record below is historical.

This change follows publication of Silique 0.2.26+35. It is a separate candidate,
0.2.27+36, not a change to the published installers or signed update channels.

## User-visible behavior

- A fresh, mode-less setup asks how to store credentials before creating a
  notebook. Local placement is initially selected, with explicit acknowledgment
  of its weaker protection before confirmation.
- Existing installations retain system protection until the user changes it.
  Recovery of a lost notebook location does not change credential placement.
- Settings can move the same credentials in either direction. The notebook,
  vault IDs, wrapping key, account identities and hidden-note password remain
  unchanged. The setting is device-local, never synchronized.
- There is one active credential collection. A migration may temporarily retain
  its source until the target and activation are confirmed. A cleanup failure
  must be visible; it is not a fully completed move.

## What local placement means

The application keeps its existing credentials in a private file outside the
user-selected notebook folder. This includes the installation wrapping key,
account/session credentials and device identities. Anyone able to read that
file may be able to decrypt protected material or impersonate an account.
Local file permissions and full-disk encryption are useful but do not provide
system-keyring protection. Encrypting the file with a key beside it would not
change this boundary, and is not presented as protection.

This is NOT whole-notebook encryption: ordinary notes already have local
SQLite/Markdown projections. The additional password protecting hidden notes
remains a separate requirement. Android launcher-cache keys remain in
AndroidKeyStore and are not part of this credential-placement option.

## Required failure behavior

- Serialize ordinary credential operations and migration under the same
  cross-process lock. Preserve the old authoritative copy until a verified
  target and durable activation exist.
- After activation, use only the target. Never silently fall back to a stale
  source. Report pending source cleanup and allow explicit retry.
- Missing/corrupt active credentials or unknown metadata must stop startup,
  not generate a replacement key for existing vaults.
- Keyring cancellation/unavailability is not permission to switch to local.
- Import all owned entries, including inactive accounts. macOS bundle
  tombstones override stale separate legacy values. Cleanup is scoped, never
  a blanket deletion of the system store.
- Local credentials do not move with the notebook directory, appear in sync
  payloads, or get intentionally included in notebook exports. File deletion
  is logical cleanup, not forensic erasure of backups/snapshots/SSDs.

Older binaries do not understand the mode marker. Concurrent old/new versions
and downgrade after migration are unsupported; restore a compatible version
rather than allowing an older binary to create a second identity.

## Verification

The implementation is complete on `feature/credential-storage-mode`; this is
not a published release or an installer candidate. Automated verification on
Linux passed: 693 Flutter tests, 40 skipped, no failures; analyzer clean; the
21 changed Dart files pass formatting. The native file suite independently
passed 31 tests (9 skipped), and 33 (7 skipped) with the fault-injection harness.
Darwin ACL facade tests validate the API contract, not a real macOS filesystem.
ABI C assertions compiled for Linux x64 and four Android ABIs.

Android debug APK built successfully. The app's Kotlin/Robolectric host suite
passed 37 tests without failures or skips (`:app:testDebugUnitTest`). A broader
Gradle task also invoked dependency-owned tests and failed in
`file_selector_android` because its SDK 36 Robolectric case requires Java 21,
while this toolchain uses Java 17; that plugin test is not an app regression.
Existing AGP/Kotlin deprecation and SDK-tool warnings remain.

The resumed work fixed the previous review blockers with RED→GREEN evidence:
macOS cleanup preserves foreign bundle entries and tombstones; independent
backends reload the bundle after another process changes credentials; the first
local choice is durable before staging; and Darwin extended ACLs are rejected
on pinned handles. A final independent read-only review found no blockers.

Evidence and debug APK:
`$HOME/projects/Silique/artifacts/credential-mode-0.2.27-36/`.
The APK is a debug build, not a production-signed update; do not install it over
the owner's signed app or interpret it as an approved release.

Real macOS/Windows execution, Android device execution and owner manual testing
have not been performed. No 0.2.27 public release, signed feed update, production
server deployment or owner-device installation was requested or performed.
