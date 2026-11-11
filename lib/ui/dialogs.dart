import '../l10n/app_language.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../services/notebook.dart';
import '../services/api.dart';
import '../services/app_updates.dart';
import 'updates_panel.dart';
import 'language_picker.dart';
import '../core/models.dart';
import '../core/credential_mode.dart';
import 'credential_mode_picker.dart';
import '../core/server_trust.dart';
import '../core/workspace.dart';
import '../storage/native_storage.dart';
import 'server_trust_dialogs.dart';
import 'theme.dart';
import 'menus.dart';
import 'color_picker.dart';

Future<String?> askText(
  BuildContext context,
  String title, {
  String initial = '',
  bool secret = false,
  String? hint,
  String Function()? titleBuilder,
  String Function()? hintBuilder,
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: appLanguage,
      builder: (ctx, _) => AlertDialog(
        title: Text(titleBuilder?.call() ?? title),
        content: SizedBox(
          width: 400,
          child: TextField(
            contextMenuBuilder: siliqueTextContextMenu,
            controller: controller,
            autofocus: true,
            obscureText: secret,
            decoration: InputDecoration(hintText: hintBuilder?.call() ?? hint),
            onSubmitted: (value) => Navigator.pop(ctx, value),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Anuluj', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(tr('Zapisz', 'Save')),
          ),
        ],
      ),
    ),
  );
  // Dialog transition finishes after its Future resolves; do not dispose its field mid-transition.
  Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
  return result;
}

Future<void> showRecovery(
  BuildContext context,
  String key, {
  bool vault = false,
}) async {
  var saved = false;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => ListenableBuilder(
      listenable: appLanguage,
      builder: (ctx, _) => StatefulBuilder(
        builder: (ctx, setState) => PopScope(
          canPop: saved,
          child: AlertDialog(
            title: Text(
              vault
                  ? tr('Klucz odzyskiwania vaulta', 'Vault recovery key')
                  : tr('Klucz odzyskiwania konta', 'Account recovery key'),
            ),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr(
                      'Zapisz ten klucz w bezpiecznym miejscu, np. w menedżerze haseł. Umożliwi odblokowanie danych na nowym urządzeniu. Serwer nie ma jego kopii.',
                      'Save this key somewhere safe, such as a password manager. It lets you unlock your data on a new device. The server has no copy of it.',
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: sidebar,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      key,
                      contextMenuBuilder: siliqueTextContextMenu,
                      style: const TextStyle(
                        fontFamily: kMonoFontFamily,
                        fontFamilyFallback: ['monospace'],
                        fontSize: 14,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () async =>
                        Clipboard.setData(ClipboardData(text: key)),
                    icon: const Icon(Icons.copy, size: 16),
                    label: Text(tr('Kopiuj klucz', 'Copy key')),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: saved,
                    onChanged: (v) => setState(() => saved = v ?? false),
                    title: Text(
                      tr(
                        'Zapisałem klucz odzyskiwania',
                        'I have saved the recovery key',
                      ),
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              FilledButton(
                onPressed: saved ? () => Navigator.pop(ctx) : null,
                child: Text(tr('Gotowe', 'Done')),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<({String name, String? password})?> askVault(
  BuildContext context,
) async {
  final name = TextEditingController(), password = TextEditingController();
  var protected = false;
  String Function()? error;
  final result = await showDialog<({String name, String? password})>(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: appLanguage,
      builder: (ctx, _) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(tr('Nowy vault', 'New vault')),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(
                    'Oddzielna przestrzeń na Twoje notatki.',
                    'A separate space for your notes.',
                  ),
                  style: TextStyle(color: muted),
                ),
                const SizedBox(height: 20),
                TextField(
                  contextMenuBuilder: siliqueTextContextMenu,
                  controller: name,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: tr('Nazwa vaulta', 'Vault name'),
                    hintText: tr('np. Osobiste', 'e.g. Personal'),
                  ),
                ),
                const SizedBox(height: 18),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: protected,
                  onChanged: (v) => setState(() => protected = v),
                  title: Text(
                    tr('Dodatkowe hasło', 'Additional password'),
                    style: TextStyle(fontSize: 14),
                  ),
                  subtitle: Text(
                    tr(
                      'Szyfruje również lokalne pliki.',
                      'Also encrypts local files.',
                    ),
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                ),
                if (protected)
                  TextField(
                    contextMenuBuilder: siliqueTextContextMenu,
                    controller: password,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: tr('Hasło vaulta', 'Vault password'),
                      hintText: tr(
                        'Co najmniej 12 znaków',
                        'At least 12 characters',
                      ),
                    ),
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error!(),
                      style: const TextStyle(color: Colors.orangeAccent),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Anuluj', 'Cancel')),
            ),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty ||
                    protected && password.text.length < 12) {
                  setState(
                    () => error = () => tr(
                      'Podaj nazwę i hasło o długości min. 12 znaków.',
                      'Enter a name and a password of at least 12 characters.',
                    ),
                  );
                  return;
                }
                Navigator.pop(ctx, (
                  name: name.text.trim(),
                  password: protected ? password.text : null,
                ));
              },
              child: Text(tr('Utwórz vault', 'Create vault')),
            ),
          ],
        ),
      ),
    ),
  );
  Future<void>.delayed(const Duration(seconds: 1), () {
    name.dispose();
    password.dispose();
  });
  return result;
}

/// Asks for the extra password that protects hidden notes.
/// With [create] the user picks and confirms a new one.
Future<String?> askHiddenPassword(
  BuildContext context, {
  required bool create,
}) => showDialog<String>(
  context: context,
  builder: (_) => _HiddenPasswordDialog(create: create),
);

class _HiddenPasswordDialog extends StatefulWidget {
  const _HiddenPasswordDialog({required this.create});
  final bool create;
  @override
  State<_HiddenPasswordDialog> createState() => _HiddenPasswordDialogState();
}

class _HiddenPasswordDialogState extends State<_HiddenPasswordDialog> {
  final first = TextEditingController(), second = TextEditingController();
  String Function()? error;
  bool get create => widget.create;
  @override
  void dispose() {
    first.clear();
    second.clear();
    first.dispose();
    second.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Localizations.localeOf(context);
    return AlertDialog(
      scrollable: true,
      title: Text(
        create
            ? tr('Hasło ukrytych notatek', 'Hidden notes password')
            : tr('Odblokuj ukryte notatki', 'Unlock hidden notes'),
      ),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              create
                  ? tr(
                      'Ukryte notatki są dodatkowo szyfrowane tym hasłem — także wtedy, gdy synchronizują się między urządzeniami. Hasło nie jest wysyłane na serwer i nie można go odzyskać.',
                      'Hidden notes are additionally encrypted with this password, including when syncing between devices. The password is not sent to the server and cannot be recovered.',
                    )
                  : tr(
                      'Podaj hasło ustawione dla ukrytych notatek.',
                      'Enter the password set for hidden notes.',
                    ),
              style: const TextStyle(color: muted, fontSize: 12),
            ),
            const SizedBox(height: 16),
            TextField(
              contextMenuBuilder: siliqueTextContextMenu,
              controller: first,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(
                labelText: tr(
                  'Hasło (min. 8 znaków)',
                  'Password (at least 8 characters)',
                ),
              ),
            ),
            if (create) ...[
              const SizedBox(height: 12),
              TextField(
                contextMenuBuilder: siliqueTextContextMenu,
                controller: second,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: tr('Powtórz hasło', 'Repeat password'),
                ),
              ),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error!(),
                  style: const TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('Anuluj', 'Cancel')),
        ),
        FilledButton(
          onPressed: () {
            final value = first.text;
            if (value.trim().length < 8) {
              setState(
                () => error = () => tr(
                  'Hasło musi mieć co najmniej 8 znaków.',
                  'The password must have at least 8 characters.',
                ),
              );
              return;
            }
            if (create && value != second.text) {
              setState(
                () => error = () => tr(
                  'Hasła nie są identyczne.',
                  'The passwords do not match.',
                ),
              );
              return;
            }
            Navigator.pop(context, value);
          },
          child: Text(
            create
                ? tr('Utwórz hasło', 'Create password')
                : tr('Odblokuj', 'Unlock'),
          ),
        ),
      ],
    );
  }
}

class SettingsPanel extends StatefulWidget {
  const SettingsPanel({
    super.key,
    required this.notebook,
    required this.onChanged,
    this.vault,
    this.onMoveStorage,
    this.updater,
    this.beforeUpdate,
    this.openUpdates = false,
    this.serverTrust,
    this.serverBase,
  });
  final Notebook notebook;
  final VoidCallback onChanged;

  /// The pin store consulted when rendering the "Trusted server certificate"
  /// section. When null the section is omitted (no pinning available).
  final ServerTrust? serverTrust;

  /// The current server address whose pin the section lists.
  final Uri? serverBase;

  /// The vault the per-vault presentation preferences (compact mode) edit.
  /// The switch is disabled while no unlocked vault is current.
  final Vault? vault;
  final VoidCallback? onMoveStorage;
  final AppUpdater? updater;
  final Future<void> Function()? beforeUpdate;

  /// Open the dialog directly on the updates tab, so the update snackbar
  /// action never leaves the user searching the settings.
  final bool openUpdates;
  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel>
    with SingleTickerProviderStateMixin {
  static const _generalTab = Key('settings-tab-general');
  static const _appearanceTab = Key('settings-tab-appearance');
  static const _accountTab = Key('settings-tab-account');
  static const _storageTab = Key('settings-tab-storage');
  static const _updatesTab = Key('settings-tab-updates');
  static const _updatesTabIndex = 4;

  final server = TextEditingController(),
      email = TextEditingController(),
      password = TextEditingController(),
      recovery = TextEditingController();
  late final TabController _tabs = TabController(
    length: 5,
    vsync: this,
    // The update snackbar action must land on the updates tab immediately;
    // no post-frame scroll reveal is needed inside a dedicated tab.
    initialIndex: widget.openUpdates ? _updatesTabIndex : 0,
  );
  final TabBarScrollController _tabScroll = TabBarScrollController();

  void _onTabBarPointerSignal(PointerSignalEvent event) {
    // A mouse wheel over a horizontal scrollable only forwards scrollDelta.dx
    // by default (see Scrollable._pointerSignalEventDelta), so the vertical
    // wheel — the only axis a physical mouse offers — never reaches the tabs.
    // Re-route both axes onto the bar's own scroll controller, and only while
    // the pointer is over the bar (the Listener is scoped to the TabBar), so
    // the dialog's tab content below is never scrolled by the same gesture.
    if (event is! PointerScrollEvent) return;
    if (!_tabScroll.hasClients) return;
    final position = _tabScroll.position;
    final delta = event.scrollDelta.dy == 0 ? event.scrollDelta.dx : event.scrollDelta.dy;
    final target = (position.pixels - delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target != position.pixels) position.jumpTo(target);
  }
  bool register = false, busy = false;
  String? error;
  String Function()? message;
  List<Json>? get devices => repo.devices;
  set devices(List<Json>? value) => repo.devices = value;
  List<Json> pairingRequests = [];
  String? safetyCode;

  /// The certificate of the current server that has been presented but is not
  /// yet pinned, captured from the most recent [UntrustedServerCertificate].
  /// When non-null the account tab renders an inline "trust this server" block
  /// (with the SPKI fingerprint) instead of leaking the raw exception text.
  CertInfo? _untrustedCert;

  Notebook get repo => widget.notebook;

  /// The normalized base of the signed-in server, or null when signed out.
  Uri? get _trustBase =>
      repo.session == null ? null : SiliqueApi.validateServer(repo.session!.server);
  @override
  void initState() {
    super.initState();
    appLanguage.addListener(_languageChanged);
    server.text = repo.session?.server ?? '';
    email.text = repo.session?.email ?? '';
    if (repo.session != null) unawaited(refreshDevices());
  }

  void _languageChanged() => setState(() {});

  @override
  void dispose() {
    appLanguage.removeListener(_languageChanged);
    _tabScroll.dispose();
    _tabs.dispose();
    for (final c in [server, email, password, recovery]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      await action();
      widget.onChanged();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  CertInfo _untrustedCertInfo(UntrustedServerCertificate error) => CertInfo(
    spki: error.spki,
    subject: error.subject,
    san: error.san,
    notAfter: error.notAfter,
  );

  /// Runs [action] through the shared server-trust guard, so every account-tab
  /// request to the server can be confirmed from *any* path — not only login.
  ///
  /// `server_trust.dart` throws `ServerCertificatePinMismatch`/`Expired`, which
  /// `guardServerTrust` surfaces with its dialogs and rethrows. An
  /// `UntrustedServerCertificate` is handled inline: the fingerprint is captured
  /// and the account tab shows its "Zaufaj temu serwerowi" block, so a raw
  /// exception never reaches the `error` field. With no live UI (`!mounted`) the
  /// error propagates instead, as required for the no-UI action case.
  Future<void> _serverAction(Future<void> Function() action) async {
    final base = _trustBase;
    if (base == null) return action();
    await guardServerTrust<void>(
      context: context,
      trust: repo.trust,
      base: base,
      attempt: () async {
        try {
          await action();
        } on UntrustedServerCertificate catch (error) {
          if (!mounted) rethrow;
          setState(() => _untrustedCert = _untrustedCertInfo(error));
        }
      },
    );
  }

  Future<void> refreshDevices() =>
      run(() => _serverAction(() => repo.refreshDevices()));

  /// Persists the pinned certificate for the current server and retries the
  /// device/pairing refresh exactly once, matching the inline trust block.
  Future<void> _trustServer() async {
    final cert = _untrustedCert;
    final base = _trustBase;
    if (cert == null || base == null) return;
    await repo.trust.confirm(base, cert);
    if (mounted) setState(() => _untrustedCert = null);
    await refreshDevices();
    await refreshPairing();
  }

  /// Inline "no trust yet" block: shows the server's SPKI fingerprint and a
  /// "Zaufaj temu serwerowi" action, so the certificate can be confirmed from
  /// the account tab (any server-touching path) rather than only at login.
  Widget _untrustedServerBlock() => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: sidebar,
      border: Border.all(color: line),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('ODCISK KLUCZA (SPKI)', 'KEY FINGERPRINT (SPKI)'),
          style: TextStyle(fontSize: 11, letterSpacing: 1.3, color: muted),
        ),
        const SizedBox(height: 8),
        SelectableText(
          spkiDisplay(_untrustedCert!.spki),
          key: const Key('account-trust-spki'),
          contextMenuBuilder: siliqueTextContextMenu,
          style: const TextStyle(
            fontFamily: kMonoFontFamily,
            fontFamilyFallback: ['monospace'],
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          tr(
            'Silique nie może potwierdzić tożsamości tego serwera. Zweryfikuj odcisk i zaufaj serwerowi, aby odświeżyć listę urządzeń.',
            'Silique cannot confirm the identity of this server. Verify the fingerprint and trust the server to refresh the device list.',
          ),
          style: const TextStyle(color: muted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const Key('account-trust-server'),
          onPressed: busy ? null : _trustServer,
          child: Text(tr('Zaufaj temu serwerowi', 'Trust this server')),
        ),
      ],
    ),
  );

  Future<void> connect() => run(() async {
    // A self-signed server must be confirmable instead of fatal: the pin is
    // stored once, the attempt is retried exactly once, and every later
    // connection goes through the same badCertificateCallback.
    final base = SiliqueApi.validateServer(server.text);
    final key = await connectTrustingServerCertificate<String?>(
      context: context,
      trust: repo.trust,
      base: base,
      attempt: () => repo.connect(
        server.text,
        email.text,
        password.text,
        register: register,
        recoveryKey: recovery.text,
      ),
    );
    password.clear();
    recovery.clear();
    if (key != null && mounted) await showRecovery(context, key);
    await _serverAction(() => repo.sync());
    await _serverAction(() => repo.refreshDevices());
    if (mounted) {
      final keysLocked = repo.accountKey == null;
      setState(
        () => message = () => keysLocked
            ? tr(
                'Konto zalogowane. Odblokuj klucze przez parowanie lub klucz odzyskiwania.',
                'Signed in. Unlock the keys by pairing or using a recovery key.',
              )
            : tr(
                'Konto połączone. Włącz synchronizację wybranych vaultów poniżej.',
                'Account connected. Enable syncing for your chosen vaults below.',
              ),
      );
    }
  });
  Future<void> refreshPairing() => run(() => _serverAction(() async {
    pairingRequests = await repo.pairings();
    if (repo.accountKey == null) {
      final own = pairingRequests
          .where((p) => p['requesterId'] == repo.deviceId)
          .firstOrNull;
      if (own != null && own['approverKey'] != null) {
        safetyCode = (await repo.pairingDetails(own)).code;
        if (await repo.finishPairing(own)) {
          await repo.sync();
          message = () => tr(
            'Urządzenie sparowane. Notatki są odblokowane.',
            'Device paired. Notes are unlocked.',
          );
          safetyCode = null;
        }
      }
    }
  }));
  Future<void> approve(Json request) => run(() => _serverAction(() async {
    final offered = request['approverId'] == null
        ? await repo.offerPairing(request)
        : request;
    final code = (await repo.pairingDetails(offered)).code;
    if (!mounted) return;
    var compared = false;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ListenableBuilder(
        listenable: appLanguage,
        builder: (ctx, _) => StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: Text(
              tr(
                'Porównaj kody na obu urządzeniach',
                'Compare the codes on both devices',
              ),
            ),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr(
                      'Na nowym urządzeniu naciśnij „Odśwież parowanie”. Oba urządzenia muszą wyświetlać dokładnie ten sam pełny kod. Dopiero wtedy udostępnij klucz konta.',
                      'Press “Refresh pairing” on the new device. Both devices must display exactly the same full code. Only then share the account key.',
                    ),
                  ),
                  const SizedBox(height: 20),
                  SelectableText(
                    code,
                    contextMenuBuilder: siliqueTextContextMenu,
                    style: const TextStyle(
                      fontFamily: kMonoFontFamily,
                      fontFamilyFallback: ['monospace'],
                      fontSize: 20,
                      color: accent,
                    ),
                  ),
                  const SizedBox(height: 16),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: compared,
                    onChanged: (v) => setState(() => compared = v ?? false),
                    title: Text(
                      tr(
                        'Porównałem pełny kod — jest identyczny',
                        'I have compared the full code — it is identical',
                      ),
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr('Anuluj', 'Cancel')),
              ),
              FilledButton(
                onPressed: compared ? () => Navigator.pop(ctx, true) : null,
                child: Text(tr('Zatwierdź urządzenie', 'Approve device')),
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed == true) {
      await repo.approvePairing(offered);
      message = () => tr(
        'Klucz przekazany w zaszyfrowanej kopercie. Odśwież parowanie na nowym urządzeniu.',
        'Key sent in an encrypted envelope. Refresh pairing on the new device.',
      );
    }
  }));
  Widget pairingSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 16),
      const Divider(),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: Text(
              tr('PAROWANIE URZĄDZEŃ', 'DEVICE PAIRING'),
              style: TextStyle(fontSize: 11, letterSpacing: 1.3, color: muted),
            ),
          ),
          TextButton(
            onPressed: busy ? null : refreshPairing,
            child: Text(tr('Odśwież parowanie', 'Refresh pairing')),
          ),
        ],
      ),
      if (repo.accountKey == null) ...[
        Text(
          tr(
            'Na odblokowanym urządzeniu otwórz Ustawienia → Parowanie urządzeń, odśwież listę i wybierz to urządzenie.',
            'On an unlocked device, open Settings → Device pairing, refresh the list and select this device.',
          ),
          style: TextStyle(color: muted, fontSize: 12),
        ),
        if (safetyCode != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: SelectableText(
              safetyCode!,
              contextMenuBuilder: siliqueTextContextMenu,
              style: const TextStyle(
                fontFamily: kMonoFontFamily,
                fontFamilyFallback: ['monospace'],
                fontSize: 20,
                color: accent,
              ),
            ),
          ),
        TextButton(
          onPressed: busy ? null : () => run(() => _serverAction(repo.startPairing)),
          child: Text(
            tr(
              'Rozpocznij parowanie ponownie (ważne 10 minut)',
              'Restart pairing (valid for 10 minutes)',
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          contextMenuBuilder: siliqueTextContextMenu,
          controller: recovery,
          obscureText: true,
          decoration: InputDecoration(
            labelText: tr(
              'Lub użyj klucza odzyskiwania konta',
              'Or use the account recovery key',
            ),
          ),
        ),
        TextButton(
          onPressed: busy
              ? null
              : () => run(() => _serverAction(() async {
                  await repo.recoverAccount(recovery.text);
                  recovery.clear();
                  await repo.sync();
                  message = () => tr('Konto odblokowane.', 'Account unlocked.');
                })),
          child: Text(
            tr('Odblokuj kluczem odzyskiwania', 'Unlock with recovery key'),
          ),
        ),
      ] else ...[
        Text(
          tr(
            'Nowe urządzenie otrzyma klucz konta po porównaniu kodu. Hasła chronionych vaultów nadal są wymagane.',
            'The new device will receive the account key after the code is compared. Passwords for protected vaults are still required.',
          ),
          style: TextStyle(color: muted, fontSize: 12),
        ),
        for (final p in pairingRequests.where(
          (p) =>
              p['requesterId'] != repo.deviceId &&
              p['envelope'] == null &&
              (p['approverId'] == null || p['approverId'] == repo.deviceId),
        ))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.phonelink_lock),
            title: Text(
              tr(
                'Urządzenie ${(p['requesterId'] as String).substring(0, 8)}',
                'Device ${(p['requesterId'] as String).substring(0, 8)}',
              ),
              style: const TextStyle(fontSize: 13),
            ),
            trailing: TextButton(
              onPressed: busy ? null : () => approve(p),
              child: Text(tr('Porównaj kod', 'Compare code')),
            ),
          ),
      ],
    ],
  );

  CredentialModeControl? get credentialControl {
    final keys = repo.keys;
    return keys is CredentialModeControl ? keys as CredentialModeControl : null;
  }

  Future<void> changeCredentialMode(CredentialMode target) async {
    final control = credentialControl;
    if (control == null ||
        busy ||
        control.cleanupPending ||
        control.mode == target) {
      return;
    }
    await run(() async {
      if (target == CredentialMode.local) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => ListenableBuilder(
            listenable: appLanguage,
            builder: (ctx, _) => AlertDialog(
              scrollable: true,
              title: Text(
                tr(
                  'Przenieść klucze do lokalnego pliku?',
                  'Move keys to a local file?',
                ),
              ),
              content: const LocalCredentialWarning(),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(tr('Anuluj', 'Cancel')),
                ),
                FilledButton(
                  key: const Key('credential-confirm-local'),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(
                    tr(
                      'Rozumiem ryzyko — użyj lokalnego pliku',
                      'I understand the risk — use a local file',
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        if (confirmed != true || !mounted) return;
      }
      await control.changeMode(target);
    });
  }

  Widget credentialSection(CredentialModeControl control) => Padding(
    padding: const EdgeInsets.only(top: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr(
            'Aktualnie: ${credentialModeLabel(control.mode)}',
            'Current: ${credentialModeLabel(control.mode)}',
          ),
          key: const Key('credential-current-mode'),
        ),
        const SizedBox(height: 12),
        CredentialModePicker(
          mode: control.mode,
          onChanged: busy || control.cleanupPending
              ? null
              : changeCredentialMode,
        ),
        if (control.cleanupPending) ...[
          const SizedBox(height: 12),
          Text(
            tr(
              'Usuwanie kopii w poprzednim magazynie nie zostało zakończone. Aktywny tryb jest pokazany powyżej. Dokończ porządkowanie przed kolejną zmianą.',
              'Removal of the copy in the previous store is incomplete. The active mode is shown above. Finish cleanup before making another change.',
            ),
            style: TextStyle(color: Colors.orangeAccent, height: 1.5),
          ),
          TextButton(
            key: const Key('credential-retry-cleanup'),
            onPressed: busy ? null : () => run(control.retryCleanup),
            child: Text(
              tr(
                'Ponów usuwanie poprzedniej kopii',
                'Retry removing the previous copy',
              ),
            ),
          ),
        ],
      ],
    ),
  );

  Future<void> createHiddenPassword() async {
    final value = await askHiddenPassword(context, create: true);
    if (value == null) return;
    await run(() async {
      await repo.setHiddenPassword(value);
      message = () =>
          tr('Hasło ukrytych notatek ustawione.', 'Hidden notes password set.');
    });
  }

  Future<void> unlockHiddenNotes() async {
    final value = await askHiddenPassword(context, create: false);
    if (value == null) return;
    await run(() async {
      if (await repo.unlockHidden(value)) {
        message = () =>
            tr('Ukryte notatki odblokowane.', 'Hidden notes unlocked.');
      } else {
        throw FormatException(
          tr('Nieprawidłowe hasło.', 'Incorrect password.'),
        );
      }
    });
  }

  Widget hiddenSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 20),
      Text(
        tr('UKRYTE NOTATKI', 'HIDDEN NOTES'),
        style: TextStyle(fontSize: 11, letterSpacing: 1.3, color: muted),
      ),
      const SizedBox(height: 8),
      Text(
        !repo.hiddenPasswordSet
            ? tr(
                'Ustaw osobne hasło, aby ukryć pierwszą notatkę. Treść jest dodatkowo szyfrowana tym hasłem; hasło nie jest wysyłane na serwer.',
                'Set a separate password to hide your first note. Content is additionally encrypted with this password; the password is not sent to the server.',
              )
            : repo.hiddenUnlocked
            ? tr(
                'Odblokowane — otwórz sekcję „Ukryte”. Notatki synchronizują się wyłącznie jako dodatkowo zaszyfrowana treść.',
                'Unlocked — open the “Hidden” section. Notes sync only as additionally encrypted content.',
              )
            : tr(
                'Zablokowane hasłem. Treść pozostaje zaszyfrowana na dysku i w synchronizacji.',
                'Password locked. Content remains encrypted on disk and during sync.',
              ),
        style: const TextStyle(color: muted, fontSize: 12),
      ),
      const SizedBox(height: 10),
      Wrap(
        children: [
          if (!repo.hiddenPasswordSet)
            FilledButton.icon(
              key: const Key('hidden-create-password'),
              onPressed: busy ? null : createHiddenPassword,
              icon: const Icon(Icons.lock_outline, size: 17),
              label: Text(tr('Utwórz hasło', 'Create password')),
            )
          else if (!repo.hiddenUnlocked)
            FilledButton.icon(
              key: const Key('hidden-unlock'),
              onPressed: busy ? null : unlockHiddenNotes,
              icon: const Icon(Icons.lock_open, size: 17),
              label: Text(tr('Odblokuj', 'Unlock')),
            )
          else
            TextButton.icon(
              key: const Key('hidden-lock'),
              onPressed: () async {
                await repo.lockHidden();
                if (!mounted) return;
                widget.onChanged();
                setState(() {});
              },
              icon: const Icon(Icons.lock, size: 17),
              label: Text(tr('Zablokuj teraz', 'Lock now')),
            ),
        ],
      ),
      if (repo.hiddenPasswordSet) ...[
        const SizedBox(height: 8),
        SiliqueChoice<Duration?>(
          key: const Key('hidden-auto-lock'),
          value: _autoLockValue,
          decoration: InputDecoration(
            labelText: tr('Ponowne szyfrowanie', 'Re-encryption'),
          ),
          items: [
            for (final option in const [
              Duration(minutes: 1),
              Duration(minutes: 5),
              Duration(minutes: 15),
              null,
            ])
              SiliqueChoiceItem(
                value: option,
                icon: Icons.timer_outlined,
                child: Text(
                  option == null
                      ? tr(
                          'Przy wyjściu z sekcji / zamknięciu aplikacji',
                          'When leaving the section / closing the app',
                        )
                      : tr(
                          'Po ${option.inMinutes} min bez aktywności',
                          'After ${option.inMinutes} min of inactivity',
                        ),
                ),
              ),
          ],
          onChanged: busy
              ? null
              : (value) => run(() => repo.setHiddenAutoLock(value)),
        ),
        SwitchListTile(
          key: const Key('hidden-lock-background'),
          contentPadding: EdgeInsets.zero,
          value: repo.hiddenLockOnBackground,
          onChanged: busy
              ? null
              : (value) => run(() => repo.setHiddenLockOnBackground(value)),
          title: Text(
            tr(
              'Blokuj po przejściu aplikacji w tło',
              'Lock when the app goes into the background',
            ),
            style: TextStyle(fontSize: 12),
          ),
        ),
      ],
    ],
  );

  Duration? get _autoLockValue {
    final value = repo.hiddenAutoLock;
    const known = [
      Duration(minutes: 1),
      Duration(minutes: 5),
      Duration(minutes: 15),
    ];
    if (value == null) return null;
    return known.contains(value) ? value : Duration(minutes: 5);
  }

  @override
  Widget build(BuildContext context) {
    Localizations.localeOf(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620, maxHeight: 780),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 12, 10),
            child: Row(
              children: [
                const Icon(Icons.settings_outlined, color: accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    tr('Ustawienia', 'Settings'),
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  onPressed: busy ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                  tooltip: tr('Zamknij', 'Close'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Listener(
            onPointerSignal: _onTabBarPointerSignal,
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: {...ScrollConfiguration.of(context).dragDevices, PointerDeviceKind.mouse},
              ),
              child: TabBar(
                controller: _tabs,
                scrollController: _tabScroll,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  Tab(key: _generalTab, text: tr('Ogólne', 'General')),
                  Tab(key: _appearanceTab, text: tr('Wygląd', 'Appearance')),
                  Tab(
                    key: _accountTab,
                    text: tr('Konto i synchronizacja', 'Account & sync'),
                  ),
                  Tab(
                    key: _storageTab,
                    text: tr('Pamięć i bezpieczeństwo', 'Storage & security'),
                  ),
                  Tab(key: _updatesTab, text: tr('Aktualizacje', 'Updates')),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: TabBarView(
              controller: _tabs,
              children: [
                _SettingsTabPage(children: [const LanguagePicker()]),
                _SettingsTabPage(
                  children: [
                    Text(
                      tr('KOLORY', 'COLORS'),
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.3,
                        color: muted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _defaultNoteColorTile(),
                    _defaultFolderColorTile(),
                    const SizedBox(height: 24),
                    _compactModeTile(),
                  ],
                ),
                _SettingsTabPage(
                  children: [
                    Text(
                      tr('TWÓJ SERWER', 'YOUR SERVER'),
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.3,
                        color: muted,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (repo.session == null) ...[
                      Text(
                        tr(
                          'Synchronizuj na własnych zasadach',
                          'Sync on your own terms',
                        ),
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        tr(
                          'Notatki opuszczają urządzenie dopiero po zaszyfrowaniu. Hasło logowania i klucz odzyskiwania pełnią różne funkcje.',
                          'Notes leave your device only after encryption. Your sign-in password and recovery key serve different purposes.',
                        ),
                        style: TextStyle(color: muted),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        contextMenuBuilder: siliqueTextContextMenu,
                        controller: server,
                        keyboardType: TextInputType.url,
                        decoration: InputDecoration(
                          labelText: tr('Adres serwera', 'Server address'),
                          hintText: 'https://notes.example.com',
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        contextMenuBuilder: siliqueTextContextMenu,
                        controller: email,
                        keyboardType: TextInputType.emailAddress,
                        decoration: InputDecoration(
                          labelText: tr('E-mail', 'Email'),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        contextMenuBuilder: siliqueTextContextMenu,
                        controller: password,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: tr(
                            'Hasło logowania (min. 12 znaków)',
                            'Sign-in password (at least 12 characters)',
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      if (!register)
                        TextField(
                          contextMenuBuilder: siliqueTextContextMenu,
                          controller: recovery,
                          obscureText: true,
                          decoration: InputDecoration(
                            labelText: tr(
                              'Klucz odzyskiwania konta',
                              'Account recovery key',
                            ),
                            hintText: tr(
                              'Wymagany na nowym urządzeniu',
                              'Required on a new device',
                            ),
                          ),
                        ),
                      const SizedBox(height: 16),
                      OverflowBar(
                        spacing: 8,
                        overflowSpacing: 8,
                        overflowAlignment: OverflowBarAlignment.start,
                        children: [
                          FilledButton(
                            onPressed: busy ? null : connect,
                            child: Text(
                              register
                                  ? tr('Utwórz konto', 'Create account')
                                  : tr('Połącz konto', 'Connect account'),
                            ),
                          ),
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => setState(() => register = !register),
                            child: Text(
                              register
                                  ? tr('Mam konto', 'I have an account')
                                  : tr('Rejestracja', 'Register'),
                            ),
                          ),
                        ],
                      ),
                    ] else ...[
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: sidebar,
                          border: Border.all(color: line),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.cloud_done_outlined,
                              color: Color(0xff75e4b0),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(repo.session!.email),
                                  Text(
                                    repo.session!.server,
                                    style: const TextStyle(
                                      color: muted,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: busy
                            ? null
                            : () => run(() async {
                                await repo.disconnect();
                                devices = null;
                                _untrustedCert = null;
                              }),
                        icon: const Icon(Icons.logout, size: 17),
                        label: Text(tr('Wyloguj konto', 'Sign out')),
                      ),
                      if (_untrustedCert != null) ...[
                        const SizedBox(height: 12),
                        _untrustedServerBlock(),
                      ],
                      pairingSection(),
                      const SizedBox(height: 20),
                      Text(
                        tr('SYNCHRONIZOWANE VAULTY', 'SYNCED VAULTS'),
                        style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 1.3,
                          color: muted,
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final v in repo.vaults)
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: v.syncEnabled,
                          onChanged:
                              busy ||
                                  v.owner != null &&
                                      v.owner != repo.session!.owner
                              ? null
                              : (enabled) => run(() => _serverAction(() async {
                                  if (enabled) {
                                    await repo.enableSync(v);
                                    await repo.sync();
                                  } else {
                                    v.syncEnabled = false;
                                    repo.storage.putVault(v);
                                  }
                                })),
                          title: Text(
                            v.name,
                            style: const TextStyle(fontSize: 14),
                          ),
                          subtitle: Text(
                            v.protected
                                ? tr(
                                    'Dodatkowe hasło • odblokuj przed synchronizacją',
                                    'Additional password • unlock before syncing',
                                  )
                                : tr(
                                    'Klucz konta • szyfrowanie E2EE',
                                    'Account key • E2EE encryption',
                                  ),
                            style: const TextStyle(color: muted, fontSize: 11),
                          ),
                        ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              tr('URZĄDZENIA', 'DEVICES'),
                              style: TextStyle(
                                fontSize: 11,
                                letterSpacing: 1.3,
                                color: muted,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => run(() => _serverAction(repo.refreshDevices)),
                            child: Text(tr('Odśwież', 'Refresh')),
                          ),
                        ],
                      ),
                      if (devices != null)
                        for (final device in devices!)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.devices_outlined),
                            title: Text(
                              '${device['name']}${device['id'] == repo.deviceId ? tr(' (to urządzenie)', ' (this device)') : ''}',
                              style: const TextStyle(fontSize: 13),
                            ),
                            subtitle: Text(
                              '${(device['id'] as String).substring(0, 8)} • ${device['revoked'] == 1 ? tr('dostęp cofnięty', 'access revoked') : tr('aktywne', 'active')}',
                              style: const TextStyle(fontSize: 11),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (device['revoked'] != 1 &&
                                    device['id'] == repo.deviceId)
                                  IconButton(
                                    key: const Key('device-rename'),
                                    tooltip: tr(
                                      'Zmień nazwę tego urządzenia',
                                      'Rename this device',
                                    ),
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      size: 18,
                                    ),
                                    onPressed: busy
                                        ? null
                                        : () async {
                                            final name = await askText(
                                              context,
                                              '',
                                              titleBuilder: () => tr(
                                                'Nazwa tego urządzenia',
                                                'This device’s name',
                                              ),
                                              initial:
                                                  device['name'] as String? ??
                                                  '',
                                              hintBuilder: () => tr(
                                                '1–80 znaków',
                                                '1–80 characters',
                                              ),
                                            );
                                            if (name == null) return;
                                            await run(() => _serverAction(() async {
                                              final saved = await repo
                                                  .renameDevice(
                                                    device['id'] as String,
                                                    name,
                                                  );
                                              await repo.refreshDevices();
                                              message = () => tr(
                                                'Nazwa urządzenia zapisana na serwerze: $saved',
                                                'Device name saved on the server: $saved',
                                              );
                                            }));
                                          },
                                  ),
                                if (device['revoked'] != 1)
                                  IconButton(
                                    tooltip: tr(
                                      'Cofnij dostęp',
                                      'Revoke access',
                                    ),
                                    icon: const Icon(Icons.block, size: 18),
                                    onPressed: busy
                                        ? null
                                        : () => run(() => _serverAction(() async {
                                            final confirmed = await showDialog<bool>(
                                              context: context,
                                              builder: (ctx) => ListenableBuilder(
                                                listenable: appLanguage,
                                                builder: (ctx, _) => AlertDialog(
                                                  title: Text(
                                                    tr(
                                                      'Cofnąć dostęp urządzeniu?',
                                                      'Revoke device access?',
                                                    ),
                                                  ),
                                                  content: Text(
                                                    tr(
                                                      'Urządzenie utraci synchronizację. Wcześniej pobrane dane pozostaną na nim.',
                                                      'The device will lose sync access. Previously downloaded data will remain on it.',
                                                    ),
                                                  ),
                                                  actions: [
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                            ctx,
                                                            false,
                                                          ),
                                                      child: Text(
                                                        tr('Anuluj', 'Cancel'),
                                                      ),
                                                    ),
                                                    FilledButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                            ctx,
                                                            true,
                                                          ),
                                                      child: Text(
                                                        tr(
                                                          'Cofnij dostęp',
                                                          'Revoke access',
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            );
                                            if (confirmed != true) return;
                                            await repo.api!.request(
                                              'DELETE',
                                              '/v1/devices/${device['id']}',
                                            );
                                            if (device['id'] == repo.deviceId) {
                                              await repo.disconnect();
                                              devices = null;
                                            } else {
                                              devices = devices
                                                  ?.where(
                                                    (entry) =>
                                                        entry['id'] !=
                                                        device['id'],
                                                  )
                                                  .toList();
                                            }
                                          })),
                                  ),
                              ],
                            ),
                          ),
                    ],
                  ],
                ),
                _SettingsTabPage(
                  children: [
                    if (credentialControl case final control?)
                      credentialSection(control),
                    hiddenSection(),
                    const SizedBox(height: 28),
                    const Divider(),
                    const SizedBox(height: 14),
                    Text(
                      tr('MIEJSCE DANYCH', 'DATA LOCATION'),
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.3,
                        color: muted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      repo.dataLocation,
                      contextMenuBuilder: siliqueTextContextMenu,
                      key: const Key('data-location'),
                      style: const TextStyle(fontSize: 11, color: muted),
                    ),
                    if (widget.onMoveStorage != null)
                      TextButton.icon(
                        key: const Key('move-storage-settings'),
                        onPressed: busy ? null : widget.onMoveStorage,
                        icon: const Icon(
                          Icons.drive_file_move_outlined,
                          size: 18,
                        ),
                        label: Text(
                          tr('Zmień miejsce zapisu', 'Change storage location'),
                        ),
                      ),
                    if (NativeStorage.defaultLocationWarning != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          NativeStorage.defaultLocationWarning!,
                          key: const Key('data-location-warning'),
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.orangeAccent,
                          ),
                        ),
                      ),
                    if (widget.serverTrust != null &&
                        widget.serverBase != null)
                      TrustedServerCertSection(
                        trust: widget.serverTrust!,
                        base: widget.serverBase!,
                        onChanged: widget.onChanged,
                      ),
                  ],
                ),
                _SettingsTabPage(
                  children: [
                    if (widget.updater != null)
                      KeyedSubtree(
                        key: const Key('updates-section'),
                        child: UpdatesPanel(
                          updater: widget.updater!,
                          beforeInstall: widget.beforeUpdate ?? () async {},
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          // Operation feedback stays visible under the tabs no matter which
          // tab the running action belongs to.
          if (error != null || message != null || busy)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (error != null)
                    SelectableText(
                      error!,
                      contextMenuBuilder: siliqueTextContextMenu,
                      style: const TextStyle(color: Colors.orangeAccent),
                    ),
                  if (message != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        message!(),
                        style: const TextStyle(color: Color(0xff75e4b0)),
                      ),
                    ),
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 14),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// The vault the compact-mode switch edits; `null` keeps the switch
  /// disabled (no current vault, or its metadata is still locked).
  Vault? get _compactVault {
    final vault = widget.vault;
    if (vault == null || !repo.unlocked.containsKey(vault.id)) return null;
    return vault;
  }

  String _hexText(int argb) {
    final rgb = argb & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  Widget _colorSwatch(int? argb) => Container(
    width: 22,
    height: 22,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: argb == null ? Colors.transparent : Color(argb),
      border: Border.all(color: argb == null ? Colors.white38 : Colors.white24),
    ),
    child: argb == null
        ? const Icon(Icons.block, size: 12, color: Colors.white38)
        : null,
  );

  Widget _defaultNoteColorTile() {
    final target = _compactVault;
    final argb = target == null
        ? kDefaultNoteColor
        : repo.defaultNoteColorOf(target.id);
    return ListTile(
      key: const Key('appearance-default-note-color'),
      contentPadding: EdgeInsets.zero,
      leading: _colorSwatch(argb),
      title: Text(tr('Domyślny kolor nowych notatek', 'Default note color')),
      subtitle: Text(_hexText(argb)),
      onTap: busy || target == null ? null : () => _pickDefaultNoteColor(),
    );
  }

  Widget _defaultFolderColorTile() {
    final target = _compactVault;
    final argb = target == null ? null : repo.defaultFolderColorOf(target.id);
    return ListTile(
      key: const Key('appearance-default-folder-color'),
      contentPadding: EdgeInsets.zero,
      leading: _colorSwatch(argb),
      title: Text(tr('Domyślny kolor folderów', 'Default folder color')),
      subtitle: Text(
        argb == null ? tr('Brak koloru', 'No color') : _hexText(argb),
      ),
      onTap: busy || target == null ? null : () => _pickDefaultFolderColor(),
    );
  }

  /// Opens the shared visual picker for the default note color. "No color"
  /// resets the preference to the built-in fallback (notes always have a
  /// concrete default). After saving, asks whether to repaint existing notes.
  Future<void> _pickDefaultNoteColor() async {
    final target = _compactVault;
    if (target == null) return;
    final current = repo.defaultNoteColorOf(target.id);
    final result = await showVisualColorPicker(
      context,
      initial: Color(current),
      title: tr('Domyślny kolor notatek', 'Default note color'),
    );
    if (result == null || !mounted) return;
    final argb = switch (result) {
      VisualColorValue(:final color) => color.toARGB32(),
      VisualColorClear() => kDefaultNoteColor,
    };
    await run(() => repo.setDefaultNoteColor(target, argb));
    if (!mounted) return;
    final apply = await _askApplyExisting(
      title: tr('Zmień kolor istniejących notatek?', 'Change existing notes?'),
      description: tr(
        '„Tak” usunie indywidualne kolory notatek, aby wszystkie przyjęły nowy domyślny kolor. „Nie” zachowa dotychczasowe kolory — nowa wartość obejmie tylko notatki bez własnego koloru.',
        '"Yes" clears individual note colors so every note adopts the new default. "No" keeps the existing colors — the new default only applies to notes without their own color.',
      ),
    );
    if (apply) await run(() => repo.clearNoteColors(target));
  }

  /// Opens the shared visual picker for the default folder color; "no color"
  /// clears the preference so folders keep their colorless look. After saving,
  /// asks whether to repaint existing folders.
  Future<void> _pickDefaultFolderColor() async {
    final target = _compactVault;
    if (target == null) return;
    final current = repo.defaultFolderColorOf(target.id);
    final result = await showVisualColorPicker(
      context,
      initial: current == null ? null : Color(current),
      title: tr('Domyślny kolor folderów', 'Default folder color'),
    );
    if (result == null || !mounted) return;
    final argb = switch (result) {
      VisualColorValue(:final color) => color.toARGB32(),
      VisualColorClear() => null,
    };
    await run(() => repo.setDefaultFolderColor(target, argb));
    if (!mounted) return;
    final apply = await _askApplyExisting(
      title: tr(
        'Zmień kolor istniejących folderów?',
        'Change existing folders?',
      ),
      description: tr(
        '„Tak” usunie indywidualne kolory folderów, aby wszystkie przyjęły nowy domyślny kolor. „Nie” zachowa dotychczasowe kolory — nowa wartość obejmie tylko foldery bez własnego koloru.',
        '"Yes" clears individual folder colors so every folder adopts the new default. "No" keeps the existing colors — the new default only applies to folders without their own color.',
      ),
    );
    if (apply) await run(() => repo.clearFolderColors(target));
  }

  /// Asks whether a newly saved default color should also repaint existing
  /// elements. Resolves `true` for "yes", `false` for "no" or dismissal.
  Future<bool> _askApplyExisting({
    required String title,
    required String description,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(description),
        actions: [
          TextButton(
            key: const Key('apply-existing-no'),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Nie, tylko nowe', 'No, only new')),
          ),
          FilledButton(
            key: const Key('apply-existing-yes'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Tak, zmień istniejące', 'Yes, change existing')),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Widget _compactModeTile() {
    final target = _compactVault;
    return SwitchListTile(
      key: const Key('compact-mode-toggle'),
      contentPadding: EdgeInsets.zero,
      value: target != null && repo.compactModeOf(target.id),
      onChanged: busy || target == null
          ? null
          : (value) => run(() => repo.setCompactMode(target, value)),
      title: Text(
        tr('Tryb kompaktowy', 'Compact mode'),
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          tr(
            'Łączy listę folderów i listę notatek w jedną hierarchiczną listę — notatki są widoczne bezpośrednio w swoich folderach i podfolderach.',
            'Merges the folder list and the note list into one hierarchical list — notes appear directly inside their folders and subfolders.',
          ),
          style: const TextStyle(color: muted, fontSize: 12, height: 1.4),
        ),
      ),
    );
  }
}

/// A scrollable settings tab page that stays alive once visited, so its
/// fields, scroll offset and element states survive tab switches and the
/// language rebuilds of the open dialog.
class _SettingsTabPage extends StatefulWidget {
  const _SettingsTabPage({required this.children});
  final List<Widget> children;
  @override
  State<_SettingsTabPage> createState() => _SettingsTabPageState();
}

class _SettingsTabPageState extends State<_SettingsTabPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: widget.children,
      ),
    );
  }
}

/// Asks for a folder name relative to [parent] and returns the full path.
///
/// Empty, traversal and colliding names are rejected before the dialog closes,
/// so a failed validation never creates a half-working folder.
Future<String?> askFolderName(
  BuildContext context, {
  String parent = '',
  required Iterable<String> existing,
  String? title,
  String Function()? titleBuilder,
}) async {
  final controller = TextEditingController();
  var showError = false;
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: appLanguage,
      builder: (ctx, _) => StatefulBuilder(
        builder: (ctx, setState) {
          String? validate() {
            final raw = controller.text.trim();
            if (raw.isEmpty) {
              return tr('Podaj nazwę folderu.', 'Enter a folder name.');
            }
            if (raw.contains('/')) {
              return tr(
                'Nazwa podfolderu nie zawiera znaku /.',
                'A subfolder name cannot contain /.',
              );
            }
            final path = joinFolderPath(parent, raw);
            final message = folderPathError(path);
            if (message != null) return message;
            if (folderPathCollides(path, existing)) {
              return tr(
                'Folder o tej nazwie już istnieje.',
                'A folder with this name already exists.',
              );
            }
            return null;
          }

          final error = showError ? validate() : null;
          return AlertDialog(
            title: Text(
              titleBuilder?.call() ?? title ?? tr('Nowy folder', 'New folder'),
            ),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (parent.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        tr('W folderze: $parent', 'In folder: $parent'),
                        style: const TextStyle(color: muted, fontSize: 12),
                      ),
                    ),
                  TextField(
                    contextMenuBuilder: siliqueTextContextMenu,
                    key: const Key('folder-name'),
                    controller: controller,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: tr('np. Mercaro', 'e.g. Mercaro'),
                    ),
                    onChanged: (_) => setState(() => showError = true),
                    onSubmitted: (_) {
                      final message = validate();
                      if (message != null) {
                        setState(() => showError = true);
                        return;
                      }
                      Navigator.pop(
                        ctx,
                        joinFolderPath(parent, controller.text),
                      );
                    },
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        error,
                        style: const TextStyle(
                          color: Colors.orangeAccent,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('Anuluj', 'Cancel')),
              ),
              FilledButton(
                key: const Key('folder-create'),
                onPressed: () {
                  final message = validate();
                  if (message != null) {
                    setState(() => showError = true);
                    return;
                  }
                  Navigator.pop(ctx, joinFolderPath(parent, controller.text));
                },
                child: Text(tr('Utwórz', 'Create')),
              ),
            ],
          );
        },
      ),
    ),
  );
  Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
  return result;
}

/// Chooses an existing destination; `''` means all notes at the vault root.
/// [initial] is retained for existing callers; each picker starts at the root.
Future<String?> chooseTargetFolder(
  BuildContext context, {
  required List<String> folders,
  String initial = '',
  String? sourceFolder,
  Map<String, int> folderColors = const {},
}) async {
  final search = TextEditingController();
  var selected = '';
  bool allowed(String parent) {
    final source = sourceFolder;
    if (source == null) return true;
    if (isSameOrDescendantPath(parent.toLowerCase(), source.toLowerCase())) {
      return false;
    }
    final destination = joinFolderPath(parent, folderName(source));
    if (destination.toLowerCase() == source.toLowerCase()) return false;
    for (final path in folders.where(
      (path) => isSameOrDescendantPath(path, source),
    )) {
      if (folderPathError(replacePathPrefix(path, source, destination)) !=
          null) {
        return false;
      }
    }
    return folderPathError(destination) == null &&
        folderMoveCollision(from: source, to: destination, existing: folders) ==
            null;
  }

  final paths = folders.toSet().toList()
    ..sort((a, b) {
      final left = a.split('/');
      final right = b.split('/');
      for (var i = 0; i < left.length && i < right.length; i++) {
        final order = left[i].toLowerCase().compareTo(right[i].toLowerCase());
        if (order != 0) return order;
      }
      return left.length.compareTo(right.length);
    });
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: appLanguage,
      builder: (ctx, _) => StatefulBuilder(
        builder: (ctx, setState) {
          final query = search.text.trim().toLowerCase();
          return AlertDialog(
            scrollable: true,
            title: Text(tr('Przenieś do folderu', 'Move to folder')),
            content: SizedBox(
              width: 460,
              height: 380,
              child: Column(
                children: [
                  TextField(
                    contextMenuBuilder: siliqueTextContextMenu,
                    key: const Key('folder-target-search'),
                    controller: search,
                    decoration: InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: tr('Szukaj folderu', 'Search folders'),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  if (selected.isNotEmpty &&
                      !selected.split('/').last.toLowerCase().contains(query))
                    Text(tr('Wybrano: $selected', 'Selected: $selected')),
                  Expanded(
                    child: ListView(
                      children: [
                        ListTile(
                          key: const Key('folder-target-root'),
                          minTileHeight: 48,
                          enabled: allowed(''),
                          iconColor: accent,
                          hoverColor: menuHover,
                          focusColor: menuHover,
                          selected: selected.isEmpty,
                          selectedColor: accent,
                          selectedTileColor: accent.withValues(alpha: .13),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          leading: const Icon(Icons.home_outlined, size: 18),
                          title: Text(tr('Wszystkie notatki', 'All notes')),
                          trailing: selected.isEmpty
                              ? const Icon(Icons.check, color: accent, size: 18)
                              : null,
                          onTap: allowed('')
                              ? () => setState(() => selected = '')
                              : null,
                        ),
                        const Divider(height: 16, color: menuBorder),
                        for (final folder in paths)
                          if (folder
                              .split('/')
                              .last
                              .toLowerCase()
                              .contains(query))
                            ListTile(
                              key: Key('folder-target-$folder'),
                              minTileHeight: 48,
                              enabled: allowed(folder),
                              iconColor: accent,
                              hoverColor: menuHover,
                              focusColor: menuHover,
                              selected: selected == folder,
                              selectedColor: accent,
                              selectedTileColor: accent.withValues(alpha: .13),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              contentPadding: EdgeInsets.only(
                                left:
                                    16 +
                                    (query.isEmpty
                                        ? (folder.split('/').length - 1) * 20.0
                                        : 0),
                                right: 16,
                              ),
                              // A saved folder accent wins over the tile's
                              // shared iconColor, matching the sidebar rows.
                              leading: Icon(
                                Icons.folder_outlined,
                                size: 18,
                                color: folderColors[folder] == null
                                    ? null
                                    : Color(folderColors[folder]!),
                              ),
                              title: Text(
                                folder.split('/').last,
                                style: const TextStyle(fontSize: 13),
                              ),
                              subtitle: query.isNotEmpty && folder.contains('/')
                                  ? Text(
                                      folder.substring(
                                        0,
                                        folder.lastIndexOf('/'),
                                      ),
                                    )
                                  : null,
                              trailing: selected == folder
                                  ? const Icon(
                                      Icons.check,
                                      color: accent,
                                      size: 18,
                                    )
                                  : null,
                              onTap: allowed(folder)
                                  ? () => setState(() => selected = folder)
                                  : null,
                            ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('Anuluj', 'Cancel')),
              ),
              FilledButton(
                key: const Key('folder-target-confirm'),
                onPressed: allowed(selected)
                    ? () => Navigator.pop(ctx, selected)
                    : null,
                child: Text(tr('Przenieś', 'Move')),
              ),
            ],
          );
        },
      ),
    ),
  );
  Future<void>.delayed(const Duration(seconds: 1), search.dispose);
  return result;
}

Future<bool> confirmAction(
  BuildContext context,
  String Function() title,
  String Function() message,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => ListenableBuilder(
        listenable: appLanguage,
        builder: (ctx, _) => AlertDialog(
          title: Text(title()),
          content: Text(message()),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Anuluj', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Potwierdź', 'Confirm')),
            ),
          ],
        ),
      ),
    ) ??
    false;
