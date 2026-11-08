import '../l10n/app_language.dart';

import 'package:flutter/material.dart';

import '../core/credential_mode.dart';
import '../storage/native_window.dart';
import 'credential_mode_picker.dart';
import 'theme.dart';

/// Recovery never changes authority automatically or regenerates credentials.
class CredentialRecoveryScreen extends StatefulWidget {
  const CredentialRecoveryScreen({
    super.key,
    required this.control,
    required this.onContinue,
  });
  final CredentialModeControl control;
  final Future<void> Function() onContinue;
  @override
  State<CredentialRecoveryScreen> createState() =>
      _CredentialRecoveryScreenState();
}

class _CredentialRecoveryScreenState extends State<CredentialRecoveryScreen> {
  bool _busy = false;
  bool _failed = false;
  Future<void> _continue() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await widget.control.retryCleanup();
      await widget.onContinue();
    } catch (_) {
      // Native/parser exception details can contain data; keep this screen
      // actionable without echoing credential contents or platform output.
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: appLanguage,
    builder: (context, _) => SiliqueMaterialApp(
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
                        'Przerwane przenoszenie poświadczeń',
                        'Credential migration interrupted',
                      ),
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      tr(
                        'Aktywne miejsce: ${credentialModeLabel(widget.control.mode)}',
                        'Active location: ${credentialModeLabel(widget.control.mode)}',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      tr(
                        'Przed otwarciem notatek trzeba uporządkować pozostałości przenoszenia. Zatwierdzony magazyn pozostanie aktywny. Niepotwierdzona kopia albo stara kopia zostanie usunięta dopiero po sprawdzeniu aktywnych poświadczeń. Nie utworzymy nowego klucza ani nie przełączymy trybu automatycznie. Operacja może wymagać jednorazowego odblokowania magazynu systemowego.',
                        'Migration leftovers must be cleaned up before opening notes. The confirmed store will remain active. An unconfirmed or old copy will be removed only after the active credentials are verified. We will not create a new key or switch modes automatically. This may require unlocking the system store once.',
                      ),
                      style: TextStyle(color: muted, height: 1.6),
                    ),
                    if (_failed)
                      Padding(
                        padding: EdgeInsets.only(top: 16),
                        child: Text(
                          tr(
                            'Nie udało się zakończyć porządkowania lub otworzyć notatek. Sprawdź dostęp do wybranego magazynu i spróbuj ponownie. Nie usuwaj plików poświadczeń.',
                            'Could not finish cleanup or open notes. Check access to the selected store and try again. Do not delete credential files.',
                          ),
                          key: Key('credential-recovery-error'),
                          style: TextStyle(
                            color: Colors.orangeAccent,
                            height: 1.5,
                          ),
                        ),
                      ),
                    const SizedBox(height: 24),
                    FilledButton(
                      key: const Key('credential-recovery-continue'),
                      onPressed: _busy ? null : _continue,
                      child: Text(
                        tr(
                          'Uporządkuj magazyn i kontynuuj',
                          'Clean up storage and continue',
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _busy ? null : NativeWindow.close,
                      child: Text(tr('Zamknij', 'Close')),
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
