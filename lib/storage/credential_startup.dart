import 'package:flutter/foundation.dart';

import '../core/credential_mode.dart';
import '../l10n/strings.dart';
import 'managed_keys.dart';

class CredentialStartupPolicy {
  CredentialStartupPolicy({required this.files, TargetPlatform? platform})
    : platform = platform ?? defaultTargetPlatform;

  final CredentialFiles files;
  final TargetPlatform platform;

  // Separate from credential authority: declining must not rewrite mode/keys.
  static const androidOfferFile = 'android-system-offer-v1';

  Future<bool> shouldOfferAndroidMigration(
    CredentialModeControl control,
  ) async {
    if (platform != TargetPlatform.android ||
        control.mode != CredentialMode.local ||
        control.cleanupPending) {
      return false;
    }
    return files.locked(() async => await files.read(androidOfferFile) == null);
  }

  Future<void> keepLocalCredentials() => files.locked(() async {
    await files.write(androidOfferFile, 'declined');
    if (await files.read(androidOfferFile) != 'declined') {
      throw StateError('Migration offer decision was not persisted');
    }
  });

  Future<void> initialize(
    ManagedKeys keys, {
    CredentialMode? firstRunMode,
    bool requireExistingKey = false,
  }) => keys.initialize(
    // A first-run hint never overrides an existing authority or pending move.
    firstRunMode: platform == TargetPlatform.android
        ? CredentialMode.system
        : firstRunMode,
    requireExistingKey: requireExistingKey,
  );
}

/// Do not infer a fresh installation from a missing notebook folder alone.
/// This reads only device-local metadata; opening the chooser never accesses
/// the system keyring or commits the preselected mode.
Future<bool> credentialChoiceRequired(
  CredentialFiles files, {
  required bool recovering,
}) => files.locked(() async {
  if (await files.read('state.json') != null) return false;
  if (await files.read('local.json') != null) {
    throw FormatException(
      tr(
        'Brakuje ustawienia magazynu poświadczeń, ale lokalne klucze nadal '
            'istnieją. Przywróć plik ustawienia; nie utworzono nowego magazynu.',
        'The credential storage setting is missing, but local keys still exist. '
            'Restore the settings file; no new store was created.',
      ),
    );
  }
  return !recovering;
});
