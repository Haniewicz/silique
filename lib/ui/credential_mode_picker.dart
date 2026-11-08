import '../l10n/app_language.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/credential_mode.dart';
import 'theme.dart';

String credentialModeLabel(CredentialMode mode) => switch (mode) {
  CredentialMode.local => tr(
    'Lokalny plik (mniej bezpieczny)',
    'Local file (less secure)',
  ),
  CredentialMode.system => tr(
    'Systemowy magazyn / pęk kluczy',
    'System store / keychain',
  ),
};

String get localCredentialWarning => tr(
  'Mniej bezpieczne: prywatny plik aplikacji zawiera klucz szyfrowania, tokeny kont i prywatne tożsamości. Dostęp do tego pliku w systemie plików może umożliwić odszyfrowanie danych i podszywanie się pod Twoje konta.',
  'Less secure: the app’s private file contains the encryption key, account tokens and private identities. Access to this file through the file system may allow your data to be decrypted and your accounts to be impersonated.',
);

class LocalCredentialWarning extends StatelessWidget {
  const LocalCredentialWarning({super.key});

  @override
  Widget build(BuildContext context) {
    Localizations.localeOf(context);
    return Text(
      localCredentialWarning,
      style: TextStyle(color: Colors.orangeAccent, height: 1.5),
    );
  }
}

/// Placement of the same credentials, never a second notebook or synced option.
class CredentialModePicker extends StatelessWidget {
  const CredentialModePicker({
    super.key,
    required this.mode,
    required this.onChanged,
  });

  final CredentialMode mode;
  final ValueChanged<CredentialMode>? onChanged;

  @override
  Widget build(BuildContext context) {
    Localizations.localeOf(context);
    return defaultTargetPlatform == TargetPlatform.android
        ? const SizedBox.shrink()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(
                  'PRZECHOWYWANIE KLUCZY I DANYCH LOGOWANIA',
                  'KEY AND CREDENTIAL STORAGE',
                ),
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.3,
                  color: muted,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                tr(
                  'Te same klucze i dane kont, jedno aktywne miejsce przechowywania. Wybór dotyczy tylko tego urządzenia i nie jest synchronizowany. Nie szyfruje całego notatnika: zwykłe dane SQLite i pliki Markdown mogą pozostawać jawnym tekstem. Hasło ukrytych notatek jest osobnym zabezpieczeniem.',
                  'The same keys and account credentials, with one active storage location. This choice applies only to this device and is not synced. It does not encrypt the entire notebook: ordinary SQLite data and Markdown files may remain plain text. The hidden notes password is a separate safeguard.',
                ),
                style: TextStyle(color: muted, fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 8),
              for (final option in CredentialMode.values)
                ListTile(
                  key: Key('credential-mode-${option.name}'),
                  contentPadding: EdgeInsets.zero,
                  selected: option == mode,
                  enabled: onChanged != null,
                  leading: Icon(
                    option == mode
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text(credentialModeLabel(option)),
                  onTap: onChanged == null ? null : () => onChanged!(option),
                ),
              Text(
                tr(
                  'Systemowy magazyn może poprosić o hasło systemu. Zmiana miejsca przechowywania może wymagać jednorazowego odblokowania magazynu systemowego.',
                  'The system store may ask for your system password. Changing storage location may require unlocking the system store once.',
                ),
                style: TextStyle(color: muted, fontSize: 12, height: 1.5),
              ),
              if (mode == CredentialMode.local) ...[
                const SizedBox(height: 12),
                const LocalCredentialWarning(),
              ],
            ],
          );
  }
}
