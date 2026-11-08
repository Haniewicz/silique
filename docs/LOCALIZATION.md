# Interface language (0.2.33+42)

Silique supports English and Polish. English is the default when there is no
valid saved preference, independently of the operating system language. The same
English / Polski control is available during initial storage setup and in
Settings. Changes apply without replacing the navigator, notebook or editor.

## Preference and data boundaries

- `interface-language` in the application-support directory is a device-local
  presentation preference. It is loaded before opening storage or credentials.
  Selecting a language does not create a vault or access the keyring.
- A missing, malformed or unreadable preference falls back to English without
  deleting the original preference. Explicit choices are serialized and saved
  through a flushed sibling file and rename; a failed file write leaves the
  active language unchanged and permits a retry.
- Existing note titles, bodies, folders, tags, vault names and encrypted data
  remain unchanged. New default titles and newly inserted templates use the
  language selected when they are created. Journal date identifiers, storage
  directory names, protocol fields, namespaces and crypto identities stay fixed.
- The protected-vault name in persistent storage remains its legacy redaction
  marker. Only the locked display projection is translated.
- Android keeps a presentation-only native preference for launcher widgets and
  search, refreshed through `silique/language`; macOS uses the same channel for
  application-owned native messages. A native refresh failure never blocks
  notebook startup or undoes a saved choice: Settings/setup show a distinct
  saved-but-refresh-pending warning and a retry action. Windows reads the bounded
  local preference for its pre-Flutter instance/update message without
  initializing storage.
- Deterministic conflict-copy contents remain language-independent, including
  the legacy title suffix. Localizing persisted auto-reconciliation results
  would make identical copy IDs diverge on devices with different languages;
  the UI's conflict annotation is translated separately.
- Cocoa, Keychain, Sparkle, Android document pickers and installer/UAC dialogs are
  operating-system/component UI. Their own localization may follow the system;
  Silique does not override global operating-system language or security policy.

## Code conventions

`lib/l10n/strings.dart` is pure Dart. `tr(polish, english)` selects app-owned copy;
never apply it to arbitrary stored/user text. Services and storage import this
pure library, not Flutter's application controller. UI imports
`lib/l10n/app_language.dart` and uses locale dependencies or `LanguageBuilder`
for live rebuilding. Do not key the whole app by locale: that would destroy
active field identity, selection and pending editor state.

All app roots use `SiliqueMaterialApp` with Flutter's English/Polish Material,
Widgets and Cupertino delegates. Historical Polish-text fixtures explicitly use
Polish in `test/flutter_test_config.dart`; bilingual tests independently exercise
English defaults, both directions, restart persistence and data preservation.

## Verification entry points

```sh
flutter test test/app_language_test.dart test/language_preference_recovery_test.dart \
  test/dialog_language_test.dart test/home_language_test.dart \
  test/service_language_test.dart test/native_language_contract_test.dart
python3 -m unittest tool.test_native_language -v
```

Native Android language/widget tests are in `SiliqueLanguageTest.kt`. Native
Swift/Foundation and Windows runner compilation must be verified on their
platforms; portable contract checks are not owner-device installation evidence.
Publication remains a separate owner-approved step.
