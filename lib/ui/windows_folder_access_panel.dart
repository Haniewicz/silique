import '../l10n/app_language.dart';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../storage/windows_folder_access.dart';
import 'menus.dart';

/// Read-only diagnosis is separate from the user's explicit consent to UAC.
class WindowsFolderAccessPanel extends StatefulWidget {
  const WindowsFolderAccessPanel({
    super.key,
    required this.root,
    this.service,
    this.onBusyChanged,
    this.onRestartRequired,
    this.openSecurity,
    this.enabled = true,
  });

  final String root;
  final WindowsFolderAccess? service;

  /// Unknown/timeout keeps the host's storage actions locked until a new process:
  /// the native elevated operation might still be running.
  final ValueChanged<bool>? onBusyChanged;
  final VoidCallback? onRestartRequired;
  final Future<bool> Function(Uri)? openSecurity;
  final bool enabled;

  @override
  State<WindowsFolderAccessPanel> createState() =>
      _WindowsFolderAccessPanelState();
}

class _WindowsFolderAccessPanelState extends State<WindowsFolderAccessPanel> {
  late WindowsFolderAccess _service;
  int _inspectionGeneration = 0;
  FolderAccessResult? _inspection;
  FolderAccessResult? _outcome;
  bool _busy = false;
  bool _securityUnavailable = false;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? WindowsFolderAccess();
    if (_service.isWindows) _inspect();
  }

  Future<void> _inspect() async {
    final generation = ++_inspectionGeneration;
    final result = await _service.inspect(widget.root);
    if (mounted && generation == _inspectionGeneration) {
      setState(() => _inspection = result);
    }
  }

  @override
  void didUpdateWidget(WindowsFolderAccessPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.root == widget.root && oldWidget.service == widget.service) {
      return;
    }
    _inspection = null;
    _inspectionGeneration++;
    if (oldWidget.service != widget.service) {
      _service = widget.service ?? WindowsFolderAccess();
    }
    if (_service.isWindows && !_busy && _outcome == null) _inspect();
  }

  Future<void> _allow() async {
    final inspection = _inspection;
    if (!widget.enabled ||
        _busy ||
        _outcome != null ||
        inspection?.status != FolderAccessStatus.confirmed ||
        inspection?.canRequest != true) {
      return;
    }
    setState(() => _busy = true);
    widget.onBusyChanged?.call(true);
    try {
      final consent = await showDialog<bool>(
        context: context,
        builder: (context) => ListenableBuilder(
          listenable: appLanguage,
          builder: (context, _) => AlertDialog(
            title: Text(
              tr('Zgoda w ochronie Windows', 'Windows protection permission'),
            ),
            content: SingleChildScrollView(
              child: Text(
                tr(
                  'Zgoda CFA pozwoli tej instalacji Silique na dostęp do chronionych folderów, nie tylko do wybranego folderu notatek. Zgoda nie wyłącza Defendera ani skanowania. Wymaga uprawnień administratora. Windows wyświetli UAC; ponieważ aplikacja nie jest podpisana, może pokazać „Nieznany wydawca”. Możesz anulować bez zmiany ustawień. Kontynuować?',
                  'CFA permission will allow this Silique installation to access protected folders, not just the selected notes folder. It does not disable Defender or scanning. Administrator privileges are required. Windows will show UAC; since the app is unsigned, it may show “Unknown publisher”. You can cancel without changing settings. Continue?',
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(tr('Anuluj', 'Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(tr('Kontynuuj do UAC', 'Continue to UAC')),
              ),
            ],
          ),
        ),
      );
      if (consent != true || !mounted) return;
      final outcome = await _service.requestAllow(inspection!, widget.root);
      if (!mounted) return;
      setState(() => _outcome = outcome);
      if (outcome.status == FolderAccessStatus.allowed ||
          outcome.status == FolderAccessStatus.unconfirmed) {
        widget.onRestartRequired?.call();
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (_outcome?.status != FolderAccessStatus.unconfirmed) {
          widget.onBusyChanged?.call(false);
        }
      }
    }
  }

  Future<void> _openSecurity() async {
    try {
      final uri = Uri.parse('windowsdefender://threatsettings');
      final opened =
          await (widget.openSecurity?.call(uri) ??
              launchUrl(uri, mode: LaunchMode.externalApplication));
      if (mounted) setState(() => _securityUnavailable = !opened);
    } catch (_) {
      if (mounted) setState(() => _securityUnavailable = true);
    }
  }

  String get _outcomeText => switch (_outcome!.status) {
    FolderAccessStatus.allowed => tr(
      'Dodano zgodę. Zamknij i uruchom Silique ponownie.',
      'Permission added. Close and restart Silique.',
    ),
    FolderAccessStatus.cancelled => tr(
      'Anulowano zgodę UAC. Nie zmieniono ustawień.',
      'UAC permission cancelled. Settings were not changed.',
    ),
    FolderAccessStatus.failed => tr(
      'Nie udało się dodać zgody. Zmianę mogła zablokować polityka systemowa lub odmowa dostępu.',
      'Could not add permission. A system policy or access denial may have blocked the change.',
    ),
    _ => tr(
      'Nie potwierdzono wyniku. Operacja Windows może nadal trwać. Nie ponawiaj żądania.',
      'The outcome is unconfirmed. The Windows operation may still be running. Do not repeat the request.',
    ),
  };

  @override
  Widget build(BuildContext context) {
    Localizations.localeOf(context);
    return !_service.isWindows
        ? const SizedBox.shrink()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tr('Ochrona folderów Windows', 'Windows folder protection')),
              SelectableText(
                tr('Folder: ${widget.root}', 'Folder: ${widget.root}'),
                contextMenuBuilder: siliqueTextContextMenu,
              ),
              if (_inspection == null)
                Text(
                  tr(
                    'Sprawdzanie ochrony — bez zmian systemu…',
                    'Checking protection — no system changes…',
                  ),
                ),
              if (_inspection != null &&
                  _inspection!.status != FolderAccessStatus.confirmed)
                Text(
                  tr(
                    'Nie potwierdzono, że przyczyną jest Kontrolowany dostęp do folderów. Możliwa jest inna blokada zapisu; inspekcja nie zmieniła ustawień.',
                    'Controlled folder access was not confirmed as the cause. Another write restriction may exist; inspection did not change settings.',
                  ),
                ),
              if (_inspection?.status == FolderAccessStatus.confirmed)
                Text(
                  tr(
                    'Potwierdzono blokadę tej instalacji przez Kontrolowany dostęp do folderów (CFA).',
                    'Controlled folder access (CFA) is confirmed to be blocking this installation.',
                  ),
                ),
              if (_inspection?.status == FolderAccessStatus.confirmed &&
                  !_inspection!.canRequest)
                Text(
                  tr(
                    'Ta instalacja nie pozwala na bezpieczną automatyczną zgodę. Zainstaluj Silique ponownie w Program Files. Możesz też sprawdzić ustawienia ręcznie.',
                    'This installation cannot safely request permission automatically. Reinstall Silique in Program Files. You can also check settings manually.',
                  ),
                ),
              if (_busy)
                Text(
                  tr(
                    'Oczekiwanie na zgodę Windows. Nie ponawiaj żądania.',
                    'Waiting for Windows permission. Do not repeat the request.',
                  ),
                ),
              if (_outcome != null) Text(_outcomeText),
              if (_inspection?.status == FolderAccessStatus.confirmed &&
                  _inspection!.canRequest &&
                  _outcome == null)
                FilledButton(
                  onPressed: _busy || !widget.enabled ? null : _allow,
                  child: Text(
                    tr(
                      'Zezwól Silique w ochronie Windows',
                      'Allow Silique in Windows protection',
                    ),
                  ),
                ),
              TextButton(
                onPressed: _busy || !widget.enabled ? null : _openSecurity,
                child: Text(
                  tr('Otwórz Zabezpieczenia Windows', 'Open Windows Security'),
                ),
              ),
              Text(
                tr(
                  'Ręcznie: Ochrona przed wirusami i zagrożeniami → Zarządzaj ochroną przed oprogramowaniem wymuszającym okup → Zezwalaj aplikacji na dostęp przez funkcję Kontrolowany dostęp do folderów. Jeśli potwierdzisz blokadę, wskaż dokładnie plik poniżej. Nie wyłączaj ochrony. Samo otwarcie ustawień nie prosi o podniesienie uprawnień.',
                  'Manually: Virus & threat protection → Manage ransomware protection → Allow an app through Controlled folder access. If you confirm a block, select the exact file shown below. Do not disable protection. Opening settings alone does not request elevation.',
                ),
              ),
              SelectableText(
                _service.executable,
                contextMenuBuilder: siliqueTextContextMenu,
              ),
              if (_securityUnavailable)
                Text(
                  tr(
                    'Nie można otworzyć ustawień. Otwórz Zabezpieczenia Windows z menu Start i użyj powyższej instrukcji.',
                    'Could not open settings. Open Windows Security from the Start menu and follow the instructions above.',
                  ),
                ),
            ],
          );
  }
}
