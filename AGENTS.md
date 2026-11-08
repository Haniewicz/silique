# Silique (publiczne repo klienta)

## Git workflow — decyzja właściciela 2026-11-08

- Rozwój prowadzimy **wyłącznie na gałęzi `dev`** w TYM repozytorium.
- `main` jest gałęzią wydań: merge `dev` -> `main` **tylko razem z pełnym release**
  (wersja + build + publikacja). Nie pushuj bezpośrednio do `main`.
- Stare, prywatne repo `Haniewicz/silique-app` zostaje jako archiwum proweniencji; nowy kod
  nie może powstawać tylko tam.

# Local macOS installation

- The owner uses one installed copy: `/Applications/Silique.app`.
- After app changes, build/sign and replace that installation with `Zbuduj macOS.command`. `Uruchom Silique.command` builds, updates the same installation, and opens it.
- From 0.2.30 onward publish macOS as DMG only, never a parallel macOS ZIP. The same signed DMG is used for manual installation and Sparkle updates. Preserve historical releases. Do not leave extracted test/legacy apps in project or release folders; the installer removes Release/Debug app bundles after successful installation.
- If a separate debug build is needed during development, remove its app bundle after testing. Unregister only that bundle from Launch Services; never reset the global application registry.
- Preserve all vaults, preferences, system keychain entries and installation/crypto identifiers when updating or replacing the app. Removing old app copies is not permission to erase user data.
- GitHub publication requires the owner's explicit approval for the specific release and personal testing unless the owner explicitly waives that test. A waiver is not proof of testing or standing authorization.

## Planned changes (do not implement without an explicit request)

- `docs/BACKLOG.md` holds owner-decided future changes that are deliberately not
  implemented yet. Read it before proposing work; do not start those items on
  your own initiative.
- Implemented for 0.2.29: Android uses Keystore for fresh installs and has no
  credential selector. Existing local installs receive a one-time explicit
  migration offer; declining preserves their authority and data. Do not restore
  a silent migration or local fallback. See `docs/0.2.29.md`.

## Current release handoff

- For Silique 0.2.8 release provenance, read `docs/HANDOFF.md` first. It records the published release, source SHAs, completed GitHub Actions runs, verified tests and diagnostic locations. Refresh live repository/release status before further work.
