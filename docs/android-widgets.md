# Android launcher widgets

The launcher picker offers **Notatki**, **Nowa notatka**, **Wpis do dziennika**
and **Szukaj**. Search is a small native Android dialog, not a Flutter route;
typing/filtering/cancelling it never starts MainActivity. Selecting a result opens
the exact ordinary note. New-note and journal actions open the ordinary editor,
leaving and locking the hidden section first. Journal uses the repository's normal
local-date/title behavior.

## Privacy boundary

- Only unlocked account-mode vaults contribute notes. Hidden, deleted and
  password-vault notes are excluded, including their titles, bodies and folders.
- A move to hidden revokes the native snapshot before starting the move. Failed
  native revocation aborts the move rather than leaving an old launcher index.
- Snapshot bytes are AES-256-GCM encrypted using an AndroidKeystore key and an
  atomic file in `noBackupFilesDir`; they are not stored in SharedPreferences.
- Screen-off immediately masks launcher content and clears open native query /
  results, even before keyguard reports locked. Keyguard checks also guard every
  snapshot read and result selection. Unlock refreshes from the current snapshot.
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
Android SDK. On the constrained Hermes
host, use the installed direct Gradle executable (the repository wrapper may not
be installed), one worker, `-Dorg.gradle.jvmargs=-Xmx640m`, and
`-Pkotlin.compiler.execution.strategy=in-process`:

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
6. Confirm `silique-widgets.enc` is absent from backups and contains no plaintext;
   verify the real device Keystore path and tamper failure without exporting keys.
