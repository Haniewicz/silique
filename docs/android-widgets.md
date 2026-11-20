# Android launcher widgets

The launcher picker offers **Notatki**, **Nowa notatka**, **Wpis do dziennika**
and **Szukaj**. Search is a small native Android floating dialog over the launcher
that opened the widget — a transparent window (only the outside is dimmed) with a
fully opaque card, so the screen behind stays visible while no note text can be
read through it. Typing/filtering/cancelling it never starts MainActivity; a tap
outside closes it. Selecting a result opens the exact ordinary note. New-note and journal actions open the ordinary editor,
leaving and locking the hidden section first. Journal uses the repository's normal
local-date/title behavior.

## What the launcher can show

Every render resolves to exactly one of three states, so a temporary problem never
looks like an empty vault:

- **ready** — the decrypted index is present (possibly with zero notes, which is a
  genuine "no notes" and shows that hint). Rows are separated by a transparent
  list divider plus list padding instead of per-row margins, because a margin on
  a RemoteViews collection row made the first card sit on the clip edge and look
  cut off;
- **locked** — the keyguard is up or the screen is off: the list is hidden and the
  header says the notes are locked; no empty-list hint is drawn;
- **unreadable** — the encrypted snapshot cannot be read right now (Keystore not
  usable yet, transient I/O): the list is hidden and the launcher shows
  "notes are temporarily unavailable" instead of "no notes". The file is kept.

A render that lands locked or unreadable arms a bounded check-back: every 60 s for
the first 30 checks, then every 10 minutes for up to 48 hours, and only the check
that finds the state settled performs the render (the others decrypt nothing and
repaint nothing). The alarm is RTC/non-wakeup, so it fires when the user wakes the
device rather than waking it from sleep. This is what keeps a phone locked
overnight from showing the masked state until the app is next opened. The app also
republishes the snapshot when it returns to the foreground, and a rejected publish
no longer drops the last good encrypted copy.

## Diagnostics

Widget work happens in the launcher's process, so the app exposes a bounded,
content-free log (`silique-widgets.log`, at most 64 KiB, next to the encrypted
snapshot): timestamp, pid, event (read/write outcome, render state, retry polls)
and counts plus exception class names. It never records titles, bodies, folder
names or search queries. **Ustawienia → Ogólne → Diagnostyka widżetów** shows the
log with a copy button. Only a real decryption/format failure drops the snapshot;
a transient key or I/O problem keeps it.

## Privacy boundary

- Only unlocked account-mode vaults contribute notes. Hidden, deleted and
  password-vault notes are excluded, including their titles, bodies and folders.
- A move to hidden revokes the native snapshot before starting the move. Failed
  native revocation aborts the move rather than leaving an old launcher index.
- Snapshot bytes are AES-256-GCM encrypted using an AndroidKeystore key and an
  atomic file in `noBackupFilesDir`; they are not stored in SharedPreferences.
- Masking reads the live screen/keyguard state (PowerManager + KeyguardManager)
  on every render and result selection; it is never remembered from a broadcast,
  so a process that missed ACTION_USER_PRESENT while frozen cannot stay masked.
  Screen-off still masks immediately and clears open native query / results, and
  unlock refreshes from the current snapshot.
- Native search uses FLAG_SECURE, disables keyboard learning/autofill and does not
  save its query/results in Android instance state. This cannot stop a launcher
  from retaining data it already rendered while the phone was unlocked.
- Intent payloads contain validated IDs, not note text. Standalone launcher
  PendingIntents are immutable. Android's collection-list template alone must be
  mutable to accept a row's IDs; it targets only the private trampoline, which
  checks those IDs against the current eligible snapshot. Cold/warm requests are
  deduplicated; a reusable launcher tap receives a fresh request identity. Dart
  retains ordinary-vault requests while that vault is locked and revalidates after
  unlock. Home serializes rapid taps and flushes the prior editor before routing.

## Local automated checks

```sh
flutter test test/android_widgets_test.dart test/android_widgets_home_test.dart
flutter analyze --no-pub
```

Robolectric host tests run from the `android/` directory and need JDK 17 and the
Android SDK. On the constrained Hermes host, use the installed direct Gradle
executable (the repository wrapper may not be installed), one worker,
`-Dorg.gradle.jvmargs=-Xmx640m`, and `-Pkotlin.compiler.execution.strategy=in-process`:

```sh
export JAVA_HOME="$HOME/.local/share/silique-toolchains/jdk17"
export ANDROID_HOME="$HOME/.local/share/silique-toolchains/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
"$HOME/.local/share/silique-toolchains/gradle-9.3.1/bin/gradle" \
  :app:testDebugUnitTest :app:assembleDebug --no-daemon --max-workers=1 \
  -Dorg.gradle.jvmargs=-Xmx640m \
  -Pkotlin.compiler.execution.strategy=in-process \
  -Ptarget-platform=android-arm64
```

The local debug artifact is ARM64-only, not a release artifact. AGP 9 host-test
packaging explicitly depends on Flutter's copied assets. Robolectric encryption
checks use real AES-GCM with an injected JVM key: they do **not** prove hardware
Keystore behavior, lock-screen rendering or launcher behavior on a physical phone.

## Physical-device acceptance checklist (still required)

1. Install the debug APK on an ARM64 Android device; add all four widgets and
   resize the notes list. Verify live saves/deletes refresh without reopening it.
2. Select a list row and a search result; confirm the exact vault/note opens.
   Type body/folder/tag terms in native search, cancel it, and verify Flutter
   never opened until result selection. Verify outside-tap dismissal and rotation.
3. Tap the same new-note and journal widgets repeatedly. Confirm distinct new
   requests, ordinary empty-title notes, normal dated journal entries and no
   accidental writes to hidden mode. Repeat from a cold app process.
4. Move an indexed note to hidden; confirm its title/body disappear immediately
   from both widgets and an already-open search. Verify deleted/password-vault
   notes and all hidden notes are absent, including after app restart.
5. Lock/screen-off with search open and with list rows visible, then unlock.
   Confirm queries/results are wiped and no stale row opens. Lock an account
   vault in-app, tap a launcher action, unlock it and confirm one eventual action.
6. Lock the phone, let the app process die, then unlock: the list must repaint
   without opening the app. Force-stop the app, reboot the device, and confirm the
   widget shows notes (or "locked"/"temporarily unavailable", never a false
   "no notes").
7. Open **Ustawienia → Ogólne → Diagnostyka widżetów**, confirm the log lists the
   recent renders/reads and that copying it works.
8. Confirm `silique-widgets.enc` is absent from backups and contains no plaintext;
   verify the real device Keystore path and tamper failure without exporting keys.
