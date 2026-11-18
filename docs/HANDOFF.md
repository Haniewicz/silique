# Silique 0.2.60+69 — release published

2026-11-18, on the owner's instruction, [Silique 0.2.60](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.60) was published: seven installers (macOS DMG, Android APK, Windows EXE/ZIP, three Linux GTK4 packages) plus `SHA256SUMS.txt`; both signed update feeds point at build 69. Source code for every package: `0938b8fda5724aa57e385fc199488ea12762b29b` (`main`, 0.2.60+69). Scope and notes: [0.2.60](0.2.60.md).

Four UI changes from the owner's list. The sidebar footer now ends in one row of four equal actions — Deleted, Hidden, Import and Settings — in both the compact and the classic sidebar; the vault badge below them (vault name, note count, `E2EE`/`local`) is gone, and the Settings action uses the shared footer-button styling with the key `sidebar-settings-nav`, closing the phone drawer before it opens the panel. The two template pickers in Settings now use the same `InputDecoration` label treatment as every other dropdown, and their closed trigger stays one line. Templates living in a subfolder of the templates folder are listed and selectable (previously only notes directly in the root were offered), with the path relative to the templates folder shown in the menu and in the Settings lists so same-named templates can be told apart. Built-in folder names follow the UI language through aliases without rewriting stored paths: a new module `lib/core/system_folders.dart` recognises `Szablony`/`Templates` and `Dziennik`/`Journal` case-insensitively for detection, seeding, rename/delete guards, hiding, tree labels/icons, breadcrumbs, the quick switcher and the folder pickers; a new vault seeds the folder in the current language, an existing vault keeps its stored spelling (no duplicate and no migration), and display-only localization never changes paths. No protocol, crypto, database-migration, dependency or server change.

Orchestration was mode 2 (worker + reviewer) through the direct DeepSeek API via `dsh headless`. The worker's first session lost access to the Flutter toolchain because the headless sandbox roots `workspace-write` at the repository; the same session was resumed with `danger-full-access` and kept all its context. A quota error (`QUOTA/402 Insufficient Balance`) killed the worker during the review-fix round, after most fixes were already applied; the remaining fixes (nested alias leaf localization, breadcrumbs and picker display, single-line trigger, phone drawer, formatting, test teardown) were finished by the Lead and verified with the full suite. Review returned no blocking findings; its non-blocking points were fixed.

Runs: macOS/Android 44375625888, Windows 44375631967, Linux GTK4 44375638699, signed preparation 44385291716, publication 44385809121 — all `success`. Candidate draft `candidate-0.2.60-69` carried the seven installers; the first `collect` attempt was interrupted after the downloads and before creating the draft, so the staging directory was removed and the command re-run; the Linux artifact was verified separately (version 0.2.60/build 69, all three sums OK) before the re-run. Evidence: `silique preflight 0938b8f` → `PREFLIGHT OK` (`+1342 ~46`, `flutter analyze` clean); all eight published assets were downloaded and verified against the published `SHA256SUMS.txt` by digest (7/7 `OK`); `latest.json` payload base64-decodes to a schema-1 document with `"version":"0.2.60"`, `"build":69` and all seven platform keys; `appcast.xml` advertises `sparkle:version="69"`, `sparkle:shortVersionString="0.2.60"`. The server was not touched by this release.

Known limitations: no personal device test was performed; macOS still installs manually from the self-signed DMG; Linux packages were built by the GitHub-hosted GTK4 builder (CT 104 path not used); 46 environment-dependent tests are skipped in the suite; and with the alias decision, a vault whose journal notes were created in both languages can keep two journal folders that the UI displays under the same localized name.

---

# Silique 0.2.59+68 — release published

2026-11-17, on the owner's instruction, [Silique 0.2.59](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.59) was published: seven installers (macOS DMG, Android APK, Windows EXE/ZIP, three Linux GTK4 packages) plus `SHA256SUMS.txt`; both signed update feeds point at build 68. Source code for every package: `785c4c01b1231f83ff1092ab5963f6ef6debb767` (`main`, 0.2.59+68). Scope and notes: [0.2.59](0.2.59.md).

Six UI changes from the owner's list. The notes list now renders one header per group (Pinned / Today / Yesterday / Older) instead of repeating the group name above every note. `Szablony` became a built-in default folder: a new vault seals it into its first metadata write, and an older vault receives it on the first unlock through the normal metadata path (offline-tolerant, pending for the next sync when the owner session is offline); the folder cannot be deleted or renamed (service guards before any write, and the folder menu does not offer those actions), while Settings → General can hide it from the tree without touching templates or notes. Creating notes from a template was removed — the note/folder/note-options "New note from template…" entries and both drawer "Journal entry from template…" entries are gone, along with their dead helpers. Settings → General gains a device-level default template for ordinary notes (default: none), filled silently into a new note without moving it out of its folder. A new "Apply template…" action on an existing note (context menu and note-options, desktop and mobile) replaces an empty note's title and body with the rendered template and appends the rendered template after a blank line to a note that already has content, keeping its title; it flushes the editor first and writes through the normal note path. Ctrl+K now focuses the switcher's search field after the first frame instead of leaving the caret in the editor. No protocol, crypto, database-migration, dependency or server change.

A dangling metadata write started from the widget lifecycle (the first implementation of the default folder) hung existing widget tests behind the notebook's serialized queue, because a real-I/O future started in `initState` never settles under the fake test clock. The blocked paths were found by an independent review bisection and fixed at the root: the folder is now seeded inside the service (`createVault` metadata plus the unlock path) instead of from `initState`, so no widget-lifecycle write exists at all, and the folder-set expectations of eleven existing tests were updated for the new default. DeepSeek direct-API orchestration workers also hit a transient `QUOTA/402` (`Insufficient Balance`) mid-batch; the remaining fixes and the release were completed after the limit cleared.

Runs: macOS/Android 44142830756, Windows 44142838288, Linux GTK4 44142846055, signed preparation 44148968474, publication 44149407539. Evidence: preflight on the released SHA `PREFLIGHT OK` (`+1327 ~46`, `flutter analyze` clean) and two full local suites green after the fix; new tests cover the single group header, the default folder (creation, idempotence, lock, restart, delete/rename guards, hiding), default note and journal templates, applying a template to an empty and a non-empty note, the note-options path and the switcher focus. The release notes list the functional scope; design details are in this handoff. The server was not touched.

All eight published assets were downloaded and verified against the published `SHA256SUMS.txt` by digest (7/7 `OK`); `latest.json` payload base64-decodes to `{"schema":1,"version":"0.2.59","build":68}` with all seven platform keys and `appcast.xml` advertises `sparkle:version="68"`, `sparkle:shortVersionString="0.2.59"`. The server was not touched by this release.


---

# Silique 0.2.58+67 — release published

2026-11-16, on the owner's instruction, [Silique 0.2.58](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.58) was published: seven installers (macOS DMG, Android APK, Windows EXE/ZIP, three Linux GTK4 packages) plus `SHA256SUMS.txt`; both signed update feeds point at build 67. Source code for every package: `eadf85858e9b9ecfa493f196fb65dad44ed12d58` (`main`, 0.2.58+67). Scope and notes: [0.2.58](0.2.58.md).

A UI release in six parts. The desktop editor now keeps a note's title, tags and body in a centred column capped at 820 px (toolbars, tabs and the status bar stay full width; nothing changes below 1000 px). The notes list is grouped into Pinned / Today / Yesterday / Older from each note's last change in the local time zone, on phones too, and stays flat for title/created sorting or an active query; compact mode is untouched. Notes stored in the `Szablony` folder become templates ("New note from template…", "Journal entry from template…", placeholders `{{date}} {{time}} {{title}} {{weekday}} {{vault}}`, a default journal template in Settings → General) and sync as ordinary encrypted notes, so no server change was involved. Keyboard shortcuts are editable per device in Settings → Shortcuts (nine actions, captured chords, conflict refusal, restore defaults), with new Ctrl+Tab / Ctrl+W / Ctrl+Shift+T handling and a 20-entry reopen history. Ctrl+K opens a floating quick switcher (fuzzy title/folder match with folded diacritics, highlighted matches, arrows/Enter/Esc) that never acts on the document underneath. Inline colours were replaced by named design tokens with identical values (59 literals → 0 outside `theme.dart`). No protocol, crypto, database-migration, dependency or server change.

Runs: macOS/Android [43932715704](https://github.com/Haniewicz/silique-releases/actions/runs/43932715704), Windows [43932722780](https://github.com/Haniewicz/silique-releases/actions/runs/43932722780), Linux GTK4 [43947085761](https://github.com/Haniewicz/silique-releases/actions/runs/43947085761), signed preparation [43955521884](https://github.com/Haniewicz/silique-releases/actions/runs/43955521884), publication [43960342303](https://github.com/Haniewicz/silique-releases/actions/runs/43960342303) — all `success`. Candidate draft `candidate-0.2.58-67` carries the seven installers; `collect` verified each Linux package against `SHA256SUMS-Linux.txt` and each macOS/Windows provenance file against the released SHA before the draft was created.

Evidence: preflight on the released SHA `PREFLIGHT OK` (`+1306 ~46`, `flutter analyze` clean); earlier revisions of the same tree were preflighted the same way (`d763185`, `b3feb23`, `d5a1ad9`, `62c145a`). New tests cover the 820 px column and wide images inside it, section grouping (midnight boundary, future timestamps, flat lists for other sorts, Favorites filter), editable bindings (parse/format, conflict, modifier split), the quick switcher (guard under overlays, macOS Cmd vs Ctrl), device-settings persistence and corrupt files, template rendering and journal defaults, plus a widget test for the macOS Ctrl+Tab regression. Two independent reviews of the feature window returned blocking findings — shortcuts firing under the quick switcher, and exact modifier matching turning stored `ctrl+tab` into Cmd+Tab on macOS after a restart — both fixed, tested and re-reviewed; the final review approved the feature window. A regression in the legacy `ui_test.dart` (section headers pushed seeded notes below the fold) was proven on a pre-change worktree, fixed at the test level with `ensureVisible`, and the full suite is green.

This release was the first real use of the GitHub-hosted Linux GTK4 builder. Four infrastructure defects were found and fixed along the way: depot_tools was only on `PATH` inside the engine bootstrap while packaging runs a second ninja; depot_tools' CIPD python was never initialised (`ensure_bootstrap` added); the native wheel regression clicked pre-onboarding coordinates (639,617 → measured 653,565 for PL and EN); and the Fedora rootfs cache save aborts the job on root-owned `0600` files. The cache save fix (`bf53603`) is on `dev` only and is deliberately not part of this release; the candidate therefore ran without the Linux build cache. A `workflow_dispatch` run stayed queued indefinitely and blocked the shared concurrency group, so the group is now scoped per run. `collect --linux-run` also compared an `int` build with a `str`; fixed in `operations/silique`. `dev` is one commit ahead of `main` (`bf53603`); that fix will reach `main` with the next release.

All eight published assets (seven installers and `SHA256SUMS.txt`) were verified by digest against the published manifest (all match); `latest.json` payload base64-decodes to `{"version":"0.2.58","build":67}` with all seven platform keys and `appcast.xml` advertises `sparkle:version="67"`, `sparkle:shortVersionString="0.2.58"`. The server was not touched by this release.

---

# Silique 0.2.57+66 — release published

2026-11-15, on the owner's instruction, [Silique 0.2.57](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.57) was published: seven installers (macOS DMG, Android APK, Windows EXE/ZIP, three Linux GTK4 packages) plus `SHA256SUMS.txt`; both signed update feeds point at build 66. Source code for every package: `dd9d930cf75c943736c2b93aec454fe1d5fbe7a2` (`main`, 0.2.57+66). Scope and notes: [0.2.57](0.2.57.md); design: [sync-recovery](sync-recovery.md).

Follow-up to the 0.2.56 recovery work, on the owner's four requirements. A reset now ends with a real upload: the queue drains until empty, the final pull can re-queue revisions, so the reset drains again and verifies zero diverged notes *and* zero pending revisions, reporting an incomplete reset as incomplete. Cross-device hand-off travels inside the vault DAG as an internal marker revision (deterministic id, epoch, device, timestamp) written last by a reset, so it is ordered after the content it describes; the marker is an internal identity and never reaches the note map, reconcile, folder rows, search, the export plan or the Android widget snapshot. A device that pulls a newer marker **holds** the vault: revisions are stored and the cursor advances, but reconcile, the image cache and any push are skipped, so nothing changes locally, and the hold persists across restarts. The shell shows a banner; the decision offers exactly three actions — export a backup then download, download, or later — and nothing is adopted without it. Adoption acknowledges only the ordinary pending revisions the server head supersedes, keeps local-only notes and hidden revisions syncing, and is idempotent; a reset clears the acting device's own hold. Every long action shows a spinner inside the pressed button. On Android a local `sync_operations` journal settles each long operation and resumes an interrupted pull/flush/reset on the next launch once the vault is unlocked (adoption is never auto-resumed), and a foreground `dataSync` service with a localised ongoing notification keeps the process alive while it runs. No protocol, crypto, DAG, data-migration or server change.

Runs: macOS/Android [43759064705](https://github.com/Haniewicz/silique-releases/actions/runs/43759064705), Windows [43759067360](https://github.com/Haniewicz/silique-releases/actions/runs/43759067360), signed preparation [43763121096](https://github.com/Haniewicz/silique-releases/actions/runs/43763121096), publication [43763430919](https://github.com/Haniewicz/silique-releases/actions/runs/43763430919) — all `success`. Candidate draft `candidate-0.2.57-66` carries the seven installers. Linux built in CT 104 (`artifacts/linux-dd9d930cf75c-1794777576`); `SOURCE_COMMIT` matched the released SHA and `sha256sum -c SHA256SUMS-Linux.txt` returned `OK` for all three packages before collection.

Evidence: preflight on the released SHA `PREFLIGHT OK` (`+1238 ~46`, `flutter analyze` clean); 20 new tests cover the incomplete-drain report, per-action spinners, the marker round-trip and its invisibility in the note list, export plan, search and widget snapshot, the hold changing no document/folder/metadata row, the hold across a restart, an unaffected second vault, adoption requiring the decision, preserved local-only and hidden revisions, and the operation journal across a restart with its resume rules. Two independent review rounds returned blocking findings that were fixed and re-reviewed; the final reviews returned no blocking findings. The first 0.2.57 build failed in `:app:compileReleaseKotlin` (a `Service` has no `context` property, and `Notification.CATEGORY_SYNC` does not exist); the failure was diagnosed from the encrypted build diagnostics, fixed, and proven with `./gradlew :app:compileReleaseKotlin -x validateSiliqueReleaseSigning` → `BUILD SUCCESSFUL` before the successful CI build. All seven published assets were verified against the published `SHA256SUMS.txt` by digest (all match); `latest.json` payload base64-decodes to `{"version":"0.2.57","build":66}` with all seven platform keys and `appcast.xml` advertises `sparkle:version="66"`, `sparkle:shortVersionString="0.2.57"`. The server was not touched by this release.

---

# Silique 0.2.56+65 — release published

2026-11-15, on the owner's instruction, [Silique 0.2.56](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.56) was published: seven installers (macOS DMG, Android APK, Windows EXE/ZIP, three Linux GTK4 packages) plus `SHA256SUMS.txt`; both signed update feeds point at build 65. Source code for every package: `f73da934e08187df5ad63551ffa1202ba4f91628` (`main`, 0.2.56+65). Scope and notes: [0.2.56](0.2.56.md), design and non-goals: [sync-recovery](sync-recovery.md).

A stalled vault was previously indistinguishable from a divergent one, and a single failing vault aborted the whole pass, so a device in that state pulled nothing and could not detect any conflict either. The release adds three layers. Per-vault status (last success, last attempt, last error and its time, pending and diverged counts) in a local-only `sync_state` table, with failures isolated per vault and the first error reported after the loop. Two recovery actions: "Force full pull" replays the changelog from cursor 0 and materialises it through the normal reconcile and image cache without touching the server — the only recovery path for a vault whose push keeps failing, because a regular pass never reaches its pull — and "Send pending changes" drains the durable batch and the pending queue with bounded pushes. A source-of-truth reset pulls the full history first, then writes one revision per note whose parents are all server heads (deterministic chain above the server's 32-parent limit), deletion revisions for notes deleted here and for heads with no local document, deterministic idempotent losing copies, and a queue retirement restricted to the revisions a reset revision actually supersedes; hidden notes stay out of scope and are reported. Also fixed: `_cacheImages` runs between the pull and the push and propagated every image failure, so one note citing an image the server answers with `404` aborted each pass before that device's own edits were sent. No protocol, crypto, DAG, data-migration or server change.

Runs: macOS/Android [43717225546](https://github.com/Haniewicz/silique-releases/actions/runs/43717225546), Windows [43717228400](https://github.com/Haniewicz/silique-releases/actions/runs/43717228400), signed preparation [43719073764](https://github.com/Haniewicz/silique-releases/actions/runs/43719073764), publication [43719278122](https://github.com/Haniewicz/silique-releases/actions/runs/43719278122) — all `success`. Candidate draft `candidate-0.2.56-65` carries the seven installers. Linux built in CT 104 (`artifacts/linux-f73da934e081-1794748874`); `SOURCE_COMMIT` matched the released SHA and `sha256sum -c SHA256SUMS-Linux.txt` returned `OK` for all three packages before collection.

Evidence: preflight on the released SHA `PREFLIGHT OK` (`+1218 ~46`, `flutter analyze` clean); 23 tests in `test/sync_recovery_test.dart` cover status recording, per-vault failure isolation, full pull from a stale cursor, queue drain, the 32/33-head chain boundary, queue retirement restricted to superseded revisions, hidden-note exclusion, deterministic idempotent copies and the destructive confirmation flow. Three regression tests were proven red before their fix and green after it: the 410 tombstone path that the first review round caught, a note existing only locally at reset time, and the lost-image `404` pass abort. Two independent review rounds on `deepseek-v4-pro-0813` returned blocking findings that were fixed and re-reviewed; the final review returned `ok`. All seven published assets were verified against the published `SHA256SUMS.txt` by digest (all match); `latest.json` payload base64-decodes to `{"version":"0.2.56","build":65}` with all seven platform keys and `appcast.xml` advertises `sparkle:version="65"`, `sparkle:shortVersionString="0.2.56"`. The server was not touched by this release.

---

# Silique 0.2.55+64 — release published

2026-11-15, on the owner's instruction, [Silique 0.2.55](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.55) was published: seven installers (macOS DMG, Android APK, Windows EXE/ZIP, three Linux GTK4 packages) plus `SHA256SUMS.txt`; both signed update feeds point at build 64. Source code for every package: `743c9fd809dfcbba8f274102f4dd9c482238b6fa` (`main`, 0.2.55+64). Scope and notes: [0.2.55](0.2.55.md).

The release unblocks a vault whose re-uploaded history cites an image that no longer exists locally: the fresh server requires a manifest for every image listed in the batch, so each batch carrying such an id failed with `409 Image not uploaded yet` and the whole DAG stayed stuck with no local bytes to satisfy it. The wire now lists only image ids that still have a local asset, a queued batch is re-filtered the same way under a fresh batch id, and an image the server reports as `purged` is no longer marked uploaded. Note payloads and revision payloads are never modified — only the server-side image reference list is reduced; the affected historical version may show a placeholder for that one image on another device. No protocol, crypto, DAG or tombstone changes.

Runs: macOS/Android [43671420966](https://github.com/Haniewicz/silique-releases/actions/runs/43671420966), Windows [43671423629](https://github.com/Haniewicz/silique-releases/actions/runs/43671423629), signed preparation [43673640500](https://github.com/Haniewicz/silique-releases/actions/runs/43673640500), publication [43673815896](https://github.com/Haniewicz/silique-releases/actions/runs/43673815896) — all `success`. Candidate draft `candidate-0.2.55-64` carries the seven installers. Linux built in CT 104 (`artifacts/linux-743c9fd809df-1794713329`); `SOURCE_COMMIT` matched the released SHA and `sha256sum -c SHA256SUMS-Linux.txt` returned `OK` for all three packages before collection.

Evidence: preflight on the released SHA `PREFLIGHT OK` (`+1195 ~46`); independent review of the fix returned `APPROVE` with no blocking findings, confirming that the wire `images` field is upload metadata only (the receiving side derives image references from the note body, never from that field). New regression tests (lost image reference, already queued batch, purged image) were red on the previous commit and green after the change. The failure was diagnosed from the owner's actual vault database: one vault with 21 notes, 3741 pending revisions and a queued batch whose three historical revisions cite an image whose rows had already been removed locally (`image_assets`/`image_chunks` empty). All seven published assets were verified against the published `SHA256SUMS.txt` by name (all `OK`); `latest.json` payload decodes to `{"schema":1,"version":"0.2.55","build":64}` and `appcast.xml` advertises `sparkle:version="64"`, `sparkle:shortVersionString="0.2.55"`.

---

# Silique 0.2.54+63 — release published

2026-11-15, on the owner's instruction, [Silique 0.2.54](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.54) was published: seven installers (macOS DMG, Android APK, Windows EXE/ZIP, three Linux GTK4 packages) plus `SHA256SUMS.txt`; both signed update feeds point at build 63. Source code for every package: `db832aefa2e674379cfd668dbd7cdf1ce44a0bdb` (`main`, 0.2.54+63). Scope and notes: [0.2.54](0.2.54.md).

The release fixes a synchronization deadlock after switching a vault to another server (the 0.2.53 re-bind path). A fresh server rejected the whole batch with `409 Image not uploaded yet` because a revision cited an image whose manifest it never received, while the client considered the image already uploaded (it had been sent to the previous server) and never re-sent it; every pass failed identically. The client now re-marks all vault images for upload on a fresh-server rebind and on `Parent revision missing` recovery, self-heals `409 Image not uploaded yet` once (re-upload, retry the same batch), reports a readable PL/EN message on a second failure, and reports a missing local image chunk with the image and note ids instead of crashing. No protocol, crypto, DAG or tombstone changes.

Runs: macOS/Android [43665277747](https://github.com/Haniewicz/silique-releases/actions/runs/43665277747), Windows [43665280180](https://github.com/Haniewicz/silique-releases/actions/runs/43665280180), signed preparation [43667780030](https://github.com/Haniewicz/silique-releases/actions/runs/43667780030), publication [43667962072](https://github.com/Haniewicz/silique-releases/actions/runs/43667962072) — all `success`. Candidate draft `candidate-0.2.54-63` carries the seven installers. Linux built in CT 104 (`artifacts/linux-db832aefa2e6-1794708569`); `SOURCE_COMMIT` matched the released SHA and `sha256sum -c SHA256SUMS-Linux.txt` returned `OK` for all three packages before collection.

Evidence: preflight on the released SHA `PREFLIGHT OK` (`+1192 ~46`); independent review of the fix returned `APPROVE` with no blocking findings, and all four new regression tests were proven red on the base commit and green after the fix. The defect was reproduced against the real server code path (same older server build as the owner's new instance): the batch returned `409 Image not uploaded yet`, was accepted after the image upload, and repeated chunk/manifest PUTs were idempotent (200). All seven published assets were verified against the published `SHA256SUMS.txt` by name (all `OK`); `latest.json` payload decodes to `{"schema":1,"version":"0.2.54","build":63}` and `appcast.xml` advertises `sparkle:version="63"`, `sparkle:shortVersionString="0.2.54"`. The owner explicitly waived testing on his own device for this release; that is a decision, not a test result. Existing stuck vaults recover on the first sync after installing this build.

Note: `dev` carried the 0.2.53 source fix without the release bump, so this release merged `dev` into `main` before bumping; the release commit is the merge plus the bump and notes, and `dev` was fast-forwarded to `main` afterwards.

---

# Silique 0.2.53+62 — release published

2026-11-15, on the owner's instruction, [Silique 0.2.53](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.53) was published: seven installers (macOS DMG, Android APK, Windows EXE/ZIP, three Linux GTK4 packages) plus `SHA256SUMS.txt`; both signed update feeds point at build 62. Source code for every package: `678c9950ff057f37eb62f78ab33a9f817a485641` (`main`, 0.2.53+62). Scope and notes: [0.2.53](0.2.53.md).

The release fixes two synchronization defects. A vault the sync pass cannot handle (account recorded for it differs from the signed-in account, sync disabled, key locked, deletion pending) is now reported with its reason instead of the pass ending as a silent no-op, and the sync switch stays usable. A vault is now identified by its own ID rather than by the server it was last synced with: `owner` is provenance only (bare account id, no `server|` prefix), historical values are tolerated, and switching to another server re-binds the vault automatically (vault key re-wrapped with the account key, `PUT` against the server's live version). A server that does not know the vault receives the whole local revision chain parent-first in server-sized batches, idempotently (`409 Parent revision missing` triggers a full ordered re-upload, `Revision ID collision` counts as already sent). A vault deleted on the server is never recreated silently. No crypto, AAD or data-migration changes.

Runs: macOS/Android [43656857029](https://github.com/Haniewicz/silique-releases/actions/runs/43656857029), Windows [43656860125](https://github.com/Haniewicz/silique-releases/actions/runs/43656860125), signed preparation [43659633215](https://github.com/Haniewicz/silique-releases/actions/runs/43659633215), publication [43659833348](https://github.com/Haniewicz/silique-releases/actions/runs/43659833348) — all `success`, no step with a non-success `outcome`. Linux built in CT 104 (`artifacts/linux-678c9950ff05-1794702297`); `SOURCE_COMMIT` matched the released SHA and `sha256sum -c SHA256SUMS-Linux.txt` returned `OK` for all three packages before collection. The candidate draft `candidate-0.2.53-62` carries the seven installers.

Evidence: preflight on the released SHA `PREFLIGHT OK` (`+1188 ~46`, `RC=0`). The first preflight attempt failed with two `TimeoutException after 0:10:00` hangs in `test/home_language_test.dart` plus the `!inTest` cascade; that file passed three times in isolation (about 8 s each) and the whole preflight was rerun, so the second result is the gate. `flutter analyze` clean. Independent code review returned `APPROVE` for all seven requirements. Five of the seven published assets were downloaded and verified against the published `SHA256SUMS.txt` (macOS DMG, Android APK and the three Linux packages — all `OK`); the Windows EXE and ZIP are listed in the same signed file but were not downloaded locally for verification. The owner has not yet installed this build on a device, so on-device behaviour is unverified rather than tested.

Process note: the second implementation card was blocked by the harness adapter after a lost claim (`stale_lock`) while its work sat uncommitted in the worktree; the coordinator finished it as salvage (commit `d9d3c6e`). Two red gates in that salvaged work were fixture defects (a mock without a `POST /batches` handler, a `tap` outside the viewport, an over-strict `owner` format assertion), not product defects. The server was not touched by this release. Housekeeping: drafts `candidate-0.2.53-62`, `candidate-0.2.52-61` and older remain, since deleting releases is owner-only.

---

# Silique 0.2.52+61 — release published

2026-11-14, on the owner's instruction, [Silique 0.2.52](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.52) was published: seven installers (macOS DMG, Android APK, Windows EXE/ZIP, three Linux GTK4 packages) plus `SHA256SUMS.txt`; both signed update feeds point at build 61. Source code for every package: `cba1ffa9eb8ac05abf02f6880df9c53f81bb0e94` (`main`, 0.2.52+61). Scope and notes: [0.2.52](0.2.52.md).

The release adds whole-vault export: from *Manage vaults* every active note is written as a `.md` file named after its title, duplicates get ` (1)`, ` (2)`, … before the extension (case-insensitive), the vault folder tree is mirrored including empty folders, images go to `_images` with depth-relative links, the trash is skipped, and hidden notes are opt-in behind their password and land in `_hidden`. Desktop writes to a chosen directory; Android/iOS share a ZIP. No server or data-layer change.

Runs: macOS/Android [43609057251](https://github.com/Haniewicz/silique-releases/actions/runs/43609057251), Windows [43609060183](https://github.com/Haniewicz/silique-releases/actions/runs/43609060183), signed preparation [43611990760](https://github.com/Haniewicz/silique-releases/actions/runs/43611990760), publication [43612230947](https://github.com/Haniewicz/silique-releases/actions/runs/43612230947) — all `success`. Candidate draft `candidate-0.2.52-61` carries the seven installers. Linux built in CT 104 (`artifacts/linux-cba1ffa9eb8a-1794670101`); `SOURCE_COMMIT` and `SHA256SUMS-Linux.txt` verified locally (`sha256sum -c`: all `OK`) before collection.

Evidence: preflight on the released SHA `PREFLIGHT OK` (1175 passed, 46 skipped, `flutter analyze` clean); independent code review of the feature accepted all nine requirements; all seven published assets verified against the published `SHA256SUMS.txt` by name (all `OK`); `latest.json` payload decodes to `{"schema":1,"version":"0.2.52","build":61}` and `appcast.xml` advertises `sparkle:version="61"`, `sparkle:shortVersionString="0.2.52"` with the signed DMG enclosure. The owner explicitly waived testing on his own device for this release; that is a decision, not a test result.

Housekeeping: the draft `candidate-0.2.52-61` remains (deleting releases is owner-only), as do `candidate-0.2.51-60` and older drafts. Two `tool/` contract suites (`test_linux_native_dependencies`, `test_windows_close_probe`) fail identically on the previous `dev` commit; they are pre-existing environment/stale-contract failures, not caused by this release.

---

# Silique 0.2.51+60 — release published

2026-11-13, on the owner's instruction, [Silique 0.2.51](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.51) was published: seven installers (macOS DMG, Android APK, Windows EXE/ZIP, three Linux GTK4 packages) plus `SHA256SUMS.txt`; both signed update feeds point at build 60. Source code for every package: `ee1b22b1b1d517a925ce72849515c1c616c07c1b` (`main`, 0.2.51+60). Scope and notes: [0.2.51](0.2.51.md).

The release fixes one defect: appearance settings (compact mode, folder/note colours, default colours, folder order) could not be changed while a vault belonged to an account but the app had no owner session — `_writeMeta` threw `Connect the vault owner's account.` before the offline-tolerant path. The change now stays local as a pending edit and is pushed by the next sync after sign-in.

Runs: macOS/Android [43425090180](https://github.com/Haniewicz/silique-releases/actions/runs/43425090180), Windows [43425096009](https://github.com/Haniewicz/silique-releases/actions/runs/43425096009), signed preparation [43430272378](https://github.com/Haniewicz/silique-releases/actions/runs/43430272378), publication [43431049330](https://github.com/Haniewicz/silique-releases/actions/runs/43431049330) — all `success`, no step with a non-success `outcome`. Linux built in CT 104; `SOURCE_COMMIT` and `SHA256SUMS-Linux.txt` verified locally before collection.

Evidence: preflight on the released SHA `PREFLIGHT OK` (+1141 passed, ~46 skipped), adapter RED gate proved the new regression test red on the pre-fix commit, `flutter analyze` clean. All seven published assets were verified against the published `SHA256SUMS.txt` (all `OK`). The owner explicitly waived testing on his own device for this release; that is a decision, not a test result.

The server was not touched by this release. Housekeeping note: draft releases `candidate-0.2.51-60` and `candidate-0.2.50-59` remain, since deleting releases is owner-only.

---

# Silique 0.2.51+60 — wydanie opublikowane

2026-11-13, na polecenie właściciela, opublikowano [Silique 0.2.51](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.51): siedem instalatorów (macOS DMG, Android APK, Windows EXE/ZIP, trzy pakiety Linux GTK4) oraz `SHA256SUMS.txt`; oba podpisane kanały wskazują build 60. Kod wszystkich paczek: `ee1b22b1b1d517a925ce72849515c1c616c07c1b` (`main`, 0.2.51+60). Zakres i notki: [0.2.51](0.2.51.md).

Wydanie naprawia jeden defekt: nie dało się zmienić ustawień wyglądu (tryb kompaktowy, kolory folderów i notatek, kolory domyślne, kolejność folderów), gdy vault należał do konta, a aplikacja nie miała sesji właściciela — `_writeMeta` rzucał `Połącz konto właściciela vaulta.` przed ścieżką tolerującą offline. Zmiana zostaje teraz lokalnie jako oczekująca i wchodzi na serwer przy najbliższej synchronizacji po zalogowaniu.

Uruchomienia: macOS/Android [43425090180](https://github.com/Haniewicz/silique-releases/actions/runs/43425090180), Windows [43425096009](https://github.com/Haniewicz/silique-releases/actions/runs/43425096009), przygotowanie podpisane [43430272378](https://github.com/Haniewicz/silique-releases/actions/runs/43430272378), publikacja [43431049330](https://github.com/Haniewicz/silique-releases/actions/runs/43431049330) — wszystkie `success`, żaden krok z `outcome` innym niż sukces. Linux zbudowany w CT 104; `SOURCE_COMMIT` i `SHA256SUMS-Linux.txt` zweryfikowane lokalnie przed zebraniem.

Dowody: preflight na wydanym SHA `PREFLIGHT OK` (+1141 przeszło, ~46 pominiętych), bramka RED adaptera dowiodła czerwoności nowego testu regresyjnego na commicie sprzed poprawki, `flutter analyze` czysty. Wszystkie siedem opublikowanych assetów zweryfikowano wobec opublikowanego `SHA256SUMS.txt` (wszystkie `OK`). Właściciel świadomie zrezygnował z testu na własnym urządzeniu dla tego wydania; to decyzja, nie wynik testu.

Serwera to wydanie nie dotykało. Uwaga porządkowa: pozostają szkice `candidate-0.2.51-60` i `candidate-0.2.50-59`, bo usuwanie wydań należy wyłącznie do właściciela.

---

# Silique — rotacja tożsamości podpisu macOS: CN=Nova Notes Local Preview → CN=Silique (2026-11-10, NIEWYDANE)

Decyzja właściciela z 2026-11-10 (zaktualizowana): brak konta Apple Developer, więc
pozostajemy przy self-signed, ale CN podpisu macOS zmienia brzmienie na `Silique`.
**Android zostaje bez zmian** — ten sam keystore, `CN=Nova Notes`, alias `nova-notes`,
ten sam pin. Tożsamości są teraz **asymetryczne**: macOS `Silique`, Android
`Nova Notes`. To świadoma decyzja, nie niedoróbka.

- Stary certyfikat macOS: `CN=Nova Notes Local Preview`, SHA-256 liścia
  `842a631b45769ded85da4db28638a7060d18628f04b8e721da8f0a3195844217`.
- Nowy certyfikat macOS: `CN=Silique`, self-signed (RSA 2048, 3650 dni). SHA-256
  liścia powstaje z wyjścia `tool/make_signing_identity.sh` — patrz
  [migration-signing-identity.md](migration-signing-identity.md). Dopóki właściciel
  nie uruchomi generatora i nie wpisze realnego odcisku, pin w `tool/macos_dmg.py`
  jest placeholderem `0000…0000` (64 zera). **Nie wydawać żadnego macOS wydania,
  dopóki placeholder nie zostanie podmieniony.**
- `SUPublicEDKey` (klucz Ed25519 aktualizatora) **bez zmian**.
- Bundle id `pl.novanotes.novaNotes` (macOS) i `pl.novanotes.nova_notes` (Android)
  **bez zmian**; katalog `Nova Notes` i `/.well-known/nova-notes` **bez zmian**.
- Wydania **≤ 0.2.45** są podpisane starą tożsamością macOS `CN=Nova Notes Local
  Preview`. Po rotacji rejestr podpisu zmienia się od pierwszego wydania z nowym
  certyfikatem — macOS wymaga **jednorazowej ręcznej reinstalacji DMG** (właściciel
  to akceptuje wyłącznie dla macOS). Android nie wymaga żadnej akcji użytkownika.
- Sekrety do podmiany przez właściciela (tylko macOS): `SILIQUE_MACOS_P12`,
  `SILIQUE_MACOS_P12_PASSWORD`, `SILIQUE_MACOS_CERT` (bez wartości w repo).

---

# Silique 0.2.44+53 — opublikowane: etykieta pęku kluczy macOS migrowana w miejscu

[Publiczne wydanie](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.44),
`2026-11-07T13:16:37Z`, latest, **7 instalatorów + SHA256SUMS.txt** (8 assetów; sumy zgodne
z digestami API). Release id `437587816`. Bump `0.2.44+53`.
Zgoda właściciela: „Zrób push i release oraz napraw bramkę adaptera” (2026-11-07) — obejmuje
to jedno wydanie; **właściciel nie wykonał osobistego testu na urządzeniu**, więc zapis dotyczy
zgody na publikację, nie potwierdzenia działania dialogu macOS.
Kanały: `appcast.xml` → 0.2.44 / build 53, `latest.json` → 0.2.44. Publiczne pobranie anonimowe:
APK HTTP 200, DEB/DMG HTTP 200 (range read 1024 B). Szkic `candidate-0.2.44-53`
(id `437584983`, 7 assetów) zachowany.

Wspólne źródło wszystkich platform: `0689fdcefb287df014cec672a982e383a2ff7dde`
(`main` = origin/main). Notatki: [0.2.44.md](0.2.44.md).

Runs: macOS+Android `42374006616`, Windows `42374008860`, podpisane przygotowanie
`42375788487`, publikacja `42375994363` — wszystkie `success`.
Paczki Linuksa: `artifacts/linux-0689fdcefb28-1794056453/` (SOURCE_COMMIT pełny SHA,
`SHA256SUMS-Linux.txt`: deb `423ed840…`, rpm `e3425e63…`, tar.gz `98dbb160…`).

## Co zmieniono

Karta `t_a1b02fb9` (board `dev`, lane `harness-dsh`), dwa commity źródłowe `51caf328` +
`6310901e`: systemowy dialog pęku kluczy na macOS pokazywał historyczną nazwę wpisu, bo
etykieta była ustawiana wyłącznie przy tworzeniu nowego wpisu (`SecItemAdd`). Teraz po udanym
zapisie i przy pierwszym odczycie kluczy `SecItemUpdate` ustawia `kSecAttrLabel` na
„Silique — klucze lokalne” **na istniejącym wpisie** — bez `SecItemDelete`, bez odtwarzania
wpisu, bez zmian identyfikatorów usługi, konta i trybu keychain plikowego.
Migracja jest jednorazowa: znacznik `silique.keychainLabelMigrated` w `UserDefaults` plus
`_relabelAttempted` w Dart, więc przy ustawionej fladze aplikacja nie dotyka pęku kluczy
w tym celu (jednorazowa zgoda „Pozwól” nie generuje drugiego okna).

## Weryfikacja

- Bramka karty (adapter `harness-dsh-dev`): `flutter test` zielony; nowy
  `tool/test_keychain_label_migration.py` — 7/7. Kontrola negatywna na `51caf328` (bez
  guardu jednorazowości): 2 FAIL (`test_relabel_is_one_shot_per_install`,
  `test_dart_relabel_is_once_per_process`). `tool/test_branding_compatibility.py` OK,
  `tool/test_native_language.py` OK (1 skip).
- Koordynator: `flutter analyze` → `No issues found!` na `6310901e`.
- Preflight na SHA wydania: pierwszy przebieg **czerwony** na
  `test/sync_status_badge_test.dart: syncing: small green spinner with the syncing tooltip`
  (`pumpAndSettle timed out` w `drainUntil`, `hidden_notes_home_test.dart:22`) — flake
  czasowy pod `--concurrency=2`; 3/3 izolowane przebiegi tego pliku zielone (`All tests passed!`),
  drugi przebieg ograniczony: `+1081 ~46`, `PREFLIGHT_EXIT=0`.
- Bramka CI obu workflowów kandydatów zielona na tym samym SHA; builder GTK4 (CT 104):
  `No issues found`, `All tests passed!`, `LINUX_EXIT=0`.
- Publiczny odczyt po publikacji: `verify_public_release.py --tag v0.2.44` →
  `release id=437587816 assets=8`, sumy zgodne z digestami API, `latest.json` → 0.2.44/53,
  podpisy manifestu, appcastu i DMG OK, DMG UDIF trailer OK.

## Pozostaje do sprawdzenia przez właściciela

- macOS: po aktualizacji pierwszy odczyt kluczy powinien pokazać w dialogu
  „Silique — klucze lokalne”. To jedyny element, którego nie da się zweryfikować poza macOS.
- macOS podpisany certyfikatem podglądu bez notaryzacji Apple — możliwe „Otwórz mimo to”.
  Windows bez Authenticode — UAC „nieznany wydawca”.

# Silique 0.2.43+52 — opublikowane: trafianie kursorem GTK4, zakładki Ustawień, auto-restart, kompakt

[Publiczne wydanie](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.43),
`2026-11-07T10:26:49Z`, latest, **7 instalatorów + SHA256SUMS.txt** (8 assetów; sumy zgodne
z digestami API i z lokalnymi paczkami Linuksa). Bump `0.2.43+52`.
Zgoda właściciela: „Po zmianach nie czekaj na decyzję, tylko opublikuj” (2026-11-07) —
obejmuje wyłącznie to wydanie, bez ręcznego testu na urządzeniach.
Kanały: `appcast.xml` → 0.2.43 / build 52. Publiczne pobranie anonimowe: APK 68 724 806 B,
DEB 14 001 532 B (HTTP 200, rozmiary zgodne z lokalnymi). Szkic `candidate-0.2.43-52` zachowany.

Wspólne źródło wszystkich platform: `215551658e326140009c6883e7aa94bd48e618b7`
(`main` = origin/main). Notatki: [0.2.43.md](0.2.43.md).

Zlecenie właściciela: pięć poprawek UI/Linuksa + publikacja. Board `dev`, worktree per karta,
lane `harness-dsh` (DeepSeek), uzupełniane pracą koordynatora:

- **Trafianie kursorem na Linuksie (GTK4)** — praca koordynatora, commit `8be96be`.
  Pomiar instrumentowanym silnikiem na CT 104: powierzchnia 1280×720, treść 1270×664,
  `point=(0,46)` (pasek tytułu), `transform=(5,5)` (obramowanie CSD) → początek treści
  w powierzchni to `(5,51)`, a `51+664+5=720` się zgadza. Kod liczył jednak `point − transform`
  = `(−5,41)`, więc każde zdarzenie wskaźnika było raportowane 10 px w prawo i 10 px w dół —
  dokładnie objaw „klik działa, gdy kursor jest wyżej”. Wyliczenie przeniesione do wspólnego
  helpera `fl_gtk_surface_update_content_offset` (`fl_gtk.h`), wywoływanego z `fl_view.cc`;
  patch silnika zregenerowany, `apply --reverse --check` na SDK = 0, forward-check na czystym
  silniku = 0, silnik przebudowany inkrementalnie. Nowy test natywny
  `tool/test_gtk4_pointer_position.py` (prawdziwe okno z paskiem tytułu, zmiana rozmiaru, klik
  w wyliczony środek celu 10×10): kontrola negatywna na starym znaku `(147,221)` vs
  oczekiwane `(137,211)` — RED; po poprawce `(137,211)` — GREEN. Wpięty w `tool/ci_linux_gtk4.sh`.
- `t_a4453ad8` → commit `8d8bb45`: przełącznik `compact-select-mode` na końcu wiersza filtrów
  (`Expanded`, prawa krawędź 13 px) + `selection-bar`, licznik i `select-all` także w sidebarze
  kompaktowym. **Salvage**: commit harnessa zawierał cały `.dsh-pub-cache` (21 829 plików) —
  do main weszły tylko `lib/ui/home.dart` i test, cache trafił do `.gitignore`.
  Test R3 z tej karty przechodził także bez poprawki (`tester.tap` nie emituje ruchu).
- **Jednoklikowe rozwijanie folderu** — praca koordynatora, commit `bd69a5e`: wiersze folderów
  i notatek były w natychmiastowym `Draggable`, którego recognizer wygrywa arenę przy pierwszym
  pikselu ruchu — a realne kliknięcie na Linuksie drga o ułamek piksela. Zmierzone w izolacji:
  czysty tap → `taps=1`, tap z ruchem 1,5 px → `taps=0, drags=1`. Desktop używa teraz
  `LongPressDraggable` z holdem 150 ms (dotyk bez zmian), a test zamontowany w trybie kompaktowym
  symuluje kliknięcie z drgnięciem: RED bez poprawki, GREEN z poprawką. Testy przeciągania
  (folder_drop_indicator, folder_reorder_ui_regression, workspace_ui_test, workspace_review_ui_test)
  czekają teraz na hold.
- `t_0c1fb4d4` → commit `9efea37`: zakładki Ustawień przewijają się kółkiem myszy i przeciąganiem
  (`TabBarScrollController` + `Listener` przerzucający obie osie kółka + `ScrollConfiguration`
  z myszą). **Salvage**: fixture wołał `repo.close()` w `tearDown`, co deadlockuje na koordynatorze
  syncu (kontrakt: `repo.storage.close()`), a asercje wymagały pełnego odsłonięcia paska po jednym
  skoku 120 px przy przepełnieniu ~513 px. RED bez poprawki (1156,9 px poza paskiem), GREEN 3/3.
- `t_0bfa38dc` → commit `dbc7f4bf`: po udanej instalacji DEB/RPM aplikacja startuje nowy proces
  (`NativeWindow.restart`: detached `Platform.resolvedExecutable` + normalne zamknięcie okna,
  bez `exit()`) i pokazuje komunikat o ponownym uruchomieniu; `cancelled`/`failed` nigdy nie
  restartują, flaga jednorazowa, wyjątek restartu daje komunikat awaryjny. Bramka karty padła na
  flake `wiki_suggestions_overlay_test` (obszar nietknięty; test 4/4 zielony w izolacji).

Dowody: pełny suite na SHA wydania `21555165` (`flutter test --concurrency=2`):
**1081 przeszło, 46 pominiętych, 0 porażek**. Builder CT 104: `flutter analyze` czysty, suite
`+1081 ~46`, 14 kontroli natywnych GTK4 PASS (m.in. `native-pointer-after-resize`), paczki
w `artifacts/linux-215551658e32-1794046087` (DEB 14 001 532 B). Workflow: Windows
[42361698267](https://github.com/Haniewicz/silique-releases/actions/runs/42361698267),
macOS/Android [42361696115](https://github.com/Haniewicz/silique-releases/actions/runs/42361696115),
przygotowanie [42363585921](https://github.com/Haniewicz/silique-releases/actions/runs/42363585921),
publikacja [42363864296](https://github.com/Haniewicz/silique-releases/actions/runs/42363864296)
— wszystkie success. Weryfikacja publicznych bajtów (`verify_public_release.py --tag v0.2.43`):
PASS — 7/7 sum, manifest 0.2.43+52 z 7 platformami, podpisy manifestu, appcastu i DMG, trailer UDIF.

Serwera produkcyjnego nie zmieniano.

# Silique 0.2.42+51 — opublikowane: kompaktowy sidebar, odstępy, karty, resize okna GTK4

[Publiczne wydanie](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.42),
`2026-11-07T06:33:18Z`, latest, **7 instalatorów + SHA256SUMS.txt** (sumy zgodne z lokalnymi
paczami Linuksa). Bump `0.2.42+51`. Zgoda właściciela na publikację: „Opublikuj” (2026-11-07),
po przygotowaniu `42326161268` i publikacji `42347384093` (**success**).
Kanały: `appcast.xml` → 0.2.42 / build 51, commit kanałów `4ec1798a`; publiczne pobranie
anonimowe sprawdzone (APK 68 708 422 B, DEB 14 002 130 B — HTTP 200, rozmiary zgodne).
Szkic `candidate-0.2.42-51` zachowany.

Wspólne źródło wszystkich platform: `070347eb431bb92044e49e0dd2dd838245b3ed3e`
(`main` = origin/main). Bump `0.2.42+51` w `070347e`; notatki: [0.2.42.md](0.2.42.md).

Zlecenie właściciela: siedem poprawek UI + naprawa zmiany rozmiaru okna na Linuksie
+ publikacja nowego wydania. Tryb 2 (wybór właściciela), board `dev`, worktree per karta:

- `t_5b07980d` → commit `45e469c` (merge `a134f46`): w trybie kompaktowym filtry
  Usunięte / Ukryte / Ostatnie / Ulubione renderują płaską listę notatek w sidebarze
  (300 px) z wierszem „← Wszystkie notatki”, bez osobnej kolumny listy notatek;
  aktywne wpisy podświetlone; obie ścieżki (desktop + drawer). **Salvage koordynatora**:
  przepełnienie wiersza powrotu o 1,3 px w drawerze + test ukrytych notatek (drainUntil,
  jawne `lockHidden()`).
- `t_c0517c86` → commit `a1cddcc`: odstęp 4 px nad każdą notatką w drzewie kompaktowym
  (desktop i drawer), przycisk „Nowy wpis w dzienniku” z promieniem 8 i insetami jak
  „Nowa notatka” (`new-journal-entry` / `new-note-button`), zamknięcie karty wraca do
  ostatnio UŻYWANEJ karty, potem do sąsiada z prawej, potem z lewej; wspólna `_dropTab`
  także dla karty znikającej po usunięciu notatki.
- `t_c3ffb4e0` → commit `2572e7d`: naprawa zmiany rozmiaru okna GTK4 —
  `fl_render_texture_gtk4_measure` zwracało bieżącą alokację tekstury jako `*minimum`,
  więc okno dało się tylko powiększać. `*minimum = 0`, przebudowa silnika **inkrementalna**
  (1 rekompilacja + relink, bez `gclient sync`/ANGLE — poprzednia blokada dotyczyła pełnej
  przebudowy). Pomiar na CT 104: 1280×720 → 800×600 OK, → 1400×900 OK, 400×300 klampuje
  na `minimumSize` 760×560; kontrola negatywna na silniku bez poprawki: brak zmniejszania.
  Nowy `libflutter_linux_gtk4.so` sha256 `7e5b7c81…`, patch↔SDK `apply --reverse --check`
  = 0.

Recenzje (profil `analyst`, read-only, model `deepseek-v4-pro`): `t_ac19c460`,
`t_5f3b288f`, `t_23cf76bd` — wszystkie **ZATWIERDZONE**.

Dowody: pełny suite na SHA wydania `070347e` (`flutter test --concurrency=2`):
**1072 przeszło, 46 pominiętych, 0 porażek**. Na builderze CT 104: `flutter analyze`
czysty, suite `+1072 ~46 All tests passed`, 14 kontroli natywnych GTK4 (m.in.
`native-pointer-after-resize`), paczki w `artifacts/linux-070347eb431b-1794015865`
(sumy SHA256 zweryfikowane lokalnie). Workflow: Windows `42323090362`,
macOS/Android `42323087598`. Pierwsza próba `linux-build` padła na jednym flaky teście
(`desktop_document_viewport_test`, limit `drainUntil`) — powtórzona bez zmian w kodzie
przeszła; test przechodzi też lokalnie w izolacji.

Serwera produkcyjnego nie zmieniano.

# Silique 0.2.41+50 — opublikowane: kolory (picker RGB), sekcja „Wygląd”, UI

[Publiczne wydanie](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.41),
`2026-11-06T18:10:02Z`, latest, **7 instalatorów + SHA256SUMS.txt**.
Wspólne źródło wszystkich platform: `746e35fc72094a4d19bd5b923cfccf9b4dc642e7`.
Szkic zachowany: `candidate-0.2.41-50`.

Zlecenie właściciela: dziewięć poprawek UX i publikacja **bez ręcznego testu**
(„wypuść nowy release bez czekania na mój ręczny test”) — ta zgoda obejmuje wyłącznie
to wydanie. Tryb 2 (wybór właściciela): trzy karty sekwencyjnie na boardzie `dev`,
lane profilu `coder`, model `deepseek-v4-pro`, trasa `deepseek`, worktree per karta.

- `t_e9d0a728` → commit `8a884ce`: współdzielony picker `lib/ui/color_picker.dart`
  (pole SV + suwak hue, klik/przeciągnięcie, „Brak koloru”), używany przez foldery i notatki;
  metadane `noteColors`; jedna domyślna barwa ikon notatek zamiast hasha 4 kolorów.
- `t_ea3bfff6` → commit `705a760`: zakładka „Wygląd” (indeks 1), domyślne kolory notatek
  i folderów, pytanie o przemalowanie istniejących, tryb kompaktowy przeniesiony z „Ogólne”,
  `_updatesTabIndex` 3→4.
- `t_bb1671e9` → commit `45860f4`, **salvage koordynatora** (worker wyczerpał budżet
  150 iteracji z kompletnym kodem): slot wstawienia 3 px + 8 px przerwy przy zmianie
  kolejności folderów, status sync z `_dirty` (spinner po edycji, pomarańcz tylko przy
  realnym błędzie), usunięty przycisk „Szukaj”, „Dziennik” → „Nowy wpis w dzienniku”,
  zamknięcie karty po usunięciu otwartej notatki.
- `t_1f44fc97` (REVIEW, profil `analyst`, read-only): werdykt **APPROVE**, 9/9 wymagań
  spełnionych w kodzie; dwa zastrzeżenia nieblokujące (tooltip „Lokalnie” przed pierwszym
  passem, brak read-only wejścia do filtra „Dziennik” na desktopie).

Dowody: bramka koordynatora po każdej karcie w worktree (`flutter analyze` czysty;
18 / 51 / 19 testów PASS). Pełny suite na SHA wydania `9e32a5a` (kod + bump 0.2.41+50):
**1052 przeszło, 46 pominiętych, 0 porażek** (`flutter test --concurrency=2`).
Buildy: macOS/Android [42262754696](https://github.com/Haniewicz/silique-releases/actions/runs/42262754696),
Windows [42262760165](https://github.com/Haniewicz/silique-releases/actions/runs/42262760165),
Linux GTK4 CT 104 `artifacts/linux-746e35fc7209-1793987218`. Prepare
[42267295547](https://github.com/Haniewicz/silique-releases/actions/runs/42267295547), publikacja
[42267856049](https://github.com/Haniewicz/silique-releases/actions/runs/42267856049).
`verify_public_release.py --tag v0.2.41`: PASS — 7/7 sum zgodnych, manifest 0.2.41+50,
podpisy manifestu, appcastu i DMG OK.

Nie wykonano: testu instalacyjnego na urządzeniach właściciela (świadoma rezygnacja
dla tego wydania) oraz wdrożenia serwera — serwer bez zmian.

---

# Silique 0.2.40+49 — opublikowane: tryb kompaktowy (wyrównanie notatek, tworzenie folderu)

[Publiczne wydanie](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.40),
ID `436402902`, `2026-11-06T11:08:39Z`, latest, **7 instalatorów + SHA256SUMS.txt**.
Wspólne źródło wszystkich platform: `7995fccbbfb8e1d3e6c2bb3966fe9505cffed5c4`.
Szkic zachowany: `candidate-0.2.40-49` (ID `436398040`).

Karta `t_0941c038` (lane `dev`/`harness-qwen`, tryb 1, sesja `3cce9029`, model
`deepseek-v4-pro` po trasie `deepseek`): notatka w drzewie kompaktowym trafia w kolumny
podfolderu (`note-card` +20 px, gap po ikonie 9 zamiast 4 — oba buildery), a
`_folderDialog` w trybie kompaktowym nie ustawia już `_folder = path` (to wyłączało
`_compactTree` i filtrowało notatki do nowego, pustego folderu; objaw „notatki znikają
do restartu” z Androida) — zamiast tego `path` + przodkowie w `_compactExpanded`.
Praca dokończona **salvage'em koordynatora**: sesja harnessa wyczerpała
`max_session_turns` i utknęła na dwóch żądaniach ACL kontroli negatywnej (zatwierdzone),
commit `8c99a6a` z atrybucją, merge `--ff-only`.

Dowody: `flutter analyze` `No issues found!`; `test/compact_mode_sidebar_test.dart`
32/32; kontrola negatywna RED na kodzie bez poprawki (`dx = 21.0 px`). Pełny suite na
builderze GTK4 na SHA wydania: **1026/46/0** (`artifacts/linux-7995fccbbfb8-1793962545`),
CI macOS+Android `42202947314`, Windows `42202951162`, przygotowanie podpisów
`42207277143`, publikacja `42207684908` — wszystkie success. Dwa lokalne przebiegi na
AiBrain miały po jednym flake'u klasy „bounded test pump” (`editor_input_test`,
`home_language_test`; oba 3/3 zielone w izolacji), a pierwszy build Linux padł na tym
samym typie flake'a (`editor_live_selection_menu_owner_test`) i został powtórzony na
identycznym SHA bez zmiany kodu.

Weryfikacja publicznych bajtów (`verify_public_release.py --tag v0.2.40`): 8 assetów,
`SHA256SUMS.txt` zgodny z 7 digestami API, manifest 0.2.40+49 z 7 platformami, podpisy
manifestu, appcastu i DMG OK, trailer UDIF OK. Podpis APK nie był tym razem sprawdzany
lokalnie (materiał podpisujący i procedura CI bez zmian).

**Właściciel zrzekł się testu na urządzeniu dla tego wydania** (decyzja 2026-11-06) —
wyrównanie w kompakcie na fizycznym telefonie oraz tworzenie folderu w szufladzie przy
otwartej klawiaturze pozostają do sprawdzenia przy najbliższej okazji.

# Silique 0.2.36+45 — opublikowane: bloki kodu Linux + padding, toggle przy logo, RGB picker

[Publiczne wydanie](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.36),
ID `433866036`, `2026-11-04T12:05:43Z`, latest, **7 instalatorów + SHA256SUMS.txt**.
Wspólne źródło wszystkich platform: `5af7f9998019e93f0ec86822bbd3215f871cb289`.
[Zmiany, proweniencja lane, dowody i ograniczenia](0.2.36.md). Szkic zachowany:
`candidate-0.2.36-45` (ID `433859538`, `untagged-2c556a28adf2f3621655`).

Partia 2 kart lane `dev` (tryb 2), każda z niezależnym review APPROVE (D21 PASS):
BATCH 1/2 `t_d47cf343` — bundel Roboto Mono (OFL) zamiast generycznego `'monospace'`
(fix tofu na kliencie Linux; wiring + cmapa dowiedzione, wizualne potwierdzenie na
urządzeniu właściciela po aktualizacji) + lewy padding bloków kodu 14 px przez rzutowany
lead bez mutacji źródła; karta domknięta salvage'em koordynatora po błędzie kompilacji
harnessa (`boxHeightStyle` nie istnieje w Flutter 3.47.7) — ujawnienie
`reviews/0.2.36/A-salvage-disclosure.md`. BATCH 2/2 `t_8ea832fa` — toggle listy notatek
w nagłówku sidebara przy prawej krawędzi obok logo (stare przyciski usunięte) + RGB picker
koloru folderu (hex + suwaki R/G/B, walidacja, ARGB 0xff); zero edycji produktu przez
koordynatora, bramki adaptera czerwone flake'ami współbieżności (4 rdzenie, domyślne
shardy) — klasyfikacja i kronika w `reviews/0.2.36/B-salvage-disclosure.md`,
**rekomendacja: `tests.command` lane z `--concurrency=2` (decyzja właściciela)**.

Runy dla jednego SHA: macOS/Android `41820811351`, Windows `41820815587`, przygotowanie
`41825456946`, publikacja `41825922520` — wszystkie success; Linux na CT104
`artifacts/linux-5af7f9998019-1793792301` (**966/46/0**, analyze GTK4 `No issues found!
(9.3s)`, 14/14 prób natywnych, CT104 zatrzymany). Bramki: macOS 956/56/0 + native 92+1,
`Native DMG verify verified: 0.2.36+45`, APK V2 Verifies z `CN=Nova Notes` (cert SHA-256
`2021902e…996e`, tożsamość nie rotowana); Windows `native acceptance gates passed`
(interaktywne UAC/notebook właściciela nietestowane); lokalnie na dokładnym SHA surowy
analyze czysty + suite bounded **966/46/0**. Digesty kandydatów CI == publiczne API
(4/4), Linux zgodny z lokalnymi sumami (3/3).

Po publikacji (odczyt ze stanu publicznego): `verify_public_release.py --tag v0.2.36`
→ PASS wyłącznie z publicznych bajtów (podpisy Ed25519 manifestu/appcastu/DMG, trailer
UDIF, `SHA256SUMS.txt` == 7/7 digestów API, manifest 0.2.36 build 45 platforms 7);
`check_update_feed` → `Verified publisher signature: 0.2.36, build 45`; smoke
`updater_public_smoke_test` 1/1 (anonimowe pobranie APK realnym `UpdateClient`).
Zgoda właściciela 2026-11-04 (desktop): „Masz zgodę na wszystkie działania. Po zmianach,
zbuduj projekt i zrób release" — publikacja bez osobistego testu przedpublikacyjnego
(waiver zapisany); test na urządzeniach po publikacji. Serwera produkcyjnego nie
zmieniano. Prywatne kopie/diagnostyka: `~/.local/state/silique-release-handoff/0.2.36/`.

---

# Silique 0.2.35+44 — opublikowane, partia 12 poprawek UX

[Publiczne wydanie](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.35),
ID `433602347`, `2026-11-04T06:58:19Z`, latest, **7 instalatorów + SHA256SUMS.txt**.
Wspólne źródło wszystkich platform: `047a0da40d463e1e1b83482232d3aeeeb09c704b`.
[Zmiany, dowody i ograniczenia](0.2.35.md). Szkic zachowany:
`candidate-0.2.35-44` (ID `433596387`, `untagged-5a7d85f3806e656decae`).

Dziewięć kart lane `dev` (K1, K2, K3, K4, K5, K6, K7a, K7b, K9), każda z
niezależnym review APPROVE: folder w katalogu głównym + hover stopki; tytuł i tagi
przewijane z treścią oraz Enter do treści; pływające sugestie `[[linków]]`;
autokorekta Android + formatowanie bloków kodu; pełne menu edycji na każdej
platformie; klik aktualizacji otwiera Ustawienia na „Aktualizacje”; kolory
folderów (dane + sync, potem UI); zwijanie listy notatek. Punkt 11 zgłoszeń
(Android „Aplikacja nie została zainstalowana” przy świeżej instalacji)
zdiagnozowany bezkodowo: pakiety poprawne i podpisane dotychczasowym
certyfikatem, winne uszkodzone/niedokończone pobranie albo stan urządzenia.

Runy dla jednego SHA: macOS/Android `41784454633`, Windows `41784458891`,
podpisane przygotowanie `41788101374`, publikacja `41788759019` — wszystkie
success; Linux na CT104 `artifacts/linux-047a0da40d46-1793774821`
(**963/46/0**, analyze SDK GTK4 `No issues found! (8.8s)`, CT104 zatrzymany).
Bramki: macOS 953/56/0, `Native DMG verify verified: 0.2.35+44`, APK v2 = true
z `CN=Nova Notes` (cert SHA-256 `2021902e…996e`, tożsamość nie rotowana);
lokalna bramka 962/46/1 z flake'iem `windows_update_home_test` („bounded test
pump”) — 3× izolowanie 4/4 i obciążony repro 3×52 zielony, więc klasyfikowany
jako obciążeniowy. Dwa wcześniejsze podejścia zablokowały: dosłowne
`CN=Nova Notes` w `docs/0.2.31.md` poza allowlistą brandingu (fix `df97811`)
oraz `info` z **gołego** `flutter analyze` (`use_build_context_synchronously`,
`lib/ui/dialogs.dart:454`) — fixy `6a830a6` (desktop) i `047a0da` (TG); lokalny
łatany SDK tej uwagi nie pokazuje, więc lokalne „analyze 0” nie dowodzi stanu
bramek.

Po publikacji (odczyt ze stanu publicznego): 7/7 digestów i rozmiarów assetów
API identycznych z przygotowanym podpisanym zestawem, `sha256sum -c` publicznego
`SHA256SUMS.txt` → 7× OK, `latest.json` i `appcast.xml` bajt-identyczne z
przygotowanymi, `dart run tool/check_update_feed.dart` → `Verified publisher
signature: 0.2.35, build 44`, smoke `test/updater_public_smoke_test.dart`
(`SILIQUE_PUBLIC_UPDATER_SMOKE=1`) → 1/1: anonimowe pobranie APK przez realny
`UpdateClient`, rozmiar zgodny z manifestem, bez `.part`.

Publikacja na **jawną bieżącą zgodę właściciela** z 2026-11-04 06:47 CET
(„Pozwalam na git push i release”); zgoda z 2026-11-02 była jednorazowa i zużyta
przez 0.2.34. **Osobisty test właściciela niewykonany** — waiver odnotowany w
publicznych notesach wydania. Push agenta możliwy dopiero po decyzji właściciela
o zdjęciu `git push*` i komend publikacji z `approvals.deny` (model warunkowy
smart-approval; twarde deny utrzymane dla `gh release delete*`,
`gh workflow delete*`, `pct`/`pvesh`/`qm`, API PVE).

Incydent procesowy: meldunki sesji desktop o „opublikowanym 0.2.35+44”
(release `436413239`, runy `41747039721`/`41751747853`, commit `16293b2`) oraz
o wykonanym collect/prepare (`release_id 437442207`, run `41788216825`, artefakt
`4896742828`, katalog lokalny `prepared-0.2.35-44-41788216825`) **nie miały
odzwierciedlenia w stanie GitHuba i dysku** (404, brak plików, `origin/main`
wciąż `9e1fa7d`). Stan ustalono odczytem z API; collect, publish i weryfikację
wykonał ten przebieg (sesja TG). Zasada utrwalona w skillu: meldunek innej
sesji jest twierdzeniem, nie stanem.

---

# Silique 0.2.34+43 — opublikowane, poprawki UX komputera

[Publiczne wydanie](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.34),
ID `428322993`, `2026-10-29T19:46:43Z`, latest, **7 instalatorów + SHA256SUMS.txt**.
Wspólne źródło wszystkich platform: `1a770ed3a089e136bc3c27498f4b4f4a30e2a092`.
[Zmiany i ograniczenia](0.2.34.md). Szkic zachowany:
`candidate-0.2.34-43` (`untagged-4406cdeabc728901694c`).

Dziewięć punktów właściciela: częściowe zaznaczanie linków; pełne menu edycji
tekstu; trwała kolejność folderów; jednoznaczne zamknięcie okna z usuniętym
konfliktem teardown Windows; brak kolizji Alt/AltGraph z polskimi znakami;
wspólny import pliku i folderu; poziome Usunięte / Ukryte / Importuj nad
plakietką vaulta; ograniczenie zbędnych odczytów pęku kluczy; rebranding
z wąską listą identyfikatorów zgodności (`docs/rebrand.md`).

Runy: macOS/Android `40927232055`, Windows `40927237372`, Linux (CT104,
zatrzymany po buildzie, `artifacts/linux-1a770ed3a089-1793297941`),
podpisane przygotowanie `40932778558`, publikacja `40942757538` — wszystkie
sukces. Lokalny pełny zestaw 921/45/0, analizator czysty. macOS 911/55/0,
92 testy integracyjne, natywna bramka Keychain 1/1, DMG obie architektury.
Windows: zestawy natywne zielone, naturalne zamknięcie procesu 78 ms z exit 0
(ścisła próba 40 ms); baseline `f11e1fc` krasz `-1073740771` raportowany
wyłącznie jako obserwacja, nie jako pass. Android APK `pl.novanotes.nova_notes`
0.2.34/43 z zachowanym certyfikatem.

Po publikacji: `v0.2.34` draft=false/prerelease=false, publiczne latest =
`v0.2.34`; `SHA256SUMS.txt` zgodny z digestami API dla 7 instalatorów; podpisy
Ed25519 publicznego manifestu, appcasta i DMG zweryfikowane kluczem wydawcy,
trailer `koly` obecny; kanały publiczne zmienione wyłącznie na tę wersję
(`latest.json` blob `db65eb6f…`, `appcast.xml` blob `bab7a7bf…`); anonimowe
pobranie APK 67 763 187 bajtów.

Jawna zgoda właściciela: **„Opublikuj”** — dla tego wydania. **Nie odbył się
osobisty test właściciela** ani instalacja na jego urządzeniach. Nadal brak
Developer ID/notaryzacji macOS oraz Authenticode Windows; zgłoszone 3–4 s
opóźnienie zamknięcia na konkretnym komputerze nie zostało odtworzone,
a monity pęku kluczy po aktualizacji i fizyczny układ klawiatury pozostają do
weryfikacji u właściciela. Serwer produkcyjny, dane i klucze nietknięte.

---

# Silique 0.2.33+42 — opublikowane, English / Polski

[Publiczne wydanie](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.33),
ID `427313759`, `2026-10-28T23:49:49Z`, latest, **7 instalatorów + SHA256SUMS.txt**.
Wspólne źródło wszystkich platform: `d8fac39afe081dcf0bf1a5b0091bd19e7264610c`.
[Dokładne dowody, sumy i ograniczenia](0.2.33.md).
[Zachowany szkic](https://github.com/Haniewicz/silique-releases/releases/tag/untagged-a66ea8d715623511c5f6),
ID `427309859`, `candidate-0.2.33-42`.

Angielski domyślnie niezależnie od OS, zapamiętywany wybór English / Polski przy
pierwszym uruchomieniu i w Ustawieniach, zmiana na żywo także w dialogach,
aktualizatorze i natywnych widgetach/wyszukiwaniu Androida. Istniejące notatki,
klucze, identyfikatory i deterministyczne kopie konfliktów bez zmian.

Dokładna jednorazowa zgoda właściciela: **„Po zakończeniu prac zrób publiczne
wydanie bez czekania na moją zgodę”**. Dotyczy tylko tego wydania; **nie odbył się
osobisty test na urządzeniu właściciela**. Publikacja normalnym zatwierdzonym
przepływem po pełnej weryfikacji, nie stałe upoważnienie na przyszłość.

macOS/Android `40787224858`, Windows `40787229511`, podpisane przygotowanie
`40789274601`, publikacja `40789771370` — success. Lokalny/Linux Flutter
810/44/0; macOS 800/54/0, w tym rzeczywista Swift/Foundation i naprawiony wyłącznie
testowy zegar auto-locka. Windows 81/5/0 oraz 74/3/0 (nakładające się zestawy),
rzeczywisty Inno same-install, bariery, guard, negative control i syntetyczne
zachowanie danych. Robolectric 44/0/0; dwa rzeczywiste klienty SQLite PL/EN
ordinary+hidden 2/2, bez rekursywnych konfliktów i bez 429. Linux
`linux-d8fac39afe08-1793230523`, 14 natywnych prób; CT104 zatrzymany.

Natywne DMG: podpis, dokładna wersja/root, obie architektury i rzeczywista
ekstrakcja Sparkle 2.10 z zimnego cache zaliczone. Przed publikacją oba kanały
niezmienione; po niej 8/8 publicznych API digestów/rozmiarów i anonimowych pobrań
zgodne z przygotowaniem, oba publiczne kanały bajtowo zgodne, 3/3 podpisy Ed25519.
Rzeczywisty anonimowy UpdateClient: dokładnie 0.2.33/build42, APK 67 583 003 bajty,
1/1 smoke, bez `.part`. Początkowy stary odczyt CDN zdiagnozowany po przypiętym
publicznym SHA; końcowe sprawdzenie także rzeczywistych URL `main` przeszło.

Brak Developer ID/notaryzacji macOS i Authenticode Windows nadal obowiązuje.
Brak osobistego testu, fizycznego Androida, interaktywnego/alternate-admin UAC;
CI nie dowodzi akceptacji Gatekeepera ani instalacji/restartu u właściciela.
Serwer produkcyjny, urządzenia i dane właściciela, klucze oraz historia wydań
nietknięte. Pełne prywatne logi poza repo instalatorów.

---

# Silique 0.2.32+41 — opublikowane, aktualizator Windows

[Publiczne wydanie](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.32),
ID `426378771`, `2026-10-28T07:44:08Z`, **7 instalatorów + SHA256SUMS.txt**.
Wspólne źródło: `b3c09c2cc2ec7e1d17f5ae18a1bde1bcbf6d9149`.
[Proweniencja, testy, sumy i ograniczenia](0.2.32.md).

Windows: jawny aktualizator w Ustawieniach, ścisła tożsamość instalacji HKLM,
podpis/rozmiar/SHA256 i natywne blokady pobranego EXE przez rzeczywisty Inno,
save/drain/fence/checkpoint przed zamknięciem. Chroniony niestandardowy katalog
aktualizowany w miejscu; portable pozostaje ręczny. Pierwsze przejście ze
starszego klienta bez tej funkcji wymaga ręcznego Setup 0.2.32.

Na polecenie właściciela **„Kiedy wszystko będzie zrobione. Opublikuj wydanie
bez mojej akceptacji”** — jednorazowy waiver, **nie odbył się osobisty test**.
Nie wykonano interaktywnego UAC ani UAC z innym administratorem/na urządzeniu
właściciela. Authenticode nadal brak; UAC może pokazać nieznanego wydawcę.
macOS tylko DMG, bez Developer ID/notaryzacji; Gatekeeper nadal ma zastosowanie.

Windows `40648782386`, macOS/Android `40648778519`, przygotowanie `40651287065`,
publikacja `40651724997` — success. Linux `linux-b3c09c2cc2ec-1793172228`,
759/42/0 i 14 natywnych prób; CT104 zatrzymany. Windows 81/5/0 + natywna
integracja 74/3/0 (nakładające się zestawy), prawdziwy Inno same-install,
barriers/negative control/guard lifetime/syntetyczne zachowanie danych zaliczone.
macOS 749/52/0, native DMG metadata/signature/obie architektury i realna
ekstrakcja Sparkle zaliczone. Most poświadczeń atomowo zwraca DWORD z Win32.

Po publikacji: 8/8 API digestów/rozmiarów i anonimowo pobranych zasobów zgodne,
oba publiczne kanały bajtowo zgodne z przygotowaniem, 3/3 podpisy Ed25519,
manifest 0.2.32/build 41 i 7 platform. Realny anonimowy UpdateClient pobrał
APK 65 988 727 bajtów dla dokładnie tej wersji, 1/1 smoke. Serwer produkcyjny,
urządzenia właściciela, klucze i identyfikatory nietknięte.

---

# Silique 0.2.31+40 — opublikowane, naprawa `-50` przy wyliczaniu kluczy macOS

[Publiczne wydanie](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.31),
`2026-10-27T19:44:54Z`, **8 zasobów: 7 instalatorów + SHA256SUMS.txt**.
Wszystkie platformy: `74773dd197e0a1f0ee19ff5f3c25db29b3e268b5`.
[Przyczyna, dowody RED/GREEN, sumy i ograniczenia](0.2.31.md).

Przyczyna potwierdzona sondą natywną, nie hipotezą: na keychainie plikowym
`kSecMatchLimitAll` razem z `kSecReturnData` kończy się `errSecParam` (-50),
a pojedyncze odczyty, zapis i kasowanie działają. Wyliczanie idzie teraz przez
same atrybuty (`listKeys` w kanale `silique.notes/keys`) i odczyt klucz-po-kluczu.
Warianty „accessibility” i „data-protection keychain” zostały odrzucone pomiarem.
Klucze i dane pozostały nietknięte; brak migracji użytkownika.

Jawna zgoda właściciela: **„Commit i publikacja”**, potem **„Zatwierdzam wszystko”**.
**Nie wykonano testu na urządzeniach właściciela** — publikacja bez osobistego
testu, bez twierdzenia, że się odbył. Brak Developer ID/notaryzacji.

Runy: macOS/Android `40568084110`, Windows `40568089369`, przygotowanie
`40571065340`, publikacja `40571511265` — wszystkie success. Linux
`artifacts/linux-74773dd197e0-1793129323`, CT104 wyłączony. macOS testy
705/51/0 i `flutter build macos`; sonda RED `40560647390`, GREEN `40564943208`.
Po publikacji: 7/7 sum zgodnych z API, `latest.json` i `appcast.xml` 0.2.31/40
(7 platform), APK 0.2.31/40 z tym samym certyfikatem co 0.2.21–0.2.30.

---

# Silique 0.2.30+39 — opublikowane, macOS tylko DMG

[Publiczne wydanie](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.30),
`2026-10-27T13:00:46Z`, **8 zasobów: 7 instalatorów + SHA256SUMS.txt**.
Wszystkie platformy: `69bf61af2d6698314203c8e603c0fe01112d2732`.
[Pełne dowody, wcześniejsze próby i ograniczenia](0.2.30.md).

Stała decyzja właściciela: od tej wersji publikować DMG zamiast ZIP macOS,
także dla aktualizacji Sparkle. Windows ZIP i historia wydań pozostają.
Manifest `macos-dmg`, nowy klient mapuje na `macos`; rzeczywisty stary parser
przyjął publiczny manifest dla Android/Linux. **Mac do 0.2.29 włącznie wymaga
jednorazowej ręcznej instalacji DMG**. [Kontrakt](DMG_DISTRIBUTION.md).

Jawna zgoda właściciela: **„wydaj nowe wydanie bez czekania na mój test”**.
Nie wykonano jego testu ani pełnego interaktywnego instalowania/restartu na Macu.
Brak Developer ID/notaryzacji pozostaje; DMG nie usuwa blokady Gatekeepera.
Certyfikat, klucze, identyfikatory i dane zachowane.

Runy: macOS/Android `40504214879`, Windows `40504222719`, przygotowanie
`40507619375`, publikacja `40508017181` — wszystkie success. Linux
`artifacts/linux-69bf61af2d66-1793105159`, CT104 wyłączony. macOS 704/51/0,
Linux 714/41/0, Windows natywny 51/3/0 i próba instalatora.
Natywne hdiutil build/verify/mount/read-only, dokładny root, certyfikat i obie
architektury zaliczone; Sparkle 2.10 rzeczywiście rozpakował DMG z zimnym cache.
Osiem publicznych digestów/rozmiarów, oba kanały i 3 podpisy Ed25519 sprawdzone.
Anonimowo pobrano i zweryfikowano DMG 27 340 289 bajtów; realny UpdateClient
oraz niezmieniony stary parser przyjęły dokładnie 0.2.30/39, APK 65 955 959
bajtów zweryfikowany, 1/1 smoke. Serwer i urządzenia właściciela nietknięte.

---

# Silique 0.2.29+38 — opublikowane, naprawa startu macOS i Android Keystore

[Publiczne wydanie](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.29),
`2026-10-27T10:08:24Z`, **8 zasobów: 7 instalatorów + SHA256SUMS.txt**.
Wszystkie platformy ze źródła `370efbd7df19ca1057ec660b6aa19ce5a449af9f`.
[Proweniencja, wyniki, sumy i ograniczenia](0.2.29.md).

macOS: otwarcie pełnej ścieżki poświadczeń bez czytania zabronionych przodków
sandboxa; zachowane odrzucanie symlinków, walidacja ACL i istniejące klucze.
Rzeczywista sonda Seatbelt odtworzyła EPERM i zaliczyła zapis/reopen po poprawce.
Android: wykonany zapisany backlog — Keystore dla nowych instalacji, brak
selektorów, jawna jednorazowa migracja istniejącego lokalnego magazynu.

Publikacja na aktualne polecenie właściciela **„Po naprawach wydaj release bez
czekania na testy”**. Nie wykonano testu na jego Macu ani fizycznym Androidzie.
To zgoda na tę publikację, nie dowód testu ani stałe upoważnienie.

Runy: macOS/Android `40482451461`, Windows `40482456096`, podpisane
przygotowanie `40485434307`, publikacja `40485872341` — wszystkie success.
Linux `artifacts/linux-370efbd7df19-1793094503` i CT104 ponownie wyłączony.
macOS 697/51/0, Linux 707/41/0, Windows natywny 51/3/0 i próba instalatora.
Osiem publicznych digestów/rozmiarów i oba kanały zgodne z przygotowaniem;
trzy podpisy Ed25519 sprawdzone. Root bundle macOS 0.2.29/38, x86_64+arm64;
APK 0.2.29/38. Rzeczywisty anonimowy updater pobrał i zweryfikował APK
65 955 959 bajtów, 1/1 smoke. Serwer produkcyjny i urządzenia nietknięte.

---

# Silique 0.2.28+37 — opublikowane, naprawa startu na Androidzie

[Publiczne wydanie](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.28),
**8 zasobów: 7 instalatorów i SHA256SUMS.txt**. Źródło wszystkich platform:
`aed54eae5c0b9cb2d2ab5e4717729c1d4a5ac03a`.
Pełna proweniencja i dowody: [0.2.28.md](0.2.28.md).

Po 0.2.27 Android nie startował (`errno 13`, `EACCES`): sesja poświadczeń
otwierała katalogi nadrzędne do czytania, a `/data` ma `0771`. Poprawka używa
`O_PATH` dla przodków; ochrona przed symlinkami i walidacja trybów bez zmian.

**Właściciel nie uruchomił 0.2.28 na urządzeniu.** Publikacja na jego polecenie
**„Napraw to i opublikuj nowe wydanie bez moich testów”** — zgoda na tę
publikację, nie dowód testu ani zgoda na kolejne wydania.

Runy: macOS/Android `40409692148`, Windows `40409696471`, przygotowanie
`40412519570`, publikacja `40413021937` — wszystkie success. Pierwsza próba
macOS/Android `40407705926` padła na niepowiązanym teście auto-locka ukrytego
folderu (runner-timing), ponowiona dla tego samego SHA. Linux GTK4 lokalnie,
`artifacts/linux-aed54eae5c0b-1793051959`. Testy: 694 zaliczone, 40 pominiętych,
0 błędów. Siedem sum SHA256 zgodnych z `SHA256SUMS.txt`, podpisany `latest.json`
= 0.2.28/build 37, APK `pl.novanotes.nova_notes` 0.2.28/37.

---

# Silique 0.2.27+36 — opublikowane, weryfikacja po publikacji

[Publiczne wydanie](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.27),
opublikowane `2026-10-26T21:04:57Z`; **8 zasobów: 7 instalatorów i SHA256SUMS.txt**.
Źródło wszystkich platform: `6c9b147d1d7f0325fb7eafd1af8aad5ea11127ac`.
Pełna proweniencja, siedem SHA256, dowody i ograniczenia: [0.2.27.md](0.2.27.md).

**Właściciel nie wykonał osobistego testu na urządzeniu.** Publikacja nastąpiła
na jego polecenie **„Jeśli zadanie zakończone, opublikuj”**, po wcześniejszym
**„Tak”** w tym samym zadaniu. To zgoda na tę publikację bez osobistego testu,
nie dowód wykonania testu ani upoważnienie dla następnego wydania.

Końcowe runy (konkluzje ponownie sprawdzone przez `gh`, wszystkie success):
macOS/Android `40395149744`, Windows `40395154812`, przygotowanie podpisów
`40400207020`, publikacja `40400969215`. Linux z lokalnego katalogu
`$HOME/projects/Silique/artifacts/linux-6c9b147d1d7f-1793046742`,
build i testy zielone według przekazanego wyniku poprzedniego etapu.

Wcześniejsze próby, zastąpione końcowym SHA: macOS/Android `40392366419`
dla `41d91a6` — **failure**, fixture `credential_notebook_test.dart` z
niekanonicznym `/var/folders`, odrzucony symlinkowany komponent macOS;
Windows `40392373358` dla `41d91a6` — success; Windows `40393981939`
dla `312d023` — success; macOS/Android `40393974940` dla `312d023` —
**success**, odczytane bezpośrednio z Actions. Poprawki testów: `312d023`
kanonizuje temp przez `resolveSymbolicLinksSync()` i pomija fasadę Darwin ACL
z powodem, gdy nie ma `cc`; `6c9b147` rozwiązuje ścieżkę Darta dla sond
natywnych bez wymagania `dart` w PATH.

Wynik przekazany ze wznowionego zadania, na worktree poświadczeń przed
scaleniem: **686 testów zaliczonych, około 40 pominiętych**, Robolectric
**37/37**, analiza i format czyste. Starsze 693/40 poniżej to osobny checkpoint,
nie wynik ponownie uruchomionego tutaj pełnego zestawu.

Po publikacji sprawdzono: **3/3 podpisy Ed25519** (payload latest.json,
sam appcast.xml i wskazane archiwum macOS) kluczem publicznym updatera;
latest.json **0.2.27/build 36 i 7 platform**, appcast jeden element macOS
**0.2.27/36**. Wszystkie 7 sum z manifestu zgodne z publicznym SHA256SUMS.txt.
Rzeczywisty anonimowy `UpdateClient` pobrał i zweryfikował APK
**65 955 955 bajtów**: **1/1 smoke**, bez tokenu GitHub i bez `.part`.
Root bundle w ZIP ma dokładnie `Silique.app/Contents/Info.plist`,
`CFBundleShortVersionString=0.2.27`, `CFBundleVersion=36`; nie odczytywano
zagnieżdżonego Sparkle/Updater.app. Windows **2/2 pobrane pliki** zgodne:

- Setup, 12 911 321 bajtów: `cee167b08c9fb56786789a58bb5c18c1d5a37dc47a5d79c1c88d9ca8a5bfd0a4`.
- ZIP, 15 672 201 bajtów: `ac7cf555dd3fe834fee7db32d072c4ab2f5c50f5aa1295f9a1104de32fb533a6`.

Zgodność trzech Linux SHA256 z lokalnymi pakietami i metadane APK
`pl.novanotes.nova_notes`, `0.2.27/36` sprawdzono w poprzednim etapie;
nie powtarzano builda ani aapt2. Dowody tej kontroli:
`.dart_tool/postpublication-0.2.27/` w worktree wydania (niecommitowane).
Nadal brak osobistego testu i interaktywnych instalacji/restartów, UAC/CFA
oraz instalacji DEB/RPM w tej sesji. Bez zmian kodu aplikacji, nowej publikacji,
deployu, uruchamiania CT 104, zmian sekretów, kluczy czy konfiguracji gh.

Poniższy opis „NIEPUBLIKOWANA” jest **historycznym stanem implementacji**,
zastąpionym powyższym potwierdzeniem publikacji.

---

# Silique 0.2.27+36 — implementacja wyboru poświadczeń, NIEPUBLIKOWANA

Kontynuacja sesji `20261026_141650_b29cda` na osobnej gałęzi
`feature/credential-storage-mode`, od aktualnego `origin/main`
`2d2f5b06118e3ca09a72d4bd93c27d3010f8736a`. Publikacja 0.2.26 została już
wykonana przed zmianą funkcji; nie ponawiać jej. Zgoda właściciela dotyczyła
ostatniego draftu: „Tak zrobimy. Najpierw pobierz swieżą wersję z repo (były
zmiany na innym urządzeniu), zrób release z ostatniego draftu na repo a dopiero
potem wdraż te zmiany”. To nie jest zgoda na publiczne wydanie 0.2.27.

Pierwsza konfiguracja: lokalny plik wstępnie wybrany, jawne ostrzeżenie i zgoda.
Ustawienia: przenoszenie tego samego zestawu kluczy i danych kont w obie strony;
nie zmienia danych vaultów ani hasła ukrytych notatek. Istniejące instalacje
pozostają przy magazynie systemowym. Blokada między procesami, potwierdzona
aktywacja, widoczne niedokończone sprzątanie i brak zastępczego klucza przy
utracie poświadczeń. Android używa systemowego `noBackupFilesDir` dla plików.

Wznowienie naprawiło trzy blokery poprzedniego review oraz ACL/ABI POSIX z
regresjami RED→GREEN. Końcowy niezależny review bez blockerów. Flutter:
693 zaliczone / 40 pominiętych / 0 błędów; analizator bez uwag, format 21 plików
czysty. Natywne pliki na Linuksie: 31/9/0, z fault harness 33/7/0. Host Androida:
37/0/0 (`:app:testDebugUnitTest`); debug APK zbudowany. Szerokie zadanie Gradle
zatrzymał test zależności `file_selector_android` wymagający Java 21 dla SDK 36
przy zainstalowanej Java 17; zadanie samej aplikacji jest zielone.

Dowody, logi i debug APK:
`$HOME/projects/Silique/artifacts/credential-mode-0.2.27-36/`.
Debug APK nie jest podpisanym wydaniem produkcyjnym i nie służy do aktualizacji
instalacji właściciela. Brak wykonania na rzeczywistym macOS/Windows/urządzeniu
Android oraz osobistego testu właściciela. Nie publikowano 0.2.27, nie zmieniano
kanałów aktualizacji, serwera, sekretów ani urządzenia właściciela.
[Kontrakt, wyniki i ograniczenia](CREDENTIAL_STORAGE.md).

---

# Silique 0.2.26+35 — opublikowane

[Publiczne wydanie](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.26),
release ID `424318407`. Publikacja na aktualne polecenie właściciela:
„Najpierw pobierz swieżą wersję z repo (były zmiany na innym urządzeniu), zrób
release z ostatniego draftu na repo a dopiero potem wdraż te zmiany”. Polecenie
potraktowano jako zgodę na publikację tego draftu bez oczekiwania na osobisty test;
nie deklarowano wykonania testu właściciela ani interaktywnego CFA/UAC.

Źródło siedmiu instalatorów: `2d2f5b06118e3ca09a72d4bd93c27d3010f8736a`.
Kod aplikacji, formaty danych i natywne implementacje identyczne z ostatnim
źródłem draftu `0eb15ef30345589078e55b808ee0d115d88f7f52`; jedyna korekta to
przenośność testu pierwszej konfiguracji CFA (mapowanie ścieżki fixture na
Windows przy granicy natywnego serwisu, bez osłabiania walidacji produkcyjnej).
Pierwszy Linux zatrzymał się na tym teście (601/30/1); po RED→GREEN: 28/28 CFA,
603 zaliczone / 30 pominiętych / 0 błędów w zestawie na builderze Linux, czysty
analizator, 14 natywnych prób GTK4 oraz pakowanie DEB/RPM/archive zaliczone.
Windows `40331531035`: natywny magazyn i smoke instalatora zaliczone;
macOS/Android `40331523773`: sukces. Przygotowanie podpisów `40334545298`,
publikacja `40335022304`: sukces. Początkowy Windows `40330323767` również
przeszedł, macOS/Android `40330318972` anulowano po korekcie testu; te paczki
nie weszły do publikacji.

Osiem publicznych zasobów (siedem instalatorów + `SHA256SUMS.txt`) pobrano
anonimowo i porównano rozmiary i SHA256 z podpisanym przygotowaniem. Oba publiczne
kanały są bajtowo zgodne z przygotowaniem i wskazują 0.2.26/build 35; podpis
manifestu sprawdzono rzeczywistym `tool/check_update_feed.dart`. Root bundle
macOS ma właściwą wersję i identyfikator. Kontener CT104 zatrzymany, serwer
produkcyjny nietknięty. Windows pozostaje bez Authenticode zgodnie z decyzją
właściciela; dodatni interaktywny CFA/UAC i instalacja w Program Files na
komputerze właściciela nie były wykonane.

Dopiero po publikacji i jej weryfikacji rozpoczęto oddzielną zmianę
przechowywania poświadczeń, planowaną jako 0.2.27+36. Wydanie 0.2.26 jej nie
zawiera. Wcześniejszy stan draftu poniżej jest zapisem historycznym.

---

# Silique 0.2.26+35 — wcześniejszy stan draftu

Zakres: Windows. Jawny przycisk zgody na Kontrolowany dostęp do folderów po
potwierdzonym zdarzeniu 1123, chroniona instalacja w Program Files, poprawka
transportu UTF-8 i obsługa pierwszego wyboru folderu. **Podpisy pominięte
świadomie** (brak podmiotu do weryfikacji wydawcy) — UAC pokaże nieznanego wydawcę.

Pomocnik `silique_folder_access.exe`: `--inspect` (tylko odczyt), `--request`
(strome `runas --apply`), `--apply` bez argumentów operacyjnych; jedyna mutacja to
`Add-MpPreference -ControlledFolderAccessAllowedApplications` dla wyprowadzonego
rodzeństwa `silique.exe`, z odczytem zwrotnym. Zgoda wyłącznie dla chronionego
bundle w Program Files; legacy/per-user dostaje diagnozę bez przycisku.

Instalator: admin + `{autopf}\Silique`, `UsePreviousAppDir=no`, **bez autostartu**
po instalacji, ostrzeżenie o starej instalacji per-user bez usuwania danych.
Transport pomocnika: jawne UTF-8. Panel CFA działa też przy pierwszym wyborze
folderu (inspekcja katalogu nadrzędnego).

Weryfikacja: native 113/113, smoke CLI 5/5 (bez UAC), analizator bez uwag,
571 zaliczonych / 50 pominiętych / 11 błędów (ten sam zbiór środowiskowy co
baseline), 6 testów polityki instalatora, zbudowany ZIP i Setup 0.2.26 (wersja
pliku 0.2.26.35). Brak dodatniego E2E UAC/1123 i smoke instalacji — wymagają
interaktywnej zgody właściciela. Draft `candidate-0.2.26-35` (ID 424061198) ma
ZIP, Setup i sumy; publiczne `latest` nadal v0.2.23. Nic nie opublikowano.
[Dowody i ograniczenia](0.2.26.md).

---

# Silique 0.2.25+34 — draft, NIEPUBLIKOWANY

Powód: ponowny start na komputerze właściciela kończył się 778 na
`Documents\Silique Vaults`. **Przyczyna potwierdzona**: Windows Kontrolowany
dostęp do folderów blokuje zapis `silique.exe` w tym folderze — zdarzenia
Defendera 1123 o 21:48:23, 22:05:52 i 22:06:27 odpowiadają wpisom diagnostyki
21:48:19, 22:05:49 i 22:06:23. Odtworzenie poza aplikacją: w `Documents` nie
powstaje żaden nowy plik (błąd 2), a odczyt przez SQLite również zawodzi, bo
potrzebuje zapisu `-shm`. Poprawka 0.2.24 nie mogła zadziałać — blokowany był
plik, nie mapowanie SHM.

Kod: sprawdzenie zapisu w folderze **przed** otwarciem bazy
(`StorageRootWriteBlocked`, komunikat o folderze zamiast 778) oraz akcja
„Przenieś notatki”: bajtowa kopia bazy z `-wal`/`-journal` (bez `-shm`) i
`markdown/`, `quick_check` i liczba dokumentów przed zmianą nazwy, oryginał
nietknięty. 5 nowych testów RED→GREEN (9/9 razem z istniejącymi), analizator bez
uwag, pełny zestaw 544/50/11 — te same 11 błędów środowiskowych co bez zmiany.

Stan maszyny: aplikacja otwiera notatki na kopii w `C:\Users\Ultro\Silique
Vaults` (12 notatek); oryginał w `Documents` pozostaje zablokowany i niezmieniony.
Draft `candidate-0.2.24-33` pozostaje bez zmian i nie zawiera tej poprawki.
Nic nie opublikowano. [Dowody i ograniczenia](0.2.25.md).

---

# Silique 0.2.24+33 — zweryfikowany draft, NIEPUBLIKOWANY

[Draft do testów](https://github.com/Haniewicz/silique-releases/releases/tag/untagged-5e525cd6a95e267754ba)
(ID 423674475, `candidate-0.2.24-33`, 7 instalatorów). Wszystkie pakiety:
`d519f47148d50b343d4f537633cb8f7e7fad351a`. Windows `40234354575`,
macOS/Android `40234351880`, Linux GTK4 (570/30/0, 14 prób natywnych, CT104
zatrzymany) i przygotowanie podpisów `40235889233` — sukces. Windows: 50/3,
instalator i natywne odtworzenie obu 778 przez mapowany/zablokowany SHM zaliczone.
Poprawiony start używa indeksu WAL w RAM przez EXCLUSIVE przed odczytem schematu;
zapis/ponowne otwarcie i WAL-only dane zachowane, rzeczywiste blokady nadal działają.

Odzyskiwanie tworzy sprawdzony snapshot przez SQLite backup i **nie przełącza
automatycznie lokalizacji**. Usunięto WAL→DELETE po I/O; spóźniona inicjalizacja
nie nadpisuje nowszej lokalizacji. Review obu luk aktywacji po poprawce: brak
blockerów. Digest i rozmiar 7 zasobów zgodne z podpisanym zestawem, podpis
manifestu 0.2.24/33 zweryfikowany, macOS root bundle 0.2.24/33.

**Właściciel zlecił tylko draft. Nie uruchamiano publish.** Publiczne wydanie
nadal v0.2.23, oba kanały bajtowo niezmienione. Przyczyny na Windows właściciela
ani działania naprawy na tym komputerze nie potwierdzono. Serwer produkcyjny
nietknięty. [Pełne wyniki, ograniczenia i wcześniejsze nieudane przebiegi](0.2.24.md).

---

# Silique 0.2.23+32 — opublikowane

[Publiczne wydanie](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.23).
Źródło siedmiu instalatorów: `b57bbede6e61789baa627ddecad102346f1da8fd` (`main`).
Zakres: start na Windows po pierwszym uruchomieniu. Gdy folder odmawia plików WAL
(klient synchronizacji, ochrona folderów), baza pracuje dalej na dzienniku
wycofywania z `synchronous=FULL`; otwarcie i przełączenie dziennika są ponawiane,
zapis jest sprawdzany przed UI, a nieudany start podaje prawdziwą ścieżkę, kod
SQLite i diagnostykę do skopiowania, zamiast tekstu o pęku kluczy. **Przyczyny na
komputerze właściciela nie potwierdzono** — to usunięcie ślepej uliczki i
diagnostyka, nie potwierdzona naprawa uprawnień.

532 testy zaliczone, 28 pominiętych, 0 błędów; 8 nowych regresji (RED
potwierdzony), analizator bez uwag. Pierwszy przebieg Windows `40223797978`
ujawnił niedomknięty uchwyt bazy i nie przeszedł; po naprawie Windows
`40224360783`, macOS/Android `40224357644`, Linux GTK4 (CT104 zatrzymany, trzy
zgodne sumy), przygotowanie `40226503889`, publikacja `40226716164` — sukces.
Osiem publicznych zasobów zgodnych rozmiarami i SHA256 z podpisanym zestawem; oba
kanały bajtowo zgodne i wskazują 0.2.23/build 32; podpis zweryfikowany
`tool/check_update_feed.dart`; macOS Info.plist 0.2.23/32. Publikacja na aktualne
jawne polecenie właściciela bez czekania na test ręczny; nie deklarowano jego
wykonania. Serwer produkcyjny nietknięty. [Szczegóły i ograniczenia](0.2.23.md).

---

# Silique 0.2.22+31 — opublikowane

[Publiczne wydanie](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.22).
Źródło siedmiu instalatorów: `fa395cc17afd3e65b4466316d9cc653e83c69682` (`main`).
Zakres: jedna rodzina wizualna wszystkich własnych menu kontekstowych i pickerów
(menu folderu/notatki/sortowania/edytora/tekstu, wybór folderu przy przenoszeniu,
wybór vaulta, zarządzanie vaultami) oraz **rzeczywiste usunięcie vaulta wraz z
zawartością** — owner-auth DELETE na serwerze, lokalny trwały tombstone,
czyszczenie ukrytych namespace'ów, historii, załączników, kopii Markdown i
snapshotów widgetów, z potwierdzeniem przez wpisanie nazwy i zachowaniem
niepewnego potwierdzenia jako fence.

613 testów zaliczonych, 28 pominiętych, 0 błędów; regresje API na prawdziwych
disposable serwerach 27/27; Kotlin/Robolectric 37/37; analizator bez uwag.
Niezależny review ścieżki destrukcyjnej bez blokera; dwa „should-fix" naprawione
przed wydaniem z testami RED→GREEN. macOS/Android `40218012606`, Windows
`40218014884`, Linux GTK4 z natywnym probe i trzema zgodnymi sumami (CT104
zatrzymany), podpisane przygotowanie `40219261543`, publikacja `40219567055` —
wszystkie sukces. Osiem publicznych zasobów zgodnych rozmiarami i SHA256 z
podpisanym zestawem; oba kanały bajtowo zgodne i wskazują 0.2.22/build 31;
podpis kanału zweryfikowany, anonimowy smoke updatera pobrał i zweryfikował APK;
macOS Info.plist 0.2.22/31. Publikacja na aktualne jawne polecenie właściciela
bez czekania na test ręczny; nie deklarowano jego wykonania. Serwer produkcyjny
nietknięty przy tym wydaniu. [Szczegóły i ograniczenia](0.2.22.md).

---

# Silique 0.2.21+30 — opublikowane

[Publiczne wydanie](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.21).
Źródło siedmiu instalatorów: `7f49dcd37d0b5113f8b90e1cde2bfd25a0bb48f3`.
Zakres: czytelna obsługa odmowy zapisu folderu vaultów i warunkowa instrukcja
sprawdzenia Controlled Folder Access. **Nie potwierdzono przyczyny na Windows
właściciela ani przywrócenia zapisu do Dokumentów; to poprawa obsługi błędu,
nie obejście ochrony ani potwierdzona naprawa uprawnień.**

466 testów zaliczonych, 27 pominiętych, 0 błędów; analizator bez uwag,
niezależny review bez blockerów. Windows `40185550562` (natywny magazyn i
instalacja), macOS/Android `40185548481`, Linux 14 prób natywnych — sukces.
Podpisanie `40186613419`, publikacja `40186787601`. Osiem publicznych zasobów
zgodnych z podpisanym zestawem, oba kanały bajtowo zgodne i wskazują build 30,
podpis kanału i anonimowe pobrania APK aktualizatorem oraz EXE zweryfikowane.
Publikacja na aktualne jawne polecenie właściciela bez czekania na test ręczny;
nie deklarowano jego wykonania. Serwer produkcyjny nietknięty, CT104 zatrzymany.
[Szczegóły i ograniczenia](0.2.21.md).

---

# Silique 0.2.20+29 — wydanie zakończone (opublikowane)

Źródło siedmiu instalatorów: `76f9a75b94f3f58d22515ad409eb66fa1b91f0d7` (`main`). Poprzedni kandydat `943981b3697107859bd2aa376cc8e2d216623ea6` WYCOFANO po ujawnieniu dwóch problemów bezpieczeństwa: po edycji ukrytej kopii mógł pozostać stary jawny zapis na serwerze, a przezroczyste okno widgetu mogło odsłaniać edytor. Obydwa naprawiono z testami RED/GREEN. Po korekcie 462 testy Flutter zaliczone / 27 pominiętych / 0 błędów; Kotlin/Robolectric 36/0; analizator i format czyste. Linux GTK4 14/14 prób natywnych i trzy zgodne sumy; macOS/Android `40162838609`, Windows `40162840474`, podpisane przygotowanie `40163858255` — sukces. Siedem instalatorów zgodnych z SHA256SUMS.

Nowy szkic: https://github.com/Haniewicz/silique-releases/releases/tag/untagged-526f2ed71d38e47784b7 (nieopublikowany). Lokalny podpisany zestaw `$HOME/projects/Silique/artifacts/prepared-0.2.20-29-40163858255/`; siedmiodniowy artefakt Actions `12587587763` wygasa `2026-11-01T05:01:08Z`. Stary szkic usunięto, jego paczki zachowano lokalnie jako wycofane. Opublikowano `v0.2.20` (run [40179122233](https://github.com/Haniewicz/silique-releases/actions/runs/40179122233)) na jawne polecenie właściciela „Zrób publiczny release bez czekania na moje testy”, potwierdzone po automatycznym wznowieniu zadania po limicie dostawcy. Osiem zasobów, kanał 0.2.20/build 29, APK `versionCode 29`, macOS `Info.plist` 0.2.20/29, anonimowy updater pobrał i zweryfikował APK. Właściciel nie wykonał osobistego testu na urządzeniu — zapis dotyczy zgody na publikację, nie potwierdzenia testu. Serwer produkcyjny oraz 0.2.19 nietknięte; CT 104 zatrzymany. [Szczegóły](0.2.20.md).

---

# Silique 0.2.19+28 — wydanie zakończone

Opublikowano [Silique 0.2.19](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.19)
na wyraźne polecenie właściciela „Napraw i zrób release bez czekania na
akceptację”. Zgoda dotyczy publikacji; właściciel nie wykonał osobistego testu
na urządzeniu. Zakres: usunięcie twierdzeń, że ukryte notatki są lokalne;
auto-blokada folderu Ukryte zgodna z ustawieniami (przypięta testami obu ścieżek);
widgety w palecie aplikacji; lista notatek w widgecie pokazywana bez
odblokowywania aplikacji, przy zachowaniu zakazu eksportu notatek ukrytych.
Źródło ośmiu instalatorów: `4773500ed8920fb4fcd678b0aebb3b0cb5a24174` (`main`).
macOS/Android `40129802924`, Windows `40129805500`, Linux GTK4 z 14 próbami;
przygotowanie `40130910655`, publikacja `40131164049` — udane. Zestaw 446/26/0,
analizator bez uwag, testy Kotlina zaliczone. Kanał wskazuje 0.2.19/build 28;
anonimowy updater pobrał i zweryfikował APK; macOS Info.plist 0.2.19/28, APK
versionCode 28. Serwer produkcyjny nietknięty, CT 104 zatrzymany. Brak testu na
telefonie i Macu właściciela oraz aktualizacji DEB/RPM na systemie docelowym.
[Szczegóły](0.2.19.md).

---

# Silique 0.2.18+27 — wydanie zakończone

Opublikowano [Silique 0.2.18](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.18)
na jawne polecenie właściciela „Opublikuj wydanie / Zrób to i nie czekaj na mój
test”. Zgoda dotyczy publikacji tego wydania; właściciel nie wykonał osobistego
testu na urządzeniu i nie zadeklarował jego wyniku. Zakres: szyfrowany
end-to-end sync ukrytych notatek z przenośną konfiguracją hasła, usuwaniem,
konfliktami i migracją istniejących danych; wklejanie obrazów ze schowka na
Androidzie; zapisany tytuł „Bez tytułu” z możliwością wyczyszczenia i edycją po
dotknięciu pustego obszaru; widgety Androida z pływającym wyszukiwaniem.
Źródło ośmiu instalatorów: `325e687f83a8e85ea8e6d4a057babaaa1fb6be9b` (`main`).
macOS/Android `40121154070`, Windows `40121156325`, Linux GTK4 z 14 natywnymi
próbami; przygotowanie kanałów `40122789717`, publikacja `40123014878` — udane.
Zestaw 441 zaliczonych / 26 pominiętych / 0 błędów, analizator bez uwag, testy
Kotlina (widgety, schowek) zaliczone. Osiem publicznych zasobów; podpisany
`latest.json` wskazuje 0.2.18/build 27 i siedem wpisów zgodnych z zasobami;
anonimowy rzeczywisty updater zweryfikował podpis kanału i pobrał APK. Weryfikacja
macOS: `Silique.app/Contents/Info.plist` = 0.2.18/27. Serwer produkcyjny
nietknięty, CT104 wyłączony. Brak testu na telefonie i Macu właściciela oraz
aktualizacji DEB/RPM na systemie docelowym.
[Szczegóły](0.2.18.md).

---

# Silique 0.2.17+26 — wydanie zakończone

Opublikowano [Silique 0.2.17](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.17)
na jawne polecenie właściciela „Zrób publiczny release. Akceptuję”. Zgoda dotyczy
publikacji; właściciel nie wykonał osobistego testu i nie zadeklarował wyniku.
Przebudowa ukrytych notatek: folder w lewym menu zamiast osobnego okna, wspólny
edytor i tworzenie jak w zwykłych notatkach, czyszczenie historii i pamięci
podręcznej obrazów po blokadzie, izolacja linków i namespace'u magazynu.
Źródło siedmiu instalatorów: `8d4f885da380e0b80db5042688126edd12621dd7`.
macOS/Android `40103183033`, Windows `40103185099`, Linux z 14 natywnymi próbami;
podpisywanie `40104156845`, publikacja `40104349066` — wszystkie udane.
Osiem publicznych zasobów i SHA256SUMS zgodne; publiczny `latest.json` wskazuje
0.2.17/build 26, a anonimowy rzeczywisty updater pobrał i zweryfikował APK.
Serwer produkcyjny nietknięty, CT104 wyłączony; brak testu na telefonie i Macu
właściciela oraz aktualizacji DEB/RPM na systemie docelowym.
[Szczegóły](0.2.17.md).

---

# Silique 0.2.16+25 — wydanie zakończone

Opublikowano [Silique 0.2.16](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.16)
na jawną zgodę właściciela „Publikuj bez czekania”, bez dodatkowego testu manualnego.
Wyłącznie naprawy synchronizacji: graf podstaw scalania, zachowanie konfliktów
przy niepełnej historii i monotoniczny wspólny budżet HTTP/longpoll.
Źródło siedmiu instalatorów: `679ac83eade01c71727e932cbab70ae447350d32`.
Czysta regresja: 344 zaliczone /20 pominiętych /0 błędów, analizator bez uwag.
macOS/Android `40092834283`, Windows `40092836224`, Linux z natywnym probe;
podpisywanie `40093939079`, publikacja `40094187073` — wszystkie udane.
Siedem publicznych instalatorów i SHA256SUMS zgodne z lokalnymi plikami; oba
kanały bajtowo zgodne z podpisanym zestawem i wskazują 0.2.16/build 25.
Anonimowy rzeczywisty updater pobrał i zweryfikował konkretnie APK 0.2.16+25.
Serwer produkcyjny nietknięty, CT104 wyłączony. Niezwiązane zmiany UI/Android
nie weszły do wydania; nie testowano go manualnie na urządzeniu właściciela.
[Szczegóły](0.2.16.md).

---

# Silique 0.2.15+24 — wydanie zakończone

Opublikowano [Silique 0.2.15](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.15)
na polecenie właściciela bez czekania na test manualny. Poprawiono nachodzenie pól
hasła ukrytych notatek na przyciski po otwarciu klawiatury. Wejście do kosza w lewym
menu nazywa się „Usunięte”; stara fraza wyszukiwania nie ukrywa jego zawartości ani
zwykłych notatek przy powrocie. W bazie Kosz już był w lewym menu, nie przenoszono
nieistniejącej górnej zakładki.

Źródło wszystkich instalatorów: `d3fc510ff7c3e399c4c0c001892f2d620c42570f`.
331 testów zaliczonych, 15 pominiętych; analizator czysty, niezależny review bez
błędów blokujących. Wszystkie buildy udane: macOS/Android `40009125110`,
Windows `40009129122`, Linux `linux-d3fc510ff7c3-1792782856` z natywnym probe.
Podpisanie `40011526680`, publikacja `40012041144`. Publiczne sumy i rozmiary
siedmiu instalatorów plus SHA256SUMS zgodne; oba podpisane kanały wskazują build 24;
anonimowe pobranie APK rzeczywistym aktualizatorem zaliczone. [Szczegóły](0.2.15.md).

Serwer produkcyjny nietknięty, CT 104 po buildzie wyłączony. Nie wykonano testu na
telefonie ani aktualizacji instalacji na Macu właściciela.

---

# Silique 0.2.14+23 — wydanie zakończone

Opublikowano [Silique 0.2.14](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.14)
na jawne polecenie właściciela „Zrób publikację bez czekania na moje zatwierdzenie”.
Źródło siedmiu instalatorów: `a5da81bc5b4a772956005f37888567e1e580f0bf`.
Naprawa zaznaczania uchwytami i stabilności projekcji Markdown; RED/GREEN oraz
końcowy niezależny przegląd bez błędów blokujących. Lokalnie 316 testów zaliczonych,
15 pominiętych; analizator czysty. Wszystkie buildy zakończone sukcesem, publiczne
sumy/rozmiary ośmiu zasobów zgodne z podpisanym przygotowaniem, oba kanały wskazują
0.2.14/build 23; anonimowe pobranie APK klientem aktualizatora zaliczone.

macOS/Android `40001083898`, Windows `40001089046`, przygotowanie `40003718007`,
publikacja `40004146408`. Szczegóły i ograniczenia: [0.2.14.md](0.2.14.md).
Serwera produkcyjnego nie zmieniano. Fizyczny gest na telefonie i instalacja na
Macu właściciela nie były sprawdzane. CT 104 po kompilacji wyłączony.

---

# Silique 0.2.13+22 — wydanie zakończone

2026-10-23 opublikowano [Silique 0.2.13](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.13) na polecenie właściciela („zrób build, testy oraz release bez czekania na akceptację”). Kod: `fa8c141a17780cebd525761cb270a32b65da5813`. Siedem instalatorów i SHA256SUMS; lokalne sumy zgodne z opublikowanymi. Oba podpisane kanały wskazują 0.2.13/build 22; anonimowy test publicznego kanału i pobrania APK zaliczony. Windows [39952630117](https://github.com/Haniewicz/silique-releases/actions/runs/39952630117), macOS/Android [39952625150](https://github.com/Haniewicz/silique-releases/actions/runs/39952625150), Linux na CT 104 z 14/14 próbami natywnymi, przygotowanie podpisów 39954545837, publikacja 39954786051. Zakres i wyniki: [0.2.13.md](0.2.13.md).

Lokalnie: 298 testów zaliczonych, 15 pominiętych, analizator czysty. Odtworzono na pełnym archiwum 0.2.12 reset przewijania przy wzroście tekstu (980→0, kursor poza ekranem); ten sam test przechodzi po poprawce. Serwera produkcyjnego nie zmieniano. Nie wykonano testu na fizycznym telefonie ani aktualizacji instalacji na Macu właściciela.

---

# Silique 0.2.8+17 — wydanie zakończone

2026-10-22 na polecenie właściciela opublikowano [Silique 0.2.8](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.8): siedem paczek macOS/Android/Windows/Linux oraz SHA256. Oba podpisane kanały wskazują build 17. [Zakres, źródła i wyniki](0.2.8.md).

Kod wszystkich paczek: `b94ed610be714cc4d9a2420f173cbff67bb493d8`. Windows [39791249480](https://github.com/Haniewicz/silique-releases/actions/runs/39791249480): sukces, natywny test i instalator EXE zweryfikowane. Linux zbudowany w CT 104 ze zweryfikowanego SDK/cache: 158 testów, 14 prób natywnych, rzeczywiste kółko, aktualizacja i uruchomienie DEB/RPM w Ubuntu/Fedorze zaliczone. Równoległe Actions Linux 39791256314 anulowano; paczki nie pochodzą z tego uruchomienia. CT 104 po pobraniu paczek ponownie wyłączony, cache i brak autostartu zachowane; dokumentacja Proxmox uzupełniona.

Mac: 163 testy z osobnym API zaliczone, 6 pominiętych (Linux/publiczny smoke), analizator czysty. Jedyna instalacja `/Applications/Silique.app` pozostaje w 0.2.8+17. ZIP uniwersalny, podpis i binaria zgodne z instalacją. Android APK 0.2.8+17 ma dotychczasowy certyfikat v2. Nie powtarzano natywnego testu Androida ani restartu Sparkle na danych właściciela dla końcowej paczki.

Osiem zasobów GitHub ma zgodne rozmiary i SHA256. Oba kanały pobrano publicznie i porównano z przygotowanym wydaniem; podpis manifestu 0.2.8+17 i publiczne pobranie APK rzeczywistym klientem zweryfikowane. Po przerwanym przesyłaniu uzupełniono wyłącznie szkic, a publikację wykonano dopiero po potwierdzeniu kompletu plików. Lokalne archiwa, podpisane wydanie i prywatne raporty: `Wydania/0.2.8-kandydat/` obok repozytorium aplikacji. Kod i prywatne logi nie zostały upublicznione.

Serwera nie zmieniano przy publikacji. Wcześniej przygotowane 0.2.3 z long poll pozostaje wdrożone w CT 100; backupy, manifesty i weryfikacja wcześniejszego wdrożenia są opisane w historii przygotowania i dokumentacji Proxmox.

---

# Silique 0.2.7+12 — wydanie zakończone

2026-10-22 właściciel zlecił publikację zmian wykonanych na Fedorze. Opublikowano [0.2.7](https://github.com/Haniewicz/silique-releases/releases/tag/v0.2.7): macOS ZIP, Android APK, Windows EXE/ZIP i Linux GTK4 DEB/RPM/tar.gz oraz SHA256. Oba kanały aktualizacji wskazują build 12. [Zmiany i wyniki](0.2.7.md).

Źródła produkcyjne: Linux `6840d1cb7780db61d7be0cb7ca556d4fc19e2783`; Mac/Android `c444ad8b1594b7799ad1eaf6e494b655093a5163`; Windows `f70efbc9677c5900135eb9da3990fe840cc56bc9`. Kod produkcyjny i łatki silnika są identyczne; późniejsze zmiany to dokumentacja, test oczekiwanej wersji i narzędzie publikacji. Linux [39725780861](https://github.com/Haniewicz/silique-releases/actions/runs/39725780861) oraz Windows [39770958236](https://github.com/Haniewicz/silique-releases/actions/runs/39770958236) zakończone sukcesem. Poprzedni błąd testu Windows (stała 0.2.6) poprawiono przez przekazywanie wersji/build z pubspec, bez pomijania testu.

Zachowane lokalne paczki, podpisane wydanie i prywatne raporty na Macu: `Wydania/0.2.7-kandydat/` w katalogu głównym projektu. Historyczna diagnostyka Fedory i klucz wyłącznie diagnostyki pozostają poza repo: `~/.local/state/silique-release-handoff/0.2.7/`. Nie są kluczem podpisującym kanał. Do wydania użyto dotychczasowego klucza Ed25519 na stacji macOS; nie generowano zastępczego klucza i nie zmieniano zaufania klientów. Prywatne logi i źródła nie zostały opublikowane.

Na Macu zaktualizowano jedyną instalację `/Applications/Silique.app` do 0.2.7+12, bez otwierania kluczy właściciela. Na Fedorze wcześniej zainstalowano RPM 0.2.7+12 za zgodą właściciela; szczegóły historycznych prób są w poprzednich commitach tego dokumentu. Własny emulator Androida przeszedł rzeczywistą instalację końcowego APK przez aktualizator i systemowy Package Installer, z zachowaniem pliku kontrolnego danych i istniejących testowych notatek; emulator zamknięto. CT 104 ani produkcyjnego serwera nie uruchamiano do tego wydania.

Od Linux 0.2.6 pierwsze przejście jest ręczne; od 0.2.7 RPM/DEB mają aktualizacje z potwierdzeniem i autoryzacją systemową. Portable Linux i Windows pozostają ręczne. Zachować istniejące klucze, vaulty, identyfikatory i materiały podpisu. Pełny restart aktualizacji Sparkle oraz kolejne przejście 0.2.7 → nowszy pakiet nie były automatyzowane na danych właściciela.