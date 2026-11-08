import '../l10n/app_language.dart';

import 'package:flutter/material.dart';

import '../core/credential_mode.dart';
import 'credential_recovery.dart';
import 'theme.dart';

/// A one-time offer for legacy Android local placement, not a mode selector.
/// Nothing touches the system backend until the user explicitly agrees.
class AndroidCredentialMigrationScreen extends StatefulWidget {
  const AndroidCredentialMigrationScreen({
    super.key,
    required this.control,
    required this.onKeepLocal,
    required this.onContinue,
  });

  final CredentialModeControl control;
  final Future<void> Function() onKeepLocal;
  final Future<void> Function() onContinue;

  @override
  State<AndroidCredentialMigrationScreen> createState() =>
      _AndroidCredentialMigrationScreenState();
}

class _AndroidCredentialMigrationScreenState
    extends State<AndroidCredentialMigrationScreen> {
  bool _busy = false;
  bool _failed = false;

  Future<void> _decide({required bool migrate}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      if (migrate) {
        await widget.control.changeMode(CredentialMode.system);
      } else {
        await widget.onKeepLocal();
      }
      await widget.onContinue();
    } catch (_) {
      // Never echo native credential exceptions or imply a reset is safe.
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: appLanguage,
    builder: (context, _) => widget.control.cleanupPending && !_busy
        ? CredentialRecoveryScreen(
            control: widget.control,
            onContinue: widget.onContinue,
          )
        : SiliqueMaterialApp(
            debugShowCheckedModeBanner: false,
            theme: siliqueTheme(),
            home: Scaffold(
              body: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(28),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tr(
                              'Zabezpieczyć istniejące klucze?',
                              'Secure your existing keys?',
                            ),
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            tr(
                              'Ta instalacja przechowuje poświadczenia w mniej bezpiecznym lokalnym pliku. Zalecamy przeniesienie tych samych kluczy i danych logowania do magazynu systemowego (Android Keystore). Nie zmienimy notatnika, kont ani hasła ukrytych notatek. Poprzednia kopia poświadczeń zostanie usunięta dopiero po sprawdzeniu i zatwierdzeniu magazynu docelowego.',
                              'This installation stores credentials in a less secure local file. We recommend moving the same keys and sign-in credentials to the system store (Android Keystore). Your notebook, accounts and hidden notes password will not change. The previous credential copy will be removed only after the destination store is verified and confirmed.',
                            ),
                            style: TextStyle(color: muted, height: 1.6),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            tr(
                              'To jednorazowa propozycja. Bez Twojej zgody dotychczasowy lokalny magazyn pozostanie aktywny i niczego w nim nie usuniemy.',
                              'This is a one-time offer. Without your consent, the current local store will remain active and nothing in it will be deleted.',
                            ),
                            style: TextStyle(color: muted, height: 1.6),
                          ),
                          if (_failed)
                            Padding(
                              padding: EdgeInsets.only(top: 16),
                              child: Text(
                                tr(
                                  'Nie udało się zakończyć operacji lub otworzyć notatek. Nie usuwaj plików poświadczeń. Spróbuj ponownie.',
                                  'Could not complete the operation or open notes. Do not delete credential files. Try again.',
                                ),
                                key: Key('android-credential-migration-error'),
                                style: TextStyle(
                                  color: Colors.orangeAccent,
                                  height: 1.5,
                                ),
                              ),
                            ),
                          const SizedBox(height: 24),
                          FilledButton(
                            key: const Key('android-credential-migrate'),
                            onPressed: _busy
                                ? null
                                : () => _decide(migrate: true),
                            child: Text(
                              tr(
                                'Przenieś do magazynu systemowego',
                                'Move to system store',
                              ),
                            ),
                          ),
                          TextButton(
                            key: const Key('android-credential-keep-local'),
                            onPressed:
                                _busy ||
                                    widget.control.mode != CredentialMode.local
                                ? null
                                : () => _decide(migrate: false),
                            child: Text(
                              tr(
                                'Zachowaj dotychczasowy magazyn',
                                'Keep current store',
                              ),
                            ),
                          ),
                          if (_busy)
                            const Padding(
                              padding: EdgeInsets.only(top: 16),
                              child: LinearProgressIndicator(),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
  );
}
