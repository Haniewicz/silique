import 'dart:convert';

import '../l10n/app_language.dart';

import 'package:flutter/material.dart';

import '../core/server_trust.dart';
import '../services/api.dart';
import 'menus.dart';
import 'theme.dart';

/// Hex (uppercase) of a base64 SPKI pin — the format `./infra/install.sh status`
/// prints for `cert-spki`. The pin travels as base64, but comparing it against
/// the server's output requires the same alphabet on both sides.
String spkiHex(String spki) {
  try {
    final bytes = base64Decode(spki.replaceAll(RegExp(r'\s+'), ''));
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
  } catch (_) {
    return spki.toUpperCase();
  }
}

/// Fingerprint exactly as the user must type/compare it: grouped hex.
String spkiDisplay(String spki) => groupSpki(spkiHex(spki));

/// Groups a base64 fingerprint into 4-character groups separated by spaces, the
/// same layout `./infra/install.sh status` prints, so the two can be compared
/// column by column instead of as one long unbroken string.
String groupSpki(String spki) {
  final trimmed = spki.replaceAll(RegExp(r'\s+'), '');
  final buffer = StringBuffer();
  for (var i = 0; i < trimmed.length; i++) {
    if (i > 0 && i % 4 == 0) buffer.write(' ');
    buffer.write(trimmed[i]);
  }
  return buffer.toString();
}

/// Formats an ISO-8601 (or otherwise parseable) date for the grouped list, or
/// returns [fallback] when it cannot be parsed. Used for `savedAt`/`notAfter`
/// which live in the store as plain strings.
String formatTrustDate(String? iso, String fallback) {
  if (iso == null) return fallback;
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return fallback;
  return parsed.toLocal().toString().split('.').first;
}

String _compareInstruction() => tr(
  'Na serwerze wykonaj ./infra/install.sh status (albo openssl x509 -noout '
  '-fingerprint -sha256 -in /etc/nginx/silique/cert.pem) i porównaj odcisk z '
  'powyższym.',
  'On the server run ./infra/install.sh status (or openssl x509 -noout '
  '-fingerprint -sha256 -in /etc/nginx/silique/cert.pem) and compare the '
  'fingerprint with the one above.',
);

/// Dialog for a server that presented a certificate neither the platform nor a
/// confirmed pin trusts. It shows the SPKI fingerprint, subject and expiry so
/// the user can verify the server out-of-band before deciding.
///
/// Returns `true` when the user chose "Trust this server"; `null`/`false` when
/// they cancelled. Nothing is stored here — the caller confirms the pin only
/// after a `true` result.
Future<bool> showUnknownCertificateDialog(
  BuildContext context, {
  required String server,
  required UntrustedServerCertificate error,
}) async {
  final trusted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => ListenableBuilder(
      listenable: appLanguage,
      builder: (ctx, _) => AlertDialog(
        scrollable: true,
        title: Text(
          tr('Nieznany certyfikat serwera', 'Unknown server certificate'),
        ),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(
                  'Silique nie może potwierdzić tożsamości serwera $server. '
                  'Zweryfikuj odcisk klucza z wiarygodnym źródłem, zanim '
                  'zaufasz temu serwerowi.',
                  'Silique cannot confirm the identity of $server. Verify the '
                  'key fingerprint against a trusted source before trusting '
                  'this server.',
                ),
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 16),
              Text(
                tr('ODCISK KLUCZA (SPKI)', 'KEY FINGERPRINT (SPKI)'),
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.3,
                  color: muted,
                ),
              ),
              const SizedBox(height: 8),
              SelectableText(
                spkiDisplay(error.spki),
                key: const Key('server-trust-fingerprint'),
                contextMenuBuilder: siliqueTextContextMenu,
                style: const TextStyle(
                  fontFamily: kMonoFontFamily,
                  fontFamilyFallback: ['monospace'],
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                tr('Podmiot: ${error.subject}', 'Subject: ${error.subject}'),
                key: const Key('server-trust-subject'),
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              Text(
                tr(
                  'Ważny do: ${formatTrustDate(error.notAfter.toIso8601String(), '—')}',
                  'Valid until: ${formatTrustDate(error.notAfter.toIso8601String(), '—')}',
                ),
                key: const Key('server-trust-not-after'),
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 16),
              Text(_compareInstruction(), style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Anuluj', 'Cancel')),
          ),
          FilledButton(
            key: const Key('server-trust-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Zaufaj temu serwerowi', 'Trust this server')),
          ),
        ],
      ),
    ),
  );
  return trusted == true;
}

/// Dialog for a server whose certificate public key no longer matches the
/// confirmed pin. This is a hard block: there is intentionally no "trust
/// anyway" action, because a changed key usually means a key rotation the user
/// did not authorise.
Future<void> showPinMismatchDialog(
  BuildContext context, {
  required String server,
  required ServerCertificatePinMismatch error,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => ListenableBuilder(
      listenable: appLanguage,
      builder: (ctx, _) => AlertDialog(
        scrollable: true,
        title: Text(
          tr('Certyfikat serwera się zmienił', 'The server certificate changed'),
        ),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(
                  'Klucz publiczny serwera $server nie zgadza się z '
                  'zatwierdzonym odciskiem. To może oznaczać podmianę serwera '
                  'albo rotację klucza, której nie potwierdziłeś. Połączenie '
                  'zostało zablokowane.',
                  'The public key of $server does not match the confirmed '
                  'fingerprint. This may indicate a substituted server or a '
                  'key rotation you have not authorised. The connection has '
                  'been blocked.',
                ),
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 16),
              Text(
                tr('OCZEKIWANY', 'EXPECTED'),
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.3,
                  color: muted,
                ),
              ),
              SelectableText(
                spkiDisplay(error.expected),
                key: const Key('server-trust-expected'),
                contextMenuBuilder: siliqueTextContextMenu,
                style: const TextStyle(
                  fontFamily: kMonoFontFamily,
                  fontFamilyFallback: ['monospace'],
                  fontSize: 14,
                  color: Colors.orangeAccent,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                tr('OTRZYMANY', 'RECEIVED'),
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.3,
                  color: muted,
                ),
              ),
              SelectableText(
                spkiDisplay(error.actual),
                key: const Key('server-trust-actual'),
                contextMenuBuilder: siliqueTextContextMenu,
                style: const TextStyle(
                  fontFamily: kMonoFontFamily,
                  fontFamilyFallback: ['monospace'],
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                tr(
                  'Jeśli klucz został zmieniony celowo, usuń zapisany '
                  'certyfikat w Ustawieniach → „Zaufany certyfikat serwera”. '
                  'Uwaga: osłabia to ochronę do czasu ponownego potwierdzenia.',
                  'If the key was changed intentionally, remove the saved '
                  'certificate in Settings → “Trusted server certificate”. '
                  'Note: this weakens protection until it is confirmed again.',
                ),
                style: TextStyle(
                  color: Colors.orangeAccent,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            key: const Key('server-trust-mismatch-close'),
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Zamknij', 'Close')),
          ),
        ],
      ),
    ),
  );
}

/// Dialog for a certificate whose key matches the pin but which has expired.
/// The single remedy is server-side renewal with the existing key, which keeps
/// the SPKI and therefore does not require re-confirmation.
Future<void> showExpiredCertificateDialog(
  BuildContext context, {
  required String server,
  required ServerCertificateExpired error,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => ListenableBuilder(
      listenable: appLanguage,
      builder: (ctx, _) => AlertDialog(
        scrollable: true,
        title: Text(
          tr('Certyfikat serwera wygasł', 'The server certificate expired'),
        ),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(
                  'Certyfikat serwera $server wygasł '
                  '(${formatTrustDate(error.notAfter.toIso8601String(), '—')}). '
                  'Na serwerze wykonaj ./infra/install.sh renew-cert — '
                  'ponieważ zachowuje dotychczasowy klucz, nie będzie '
                  'wymagane ponowne potwierdzanie.',
                  'The certificate of $server expired '
                  '(${formatTrustDate(error.notAfter.toIso8601String(), '—')}). '
                  'On the server run ./infra/install.sh renew-cert — because '
                  'it keeps the existing key, no re-confirmation will be '
                  'required.',
                ),
                key: const Key('server-trust-renew-cert'),
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              SelectableText(
                'renew-cert',
                contextMenuBuilder: siliqueTextContextMenu,
                style: const TextStyle(
                  fontFamily: kMonoFontFamily,
                  fontFamilyFallback: ['monospace'],
                  fontSize: 14,
                  color: accent,
                ),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            key: const Key('server-trust-expired-close'),
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Zamknij', 'Close')),
          ),
        ],
      ),
    ),
  );
}

/// Runs [attempt], intercepting certificate-trust failures and presenting the
/// matching dialog. On "trust this server" the pin is confirmed once and the
/// attempt is retried exactly once — never in a loop, and never with an
/// implicit accept. Any other failure (including a second trust failure)
/// propagates to the caller.
Future<T> connectTrustingServerCertificate<T>({
  required BuildContext context,
  required ServerTrust trust,
  required Uri base,
  required Future<T> Function() attempt,
}) async {
  try {
    return await attempt();
  } on UntrustedServerCertificate catch (error) {
    // `attempt()` awaited above: the widget may be gone by now, and showing a
    // dialog on a disposed context would throw. Nothing to trust without UI.
    if (!context.mounted) rethrow;
    final trusted = await showUnknownCertificateDialog(
      context,
      server: base.toString(),
      error: error,
    );
    if (!trusted) rethrow;
    await trust.confirm(
      base,
      CertInfo(
        spki: error.spki,
        subject: error.subject,
        san: error.san,
        notAfter: error.notAfter,
      ),
    );
    return attempt();
  } on ServerCertificatePinMismatch catch (error) {
    await showPinMismatchDialog(context, server: base.toString(), error: error);
    rethrow;
  } on ServerCertificateExpired catch (error) {
    await showExpiredCertificateDialog(
      context,
      server: base.toString(),
      error: error,
    );
    rethrow;
  }
}

/// Settings section listing the confirmed certificate pin for the current
/// server address, its pin date and expiry, with a confirmation-gated "forget"
/// action. When no pin exists, the server is using a certificate from a trusted
/// CA and there is nothing to list.
class TrustedServerCertSection extends StatefulWidget {
  const TrustedServerCertSection({
    super.key,
    required this.trust,
    required this.base,
    this.onChanged,
  });

  final ServerTrust trust;

  /// The current server address; `serverKeyOf(base)` selects the pin row.
  final Uri base;

  /// Called after a pin is removed (so the parent can refresh/repaint).
  final VoidCallback? onChanged;

  @override
  State<TrustedServerCertSection> createState() =>
      _TrustedServerCertSectionState();
}

class _TrustedServerCertSectionState extends State<TrustedServerCertSection> {
  Map<String, String>? _record;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final record = await widget.trust.store.read(serverKeyOf(widget.base));
    if (!mounted) return;
    setState(() => _record = record);
  }

  Future<void> _forget() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => ListenableBuilder(
        listenable: appLanguage,
        builder: (ctx, _) => AlertDialog(
          title: Text(
            tr('Usunąć zaufany certyfikat?', 'Remove the trusted certificate?'),
          ),
          content: Text(
            tr(
              'Połączenie z tym serwerem będzie wymagać ponownego '
              'potwierdzenia odcisku przy najbliższej próbie.',
              'Connecting to this server will require confirming the '
              'fingerprint again on the next attempt.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Anuluj', 'Cancel')),
            ),
            FilledButton(
              key: const Key('server-trust-forget-confirm'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Usuń', 'Remove')),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      // "Forget" clears this server's pin. The store has no delete verb, so we
      // write an empty record; it reads back as "no pin" (see FileTrustStore).
      await widget.trust.store.write(
        serverKeyOf(widget.base),
        const <String, String>{},
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    widget.onChanged?.call();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    Localizations.localeOf(context);
    final record = _record;
    final spki = record?['spki'];
    return Column(
      key: const Key('trusted-server-cert-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 12),
        Text(
          tr('ZAUFANY CERTYFIKAT SERWERA', 'TRUSTED SERVER CERTIFICATE'),
          style: TextStyle(fontSize: 11, letterSpacing: 1.3, color: muted),
        ),
        const SizedBox(height: 8),
        if (spki == null && record == null && _busy == false)
          Text(
            tr(
              'brak (serwer używa certyfikatu z zaufanego CA)',
              'none (the server uses a certificate from a trusted CA)',
            ),
            key: const Key('server-trust-none'),
            style: const TextStyle(color: muted, fontSize: 12),
          )
        else if (spki != null) ...[
          SelectableText(
            spkiDisplay(spki),
            key: const Key('server-trust-pinned'),
            contextMenuBuilder: siliqueTextContextMenu,
            style: const TextStyle(
              fontFamily: kMonoFontFamily,
              fontFamilyFallback: ['monospace'],
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            tr(
              'Przypięto: ${formatTrustDate(record?['savedAt'], '—')}',
              'Pinned: ${formatTrustDate(record?['savedAt'], '—')}',
            ),
            key: const Key('server-trust-pinned-at'),
            style: const TextStyle(color: muted, fontSize: 11),
          ),
          Text(
            tr(
              'Ważny do: ${formatTrustDate(record?['notAfter'], '—')}',
              'Valid until: ${formatTrustDate(record?['notAfter'], '—')}',
            ),
            key: const Key('server-trust-pinned-not-after'),
            style: const TextStyle(color: muted, fontSize: 11),
          ),
          TextButton.icon(
            key: const Key('server-trust-forget'),
            onPressed: _busy ? null : _forget,
            icon: const Icon(Icons.delete_outline, size: 18),
            label: Text(tr('Zapomnij', 'Forget')),
          ),
        ],
      ],
    );
  }
}
