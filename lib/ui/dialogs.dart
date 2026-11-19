import '../l10n/app_language.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/notebook.dart';
import '../services/api.dart';
import '../services/app_updates.dart';
import 'updates_panel.dart';
import 'language_picker.dart';
import '../core/models.dart';
import '../core/credential_mode.dart';
import '../core/device_settings.dart';
import '../core/shortcut_bindings.dart';
import 'credential_mode_picker.dart';
import '../core/server_trust.dart';
import '../core/templates.dart';
import '../core/system_folders.dart';
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
                      style: const TextStyle(color: warning),
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
                  style: const TextStyle(color: warning, fontSize: 12),
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
    this.widgetDiagnostics,
    this.pollInterval = const Duration(seconds: 2),
  });

  /// Viewport width (in logical pixels) at or above which the settings dialog
  /// uses the desktop two-column layout (sidebar + content); below it, the
  /// mobile list + drill-down. Shared by desktop and mobile builds so tests can
  /// drive the layout purely via the surface size.
  static const double desktopBreakpoint = 760;
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

  /// Loads the native Android widget diagnostics. Null on platforms without
  /// launcher widgets, which hides the diagnostics row entirely.
  final Future<String> Function()? widgetDiagnostics;
  final AppUpdater? updater;
  final Future<void> Function()? beforeUpdate;

  /// Interval between the silent account-tab poll cycles (`pairings()` +
  /// `refreshDevices()`). Tests shrink this to 20–50 ms; production uses 2 s.
  final Duration pollInterval;

  /// Open the dialog directly on the updates tab, so the update snackbar
  /// action never leaves the user searching the settings.
  final bool openUpdates;
  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  static const _generalTab = Key('settings-tab-general');
  static const _appearanceTab = Key('settings-tab-appearance');
  static const _shortcutsTab = Key('settings-tab-shortcuts');
  static const _accountTab = Key('settings-tab-account');
  static const _storageTab = Key('settings-tab-storage');
  static const _updatesTab = Key('settings-tab-updates');
  static const _updatesTabIndex = 5;

  /// A single settings section: its navigation key, sidebar/list icon and
  /// localized label. The order is the navigation order of the sections.
  List<_SectionSpec> get _sections => [
    _SectionSpec(_generalTab, Icons.tune, tr('Ogólne', 'General')),
    _SectionSpec(
      _appearanceTab,
      Icons.palette_outlined,
      tr('Wygląd', 'Appearance'),
    ),
    _SectionSpec(
      _shortcutsTab,
      Icons.keyboard_outlined,
      tr('Skróty', 'Shortcuts'),
    ),
    _SectionSpec(
      _accountTab,
      Icons.cloud_outlined,
      tr('Konto i synchronizacja', 'Account & sync'),
    ),
    _SectionSpec(
      _storageTab,
      Icons.storage_outlined,
      tr('Pamięć i bezpieczeństwo', 'Storage & security'),
    ),
    _SectionSpec(_updatesTab, Icons.update, tr('Aktualizacje', 'Updates')),
  ];

  final server = TextEditingController(),
      email = TextEditingController(),
      password = TextEditingController(),
      recovery = TextEditingController();

  /// The currently selected section index (`0..5`). Replaces the `TabBar` a
  /// `TabController` used to drive; the value is read from the sidebar (desktop)
  /// or the section list (mobile) instead of a tab strip.
  late int _section = widget.openUpdates ? _updatesTabIndex : 0;

  /// On mobile the open section index while a section is drilled into, or
  /// `null` while the section list is showing. `openUpdates` starts drilled
  /// into the updates section so the snackbar action lands there directly.
  late int? _mobileSection = widget.openUpdates ? _updatesTabIndex : null;

  bool register = false, busy = false;
  String? error;
  String Function()? message;
  List<Json>? get devices => repo.devices;
  set devices(List<Json>? value) => repo.devices = value;
  List<Json> pairingRequests = [];
  String? safetyCode;

  /// Silent account-tab polling. [pollInterval] drives [Timer] ticks; [_polling]
  /// guarantees no two runs overlap, [_pollFailures] defers surfacing a failure
  /// until three consecutive failures, and [_pairingStarted]/[_pairingComplete]
  /// guard the new-device pairing state machine so `startPairing` fires once per
  /// absence and pairing polling stops after the envelope is consumed.
  Timer? _pollTimer;
  bool _polling = false;
  int _pollFailures = 0;
  bool _pairingStarted = false;
  bool _finishingPairing = false;
  bool _pairingComplete = false;

  /// The certificate of the current server that has been presented but is not
  /// yet pinned, captured from the most recent [UntrustedServerCertificate].
  /// When non-null the account tab renders an inline "trust this server" block
  /// (with the SPKI fingerprint) instead of leaking the raw exception text.
  CertInfo? _untrustedCert;

  Notebook get repo => widget.notebook;

  /// The normalized base of the signed-in server, or null when signed out.
  Uri? get _trustBase => repo.session == null
      ? null
      : SiliqueApi.validateServer(repo.session!.server);
  @override
  void initState() {
    super.initState();
    appLanguage.addListener(_languageChanged);
    deviceSettings.addListener(_languageChanged);
    server.text = repo.session?.server ?? '';
    email.text = repo.session?.email ?? '';
    if (repo.session != null) unawaited(refreshDevices());
    _pollTimer = Timer.periodic(widget.pollInterval, (_) => unawaited(_poll()));
  }

  void _languageChanged() => setState(() {});

  @override
  void dispose() {
    _pollTimer?.cancel();
    appLanguage.removeListener(_languageChanged);
    deviceSettings.removeListener(_languageChanged);
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

  bool _ownerMismatch(Vault v) =>
      v.owner != null && vaultOwnerUserId(v.owner) != repo.session?.userId;

  bool _tombstoned(Vault v) => repo.syncIssues.any(
    (issue) => issue.vaultId == v.id && issue.reason == SyncIssue.tombstoned,
  );

  /// The tile subtitle for the "SYNCED VAULTS" switch. Ownership is provenance,
  /// not a sync gate: a mismatch is explained non-blockingly (the next sync
  /// re-binds the vault in place), and a tombstoned id is explained without
  /// resurrecting the deleted data.
  Widget _vaultSyncSubtitle(Vault v) {
    if (_tombstoned(v)) {
      return Text(
        tr(
          'Usunięty na serwerze — nie odtworzono automatycznie. Lokalne notatki pozostały bez zmian.',
          'Deleted on the server — not recreated automatically. Local notes were left unchanged.',
        ),
        style: const TextStyle(color: muted, fontSize: 11),
      );
    }
    if (_ownerMismatch(v)) {
      return Text(
        tr(
          'Przypisany do innego konta — synchronizacja przepnie vault do bieżącego konta.',
          'Bound to another account — syncing re-binds the vault to this account.',
        ),
        style: const TextStyle(color: muted, fontSize: 11),
      );
    }
    return Text(
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
    );
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
    // One retry: refreshPairing already refreshes the device list, so calling
    // refreshDevices first would issue a duplicate GET /v1/devices (and make
    // the "exactly one retry" contract in the tests untrue).
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
  Future<void> refreshPairing() => run(
    () => _serverAction(() async {
      pairingRequests = await repo.pairings();
      await repo.refreshDevices();
      await _processPairing();
    }),
  );

  /// The new-device pairing state machine, shared by the silent poll and the
  /// manual "Odśwież parowanie" fallback (and the reverse device-only refresh).
  ///
  /// A device that has not yet received its account key drives everything itself:
  ///  * no live own pairing row (never created, or since expired server-side) →
  ///    `startPairing()` once, guarded by [_pairingStarted] so a 2 s poll never
  ///    restarts it in a loop;
  ///  * own row has `approverKey` and no `envelope` → the comparison code is
  ///    derived and shown without any tap;
  ///  * own row has an `envelope` → `finishPairing()` + `sync()` once, then the
  ///    success message and pairing polling stops.
  ///
  /// The consent-dialog POST (`approvePairing`) is never reachable from here:
  /// auto-completion happens only on the requesting device after the server
  /// returns the envelope sealed by a human's approval on the key-holding device.
  Future<void> _processPairing() async {
    if (repo.accountKey != null || _pairingComplete || _finishingPairing) {
      return;
    }
    final own = pairingRequests
        .where((p) => p['requesterId'] == repo.deviceId)
        .firstOrNull;
    if (own == null) {
      if (!_pairingStarted) {
        _pairingStarted = true;
        await repo.startPairing();
      }
      return;
    }
    _pairingStarted = false;
    if (own['envelope'] != null) {
      _finishingPairing = true;
      try {
        final finished = await repo.finishPairing(own);
        if (finished) {
          await repo.sync();
          safetyCode = null;
          _pairingComplete = true;
          message = () => tr(
            'Urządzenie sparowane. Notatki są odblokowane.',
            'Device paired. Notes are unlocked.',
          );
        }
      } finally {
        _finishingPairing = false;
      }
      return;
    }
    if (own['approverKey'] != null) {
      safetyCode = (await repo.pairingDetails(own)).code;
    }
  }

  /// One silent poll cycle. It never sets [busy] (no spinner, no button lock),
  /// never touches [message], and surfaces [error] only after three consecutive
  /// failures. `UntrustedServerCertificate` is routed to the inline trust block
  /// by [_serverAction] and never reaches [error]/[message] as text.
  Future<void> _poll() async {
    if (_polling || busy || !mounted || repo.session == null) return;
    _polling = true;
    try {
      await _serverAction(() async {
        pairingRequests = await repo.pairings();
        await repo.refreshDevices();
        await _processPairing();
      });
      _pollFailures = 0;
      if (mounted) setState(() {});
    } catch (e) {
      _pollFailures++;
      if (_pollFailures >= 3 && mounted) {
        setState(() => error = '$e');
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> approve(Json request) => run(
    () => _serverAction(() async {
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
                        'Nowe urządzenie pokazuje ten sam kod automatycznie. Oba urządzenia muszą wyświetlać dokładnie ten sam pełny kod. Dopiero wtedy udostępnij klucz konta.',
                        'The new device shows the same code automatically. Both devices must display exactly the same full code. Only then share the account key.',
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
                      shape: hoverTileShape,
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
          'Klucz przekazany w zaszyfrowanej kopercie. Nowe urządzenie dokończy parowanie automatycznie.',
          'Key sent in an encrypted envelope. The new device will finish pairing automatically.',
        );
      }
    }),
  );
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
            'Na odblokowanym urządzeniu otwórz Ustawienia → Parowanie urządzeń i wybierz to urządzenie.',
            'On an unlocked device, open Settings → Device pairing and select this device.',
          ),
          style: TextStyle(color: muted, fontSize: 12),
        ),
        if (safetyCode != null) ...[
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              tr(
                'Porównaj ten kod na obu urządzeniach:',
                'Compare this code on both devices:',
              ),
              style: TextStyle(color: muted, fontSize: 12),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
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
        ],
        TextButton(
          onPressed: busy
              ? null
              : () => run(() => _serverAction(repo.startPairing)),
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
              : () => run(
                  () => _serverAction(() async {
                    await repo.recoverAccount(recovery.text);
                    recovery.clear();
                    await repo.sync();
                    message = () =>
                        tr('Konto odblokowane.', 'Account unlocked.');
                  }),
                ),
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
          _settingsRowGap(
            ListTile(
              // Informational row: no `onTap`, so no hover surface — but the
              // left inset matches every clickable settings row so the section
              // keeps one text edge.
              contentPadding: settingsItemPadding,
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
            style: TextStyle(color: warning, height: 1.5),
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
        _settingsRowGap(
          SwitchListTile(
            key: const Key('hidden-lock-background'),
            contentPadding: settingsItemPadding,
            shape: settingsItemShape,
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
    // Choose the layout from the space the panel actually got, not from the
    // window: a modal can be laid out narrower than the window (inset padding,
    // a centered dialog, a test surface). The desktop breakpoint then matches
    // what the two-column layout really has to work with.
    return LayoutBuilder(
      builder: (context, constraints) {
        final media = MediaQuery.sizeOf(context);
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : media.width;
        final height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : media.height;
        final desktop = width >= SettingsPanel.desktopBreakpoint;
        // On desktop the settings dialog widens to a roomy two-column layout; on
        // mobile it keeps the compact single-column list / drill-down. The height
        // mirror: 86% of the window, clamped to a sensible minimum so a short
        // window still shows a usable panel.
        final maxWidth = desktop ? (width - 64).clamp(720.0, 1180.0) : 620.0;
        final maxHeight = desktop ? height * 0.86 : 780.0;
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
          // Fill the available width: a bare Column would shrink-wrap to its widest
          // intrinsic child (the header row) when the parent gives loose width.
          child: SizedBox(
            width: double.infinity,
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
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                          ),
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
                Flexible(child: desktop ? _desktopLayout() : _mobileLayout()),
                // Operation feedback stays visible under the sections no matter which
                // section the running action belongs to.
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
                            style: const TextStyle(color: warning),
                          ),
                        if (message != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              message!(),
                              style: const TextStyle(color: success),
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
          ),
        );
      },
    );
  }

  /// The six section pages, one per navigation entry. Kept as a single list so
  /// the desktop sidebar (`IndexedStack`) and the mobile drill-down render the
  /// exact same content; `_SettingsTabPage` keeps each page's scroll offset and
  /// field state alive across section switches, exactly as the `TabBarView`
  /// pages did before.
  List<Widget> _pages() => [
    _SettingsTabPage(
      children: [
        const LanguagePicker(),
        _journalTemplateTile(),
        _noteTemplateTile(),
        _templatesFolderTile(),
        _widgetDiagnosticsTile(),
      ],
    ),
    _SettingsTabPage(
      children: [
        Text(
          tr('KOLORY', 'COLORS'),
          style: TextStyle(fontSize: 11, letterSpacing: 1.3, color: muted),
        ),
        const SizedBox(height: 8),
        _defaultNoteColorTile(),
        _defaultFolderColorTile(),
        const SizedBox(height: 24),
        _compactModeTile(),
      ],
    ),
    _SettingsTabPage(children: [_shortcutsSection()]),
    _SettingsTabPage(
      children: [
        Text(
          tr('TWÓJ SERWER', 'YOUR SERVER'),
          style: TextStyle(fontSize: 11, letterSpacing: 1.3, color: muted),
        ),
        const SizedBox(height: 12),
        if (repo.session == null) ...[
          Text(
            tr('Synchronizuj na własnych zasadach', 'Sync on your own terms'),
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
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
            decoration: InputDecoration(labelText: tr('E-mail', 'Email')),
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
                const Icon(Icons.cloud_done_outlined, color: success),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(repo.session!.email),
                      Text(
                        repo.session!.server,
                        style: const TextStyle(color: muted, fontSize: 11),
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
            style: TextStyle(fontSize: 11, letterSpacing: 1.3, color: muted),
          ),
          const SizedBox(height: 8),
          for (final v in repo.vaults)
            _settingsRowGap(
              SwitchListTile(
                contentPadding: settingsItemPadding,
                shape: settingsItemShape,
                value: v.syncEnabled,
                onChanged: busy
                    ? null
                    : (enabled) => run(
                        () => _serverAction(() async {
                          if (enabled) {
                            await repo.enableSync(v);
                            await repo.sync();
                          } else {
                            v.syncEnabled = false;
                            repo.storage.putVault(v);
                          }
                        }),
                      ),
                title: Text(v.name, style: const TextStyle(fontSize: 14)),
                subtitle: _vaultSyncSubtitle(v),
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
              _settingsRowGap(
                ListTile(
                  // Informational row (actions live in the trailing icons):
                  // same left inset as the clickable settings rows so the
                  // section keeps one text edge. No hover surface.
                  contentPadding: settingsItemPadding,
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
                          icon: const Icon(Icons.edit_outlined, size: 18),
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
                                    initial: device['name'] as String? ?? '',
                                    hintBuilder: () =>
                                        tr('1–80 znaków', '1–80 characters'),
                                  );
                                  if (name == null) return;
                                  await run(
                                    () => _serverAction(() async {
                                      final saved = await repo.renameDevice(
                                        device['id'] as String,
                                        name,
                                      );
                                      await repo.refreshDevices();
                                      message = () => tr(
                                        'Nazwa urządzenia zapisana na serwerze: $saved',
                                        'Device name saved on the server: $saved',
                                      );
                                    }),
                                  );
                                },
                        ),
                      if (device['revoked'] != 1)
                        IconButton(
                          tooltip: tr('Cofnij dostęp', 'Revoke access'),
                          icon: const Icon(Icons.block, size: 18),
                          onPressed: busy
                              ? null
                              : () => run(
                                  () => _serverAction(() async {
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
                                                  Navigator.pop(ctx, false),
                                              child: Text(
                                                tr('Anuluj', 'Cancel'),
                                              ),
                                            ),
                                            FilledButton(
                                              onPressed: () =>
                                                  Navigator.pop(ctx, true),
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
                                                entry['id'] != device['id'],
                                          )
                                          .toList();
                                    }
                                  }),
                                ),
                        ),
                    ],
                  ),
                ),
              ),
        ],
      ],
    ),
    _SettingsTabPage(
      children: [
        if (credentialControl case final control?) credentialSection(control),
        hiddenSection(),
        const SizedBox(height: 28),
        const Divider(),
        const SizedBox(height: 14),
        Text(
          tr('MIEJSCE DANYCH', 'DATA LOCATION'),
          style: TextStyle(fontSize: 11, letterSpacing: 1.3, color: muted),
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
            icon: const Icon(Icons.drive_file_move_outlined, size: 18),
            label: Text(tr('Zmień miejsce zapisu', 'Change storage location')),
          ),
        if (NativeStorage.defaultLocationWarning != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              NativeStorage.defaultLocationWarning!,
              key: const Key('data-location-warning'),
              style: const TextStyle(fontSize: 11, color: warning),
            ),
          ),
        if (widget.serverTrust != null && widget.serverBase != null)
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
  ];

  /// Desktop right/left split: a section sidebar on the left, the selected
  /// section's page on the right. All six pages stay mounted inside an
  /// [IndexedStack] so field state and scroll offsets survive section switches.
  Widget _desktopLayout() {
    final pages = _pages();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 220, child: _sectionSidebar()),
        const VerticalDivider(width: 1),
        Expanded(
          child: IndexedStack(index: _section, children: pages),
        ),
      ],
    );
  }

  /// The desktop navigation rail: icon + label for each section, drawn with the
  /// same rounded `Material` + `InkWell` hover surface as folder rows.
  Widget _sectionSidebar() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      children: [
        for (var i = 0; i < _sections.length; i++)
          _sectionTile(i, trailing: false),
      ],
    );
  }

  /// The mobile section list: a tile per section (icon, name, chevron). Tapping
  /// opens the section in a drill-down view instead of swapping panes.
  Widget _mobileList() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      children: [
        for (var i = 0; i < _sections.length; i++)
          _sectionTile(i, trailing: true),
      ],
    );
  }

  /// Mobile: either the section list or, once a section is open, that section's
  /// content with a back header that returns to the list (never closing the
  /// dialog).
  Widget _mobileLayout() {
    // When opened via the update snackbar action, drill straight into Updates.
    if (_mobileSection == null) return _mobileList();
    final pages = _pages();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _mobileBackHeader(),
        const Divider(height: 1),
        Expanded(
          child: IndexedStack(index: _mobileSection!, children: pages),
        ),
      ],
    );
  }

  /// Back header above a drilled-in mobile section. Returns to the list view;
  /// the dialog itself stays open.
  Widget _mobileBackHeader() {
    final spec = _sections[_mobileSection!];
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(settingsItemRadius),
      child: InkWell(
        key: const Key('settings-back-to-list'),
        borderRadius: BorderRadius.circular(settingsItemRadius),
        onTap: () => setState(() => _mobileSection = null),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.arrow_back, size: 18),
              const SizedBox(width: 8),
              Icon(spec.icon, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  spec.label,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One section tile: rounded `Material` + `InkWell` with the shared [hover]
  /// token, mirroring the folder-row hover. [trailing] adds the chevron used by
  /// the mobile list; the desktop sidebar omits it.
  Widget _sectionTile(int index, {required bool trailing}) {
    final spec = _sections[index];
    final selected = index == _section;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        key: spec.key,
        color: selected ? accent.withValues(alpha: .10) : Colors.transparent,
        borderRadius: BorderRadius.circular(settingsItemRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(settingsItemRadius),
          onTap: () => setState(() {
            _section = index;
            _mobileSection = index;
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(spec.icon, size: 19, color: selected ? accent : muted),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    spec.label,
                    style: TextStyle(
                      fontSize: 13,
                      color: selected ? Colors.white : textSecondary,
                    ),
                  ),
                ),
                if (trailing) const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          ),
        ),
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
    return _settingsRowGap(
      ListTile(
        key: const Key('appearance-default-note-color'),
        contentPadding: settingsItemPadding,
        shape: settingsItemShape,
        leading: _colorSwatch(argb),
        title: Text(tr('Domyślny kolor nowych notatek', 'Default note color')),
        subtitle: Text(_hexText(argb)),
        onTap: busy || target == null ? null : () => _pickDefaultNoteColor(),
      ),
    );
  }

  Widget _defaultFolderColorTile() {
    final target = _compactVault;
    final argb = target == null ? null : repo.defaultFolderColorOf(target.id);
    return _settingsRowGap(
      ListTile(
        key: const Key('appearance-default-folder-color'),
        contentPadding: settingsItemPadding,
        shape: settingsItemShape,
        leading: _colorSwatch(argb),
        title: Text(tr('Domyślny kolor folderów', 'Default folder color')),
        subtitle: Text(
          argb == null ? tr('Brak koloru', 'No color') : _hexText(argb),
        ),
        onTap: busy || target == null ? null : () => _pickDefaultFolderColor(),
      ),
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

  Widget _shortcutsSection() {
    return DeviceSettingsBuilder(
      builder: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('SKRÓTY', 'SHORTCUTS'),
            style: TextStyle(fontSize: 11, letterSpacing: 1.3, color: muted),
          ),
          // The reset action sits on its own row so a long localized label
          // cannot force a horizontal overflow at large text scales.
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const Key('shortcuts-reset-all'),
              onPressed: _resetShortcuts,
              child: Text(tr('Przywróć domyślne', 'Restore defaults')),
            ),
          ),
          const SizedBox(height: 4),
          for (final action in ShortcutAction.all) _shortcutTile(action),
        ],
      ),
    );
  }

  Widget _shortcutTile(ShortcutAction action) {
    final binding = deviceSettings.bindingOf(action);
    return Container(
      margin: const EdgeInsets.only(bottom: settingsItemGap),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(settingsItemRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  shortcutActionLabel(action),
                  style: const TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 2),
                Text(
                  binding.label(),
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            key: Key('shortcut-change-${action.id}'),
            onPressed: () => _captureShortcut(action),
            child: Text(tr('Zmień', 'Change')),
          ),
        ],
      ),
    );
  }

  Future<void> _captureShortcut(ShortcutAction action) async {
    final captured = await showDialog<ShortcutBinding>(
      context: context,
      builder: (_) => const _ShortcutCaptureDialog(),
    );
    if (captured == null || !mounted) return;
    // Pre-check so the error can name the conflicting action precisely.
    final conflict = deviceSettings.conflictFor(action, captured);
    if (conflict != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${tr('Już używane przez', 'Already used by')}: '
            '${shortcutActionLabel(conflict)}',
          ),
        ),
      );
      return;
    }
    try {
      await deviceSettings.setBinding(action, captured);
      if (mounted) setState(() {});
    } on ArgumentError catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } on FormatException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Future<void> _resetShortcuts() async {
    final confirmed = await confirmAction(
      context,
      () => tr('Przywrócić domyślne skróty?', 'Restore default shortcuts?'),
      () => tr(
        'Wszystkie skróty wrócą do wartości domyślnych.',
        'All shortcuts will return to their defaults.',
      ),
    );
    if (!confirmed || !mounted) return;
    await deviceSettings.resetToDefaults();
    if (mounted) setState(() {});
  }

  Widget _journalTemplateTile() {
    final vault = widget.vault;
    final templates = vault == null
        ? const <Note>[]
        : templatesOf(repo.notes[vault.id]?.values ?? const <Note>[]);
    final currentId = deviceSettings.journalTemplateId;
    // The stored id may point at a template that no longer exists; the picker
    // shows „Brak" in that case rather than a phantom selection.
    final selectedId = templates.any((t) => t.id == currentId)
        ? currentId
        : null;
    final selectedTemplate = selectedId == null
        ? null
        : templates.where((t) => t.id == selectedId).firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Text(
          tr('DZIENNIK', 'JOURNAL'),
          style: TextStyle(fontSize: 11, letterSpacing: 1.3, color: muted),
        ),
        const SizedBox(height: 12),
        SiliqueChoice<String?>(
          key: const Key('journal-template-select'),
          value: selectedId,
          onChanged: vault == null
              ? null
              : (value) {
                  unawaited(deviceSettings.setJournalTemplateId(value));
                },
          decoration: InputDecoration(
            labelText: tr('Domyślny szablon wpisu', 'Default entry template'),
          ),
          // The closed trigger stays one line: only the title, no subfolder
          // path; the popup still shows the full item (title + relative path).
          triggerBuilder: (child) => selectedTemplate == null
              ? child
              : Text(
                  selectedTemplate.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          items: [
            SiliqueChoiceItem<String?>(
              value: null,
              icon: Icons.block,
              child: Text(tr('Brak', 'None')),
            ),
            for (final template in templates)
              SiliqueChoiceItem<String?>(
                value: template.id,
                icon: Icons.description_outlined,
                child: _templateChoiceChild(template),
              ),
          ],
        ),
        if (vault == null) ...[
          const SizedBox(height: 6),
          Text(
            tr(
              'Odblokuj vault, aby wybrać szablon.',
              'Unlock a vault to pick a template.',
            ),
            style: const TextStyle(color: muted, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _noteTemplateTile() {
    final vault = widget.vault;
    final templates = vault == null
        ? const <Note>[]
        : templatesOf(repo.notes[vault.id]?.values ?? const <Note>[]);
    final currentId = deviceSettings.noteTemplateId;
    // The stored id may point at a template that no longer exists; the picker
    // shows „Brak" in that case rather than a phantom selection.
    final selectedId = templates.any((t) => t.id == currentId)
        ? currentId
        : null;
    final selectedTemplate = selectedId == null
        ? null
        : templates.where((t) => t.id == selectedId).firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Text(
          tr('NOTATKI', 'NOTES'),
          style: TextStyle(fontSize: 11, letterSpacing: 1.3, color: muted),
        ),
        const SizedBox(height: 12),
        SiliqueChoice<String?>(
          key: const Key('note-template-select'),
          value: selectedId,
          onChanged: vault == null
              ? null
              : (value) {
                  unawaited(deviceSettings.setNoteTemplateId(value));
                },
          decoration: InputDecoration(
            labelText: tr('Domyślny szablon notatki', 'Default note template'),
          ),
          // The closed trigger stays one line: only the title, no subfolder
          // path; the popup still shows the full item (title + relative path).
          triggerBuilder: (child) => selectedTemplate == null
              ? child
              : Text(
                  selectedTemplate.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          items: [
            SiliqueChoiceItem<String?>(
              value: null,
              icon: Icons.block,
              child: Text(tr('Brak', 'None')),
            ),
            for (final template in templates)
              SiliqueChoiceItem<String?>(
                value: template.id,
                icon: Icons.description_outlined,
                child: _templateChoiceChild(template),
              ),
          ],
        ),
        if (vault == null) ...[
          const SizedBox(height: 6),
          Text(
            tr(
              'Odblokuj vault, aby wybrać szablon.',
              'Unlock a vault to pick a template.',
            ),
            style: const TextStyle(color: muted, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _templatesFolderTile() {
    return _settingsRowGap(
      SwitchListTile(
        key: const Key('templates-folder-hidden-toggle'),
        contentPadding: settingsItemPadding,
        shape: settingsItemShape,
        value: deviceSettings.hideTemplatesFolder,
        onChanged: (value) {
          unawaited(deviceSettings.setHideTemplatesFolder(value));
        },
        title: Text(
          tr(
            'Ukryj folder $templatesFolder',
            'Hide the $templatesFolder folder',
          ),
          style: const TextStyle(fontSize: 14),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            tr(
              'Folder $templatesFolder jest wbudowany — można go ukryć w drzewie, ale nie usunąć.',
              'The $templatesFolder folder is built in — you can hide it from the tree, but not delete it.',
            ),
            style: const TextStyle(color: muted, fontSize: 12, height: 1.4),
          ),
        ),
      ),
    );
  }

  Widget _compactModeTile() {
    final target = _compactVault;
    return _settingsRowGap(
      SwitchListTile(
        key: const Key('compact-mode-toggle'),
        contentPadding: settingsItemPadding,
        shape: settingsItemShape,
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
      ),
    );
  }

  /// Android-only: the launcher renders outside the app, so read/publish
  /// outcomes of the encrypted widget snapshot are only visible here.
  Widget _widgetDiagnosticsTile() {
    final load = widget.widgetDiagnostics;
    if (load == null) return const SizedBox.shrink();
    return _settingsRowGap(
      ListTile(
        key: const Key('widget-diagnostics-tile'),
        contentPadding: settingsItemPadding,
        shape: settingsItemShape,
        leading: const Icon(Icons.bug_report_outlined, size: 20),
        title: Text(
          tr('Diagnostyka widżetów', 'Widget diagnostics'),
          style: const TextStyle(fontSize: 14),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            tr(
              'Zapis odczytów i odświeżeń widżetów Androida. Przydatny przy zgłaszaniu problemów z listą notatek lub wyszukiwarką.',
              'A log of Android widget reads and refreshes, useful when reporting problems with the note list or search.',
            ),
            style: const TextStyle(color: muted, fontSize: 12, height: 1.4),
          ),
        ),
        onTap: () => _showWidgetDiagnostics(load),
      ),
    );
  }

  Future<void> _showWidgetDiagnostics(Future<String> Function() load) async {
    final raw = await load();
    if (!mounted) return;
    final body = raw.trim().isEmpty
        ? tr('Brak zapisanych zdarzeń.', 'No events recorded yet.')
        : raw.trim();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Diagnostyka widżetów', 'Widget diagnostics')),
        content: SizedBox(
          width: 480,
          height: 340,
          child: SingleChildScrollView(
            child: SelectableText(
              body,
              key: const Key('widget-diagnostics-text'),
              contextMenuBuilder: siliqueTextContextMenu,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                height: 1.5,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('widget-diagnostics-copy'),
            onPressed: () {
              unawaited(Clipboard.setData(ClipboardData(text: body)));
              ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
                SnackBar(content: Text(tr('Skopiowano.', 'Copied.'))),
              );
            },
            child: Text(tr('Kopiuj', 'Copy')),
          ),
          FilledButton(
            key: const Key('widget-diagnostics-close'),
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Zamknij', 'Close')),
          ),
        ],
      ),
    );
  }
}

/// A settings section navigation entry: its tab/sidebar key, icon and label.
class _SectionSpec {
  const _SectionSpec(this.key, this.icon, this.label);
  final Key key;
  final IconData icon;
  final String label;
}

/// Adds the shared vertical gap below a Settings-section row. Rows carry their
/// own [settingsItemPadding] / [settingsItemShape]; this helper keeps the
/// spacing between rows uniform without widening the page's own padding.
Widget _settingsRowGap(Widget child) => Padding(
  padding: const EdgeInsets.only(bottom: settingsItemGap),
  child: child,
);

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
      // The section pane sits in an `IndexedStack`, whose children get loose
      // width constraints. Without this the page would shrink-wrap to its widest
      // intrinsic child and the tiles would lay out a few dozen pixels wide.
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: widget.children,
        ),
      ),
    );
  }
}

/// A modal capture dialog: the first key chord with at least one non-Shift
/// modifier is accepted and returned; Escape cancels. A plain key without a
/// modifier is ignored (validation demands a modifier for printable keys).
class _ShortcutCaptureDialog extends StatefulWidget {
  const _ShortcutCaptureDialog();
  @override
  State<_ShortcutCaptureDialog> createState() => _ShortcutCaptureDialogState();
}

class _ShortcutCaptureDialogState extends State<_ShortcutCaptureDialog> {
  final FocusNode _focus = FocusNode();
  String? _hint;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      Navigator.pop(context);
      return KeyEventResult.handled;
    }
    // Reject keys that are themselves modifiers, or that produce no physical
    // key (e.g. CapsLock, Fn).
    if (key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight ||
        key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.capsLock ||
        key == LogicalKeyboardKey.numLock ||
        key == LogicalKeyboardKey.scrollLock) {
      return KeyEventResult.handled;
    }
    final keyboard = HardwareKeyboard.instance;
    final modifiers = <ShortcutModifier>{
      if (keyboard.isControlPressed) ShortcutModifier.ctrl,
      if (keyboard.isMetaPressed) ShortcutModifier.meta,
      if (keyboard.isAltPressed) ShortcutModifier.alt,
      if (keyboard.isShiftPressed) ShortcutModifier.shift,
    };
    // Need the key name; unknown key (e.g. media keys) is silently ignored.
    final keyName = keyNameForLogicalKey(key);
    if (keyName == null) return KeyEventResult.handled;
    final hasRequiredModifier = modifiers.any(
      (m) => m != ShortcutModifier.shift,
    );
    if (!hasRequiredModifier) {
      setState(() {
        _hint = tr(
          'Naciśnij kombinację z modyfikatorem (Ctrl/Cmd, Alt).',
          'Press a combination with a modifier (Ctrl/Cmd, Alt).',
        );
      });
      return KeyEventResult.handled;
    }
    final binding = ShortcutBinding(modifiers: modifiers, key: keyName);
    Navigator.pop(context, binding);
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: appLanguage,
    builder: (context, _) => AlertDialog(
      title: Text(tr('Naciśnij skrót', 'Press a shortcut')),
      content: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Text(
          _hint ?? tr('Naciśnij kombinację…', 'Press a combination…'),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('shortcut-capture-cancel'),
          onPressed: () => Navigator.pop(context),
          child: Text(tr('Anuluj', 'Cancel')),
        ),
      ],
    ),
  );
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
                        style: const TextStyle(color: warning, fontSize: 12),
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
                    Text(
                      tr(
                        'Wybrano: ${localizeSystemFolderPath(selected)}',
                        'Selected: ${localizeSystemFolderPath(selected)}',
                      ),
                    ),
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
                                folderName(localizeSystemFolderPath(folder)),
                                style: const TextStyle(fontSize: 13),
                              ),
                              subtitle: query.isNotEmpty && folder.contains('/')
                                  ? Text(
                                      localizeSystemFolderPath(
                                        folder.substring(
                                          0,
                                          folder.lastIndexOf('/'),
                                        ),
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

/// The picker row for a template: its title plus, when it lives in a subfolder
/// of the templates folder, the relative path as a muted second line.
Widget _templateChoiceChild(Note template) {
  final subpath = templatesSubpathOf(template.folder);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(template.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      if (subpath != null)
        Text(
          subpath,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, color: muted),
        ),
    ],
  );
}

/// Chooses a template note from [templates] and returns it, or null when the
/// user cancels. An empty list shows the "create a note in the templates
/// folder" hint instead of an impossible selection. Templates from a subfolder
/// show their relative path as a subtitle.
Future<Note?> chooseTemplate(
  BuildContext context, {
  required List<Note> templates,
}) async {
  final result = await showDialog<Note>(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: appLanguage,
      builder: (ctx, _) => AlertDialog(
        scrollable: true,
        title: Text(tr('Szablon notatki', 'Note template')),
        content: SizedBox(
          width: 460,
          height: 380,
          child: templates.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      tr(
                        'Utwórz notatkę w folderze $templatesFolder, aby dodać szablon.',
                        'Create a note in the $templatesFolder folder to add a template.',
                      ),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: muted),
                    ),
                  ),
                )
              : ListView(
                  children: [
                    for (final template in templates)
                      ListTile(
                        key: Key('template-${template.id}'),
                        minTileHeight: 48,
                        iconColor: accent,
                        hoverColor: menuHover,
                        focusColor: menuHover,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        leading: const Icon(
                          Icons.description_outlined,
                          size: 18,
                        ),
                        title: Text(
                          template.title,
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: templatesSubpathOf(template.folder) == null
                            ? null
                            : Text(
                                templatesSubpathOf(template.folder)!,
                                style: const TextStyle(fontSize: 11),
                              ),
                        onTap: () => Navigator.pop(ctx, template),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Anuluj', 'Cancel')),
          ),
        ],
      ),
    ),
  );
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
