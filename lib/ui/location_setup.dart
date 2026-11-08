import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/credential_mode.dart';

import '../storage/native_files.dart';
import '../storage/native_storage.dart';
import '../storage/windows_folder_access.dart';
import 'windows_folder_access_panel.dart';
import 'theme.dart';
import '../l10n/app_language.dart';
import 'language_picker.dart';
import 'menus.dart';
import 'credential_mode_picker.dart';

/// First-run choice of the vault location, and recovery of a lost one.
///
/// The user picks a real directory through the platform picker. Nothing is
/// created before a directory is confirmed, so cancelling leaves no database
/// behind. In [recovering] mode the chosen directory must already contain the
/// notes: an empty store is never created in place of data that still exists.
class LocationSetupScreen extends StatefulWidget {
  const LocationSetupScreen({
    super.key,
    required this.onChosen,
    this.recovering = false,
    this.unavailable,
    this.folderAccessService,
    this.chooseCredentialMode = false,
    this.onChosenWithCredentialMode,
  });

  /// Persists the location and opens the notebook. Throwing shows the error here
  /// without leaving a partially created store.
  final Future<void> Function(String root) onChosen;

  /// Opt in only for genuinely fresh configuration, not existing installations.
  /// Recovery always preserves credentials, even if this flag is set.
  final bool chooseCredentialMode;

  /// Runs after consent and a usable folder have been explicitly confirmed.
  /// When omitted, [onChosen] remains the callback for existing callers.
  final Future<void> Function(String root, CredentialMode mode)?
  onChosenWithCredentialMode;

  /// Whether the recorded location could not be opened.
  final bool recovering;

  /// The unreadable recorded location, shown so the user recognises the place.
  final String? unavailable;
  final WindowsFolderAccess? folderAccessService;

  @override
  State<LocationSetupScreen> createState() => _LocationSetupScreenState();
}

class _LocationSetupScreenState extends State<LocationSetupScreen> {
  bool _busy = false;
  CredentialMode _credentialMode = CredentialMode.local;
  bool _localConsent = false;
  bool get _choosingCredentials =>
      widget.chooseCredentialMode && !widget.recovering;
  bool get _android => defaultTargetPlatform == TargetPlatform.android;
  bool get _credentialConsent =>
      _android ||
      !_choosingCredentials ||
      _credentialMode != CredentialMode.local ||
      _localConsent;
  bool _accessBusy = false;
  bool _restartRequired = false;
  String? _inspectionRoot;
  String Function()? _error;

  Future<void> _choose() async {
    if (_busy || _accessBusy || _restartRequired || !_credentialConsent) return;
    String? chosenDirectory;
    setState(() {
      _busy = true;
      _error = null;
      _inspectionRoot = null;
    });
    try {
      final choice = await chooseStorageDirectory();
      if (choice == null) {
        if (mounted) {
          setState(
            () => _error = () => widget.recovering
                ? tr(
                    'Nie wybrano katalogu. Twoje dane pozostają nietknięte.',
                    'No folder selected. Your data remains untouched.',
                  )
                : tr(
                    'Nie wybrano katalogu. Vaulty nie zostały utworzone — wybierz miejsce zapisu.',
                    'No folder selected. No vaults have been created — choose a storage location.',
                  ),
          );
        }
        return;
      }
      if (!choice.usable) {
        // Some providers hand out a location that cannot hold the vault. Say it
        // plainly and let the user pick a folder on the device; nothing is
        // substituted silently.
        if (mounted) {
          setState(
            () => _error = () => tr(
              'Ten katalog nie może przechowywać notatek. '
                  'Wybierz folder w pamięci urządzenia, np. Dokumenty.',
              'This folder cannot store notes. Choose a folder on this device, such as Documents.',
            ),
          );
        }
        return;
      }
      chosenDirectory = choice.path!;
      await _adopt(chosenDirectory);
    } catch (error) {
      if (mounted) {
        setState(() {
          final diagnostic = '$error';
          _error = () => diagnostic;
          if (error is StorageLocationUnavailable ||
              error is StorageOpenFailure) {
            // The selected parent exists even when creating Silique Vaults was
            // refused. The native helper still needs exact 1123 evidence inside it.
            _inspectionRoot = chosenDirectory;
          }
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _adopt(String directory) async {
    final root = widget.recovering
        ? NativeStorage.adoptExistingRoot(directory)
        : NativeStorage.prepareChosenRoot(directory);
    // Remember the exact path that is persisted as the location: the macOS
    // bookmark is looked up by that path after a restart, so remembering the
    // parent directory instead would leave the app without access.
    await rememberStorageAccess(root);
    final withMode = widget.onChosenWithCredentialMode;
    if (_choosingCredentials && withMode != null) {
      await withMode(root, _android ? CredentialMode.system : _credentialMode);
    } else {
      await widget.onChosen(root);
    }
  }

  @override
  Widget build(BuildContext context) => LanguageBuilder(
    builder: (context) => SiliqueMaterialApp(
      title: 'Silique',
      debugShowCheckedModeBanner: false,
      theme: siliqueTheme(),
      home: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Center(child: SiliqueMark(size: 64)),
                  const SizedBox(height: 26),
                  const LanguagePicker(),
                  const SizedBox(height: 20),
                  Text(
                    widget.recovering
                        ? tr(
                            'Nie znaleziono Twoich notatek',
                            'Your notes could not be found',
                          )
                        : tr(
                            'Gdzie mają być Twoje vaulty?',
                            'Where should your vaults be stored?',
                          ),
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.4,
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (widget.recovering) ...[
                    Text(
                      tr(
                        'Zapisana lokalizacja nie jest już dostępna. Wskaż katalog, w którym '
                            'znajdują się Twoje notatki (z plikiem silique.sqlite), a Silique otworzy '
                            'je ponownie. Nic nie zostanie nadpisane, a klucze pozostają bez zmian.',
                        'The saved location is no longer available. Select the folder containing your notes (with the silique.sqlite file), and Silique will reopen them. Nothing will be overwritten, and keys remain unchanged.',
                      ),
                      style: TextStyle(color: muted, height: 1.7),
                    ),
                    if (widget.unavailable != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: SelectableText(
                          widget.unavailable!,
                          contextMenuBuilder: siliqueTextContextMenu,
                          key: const Key('unavailable-location'),
                          style: const TextStyle(
                            fontSize: 12,
                            color: muted,
                            height: 1.6,
                          ),
                        ),
                      ),
                  ] else
                    Text(
                      tr(
                        'Wybierz folder na tym urządzeniu, w którym Silique będzie przechowywać Twoje '
                            'notatki. W wybranym miejscu powstanie podfolder „Silique Vaults”. '
                            'Lokalizację możesz później zmienić w Ustawieniach.',
                        'Choose a folder on this device for Silique to store your notes. A “Silique Vaults” subfolder will be created there. You can change the location later in Settings.',
                      ),
                      style: TextStyle(color: muted, height: 1.7),
                    ),
                  const SizedBox(height: 10),
                  Text(
                    widget.recovering
                        ? tr(
                            'Bez istniejącej bazy nie utworzymy pustego vaulta.',
                            'An empty vault will not be created in place of an existing database.',
                          )
                        : tr(
                            'Bez wybranego katalogu aplikacja nie utworzy żadnej bazy — '
                                'możesz anulować i wybrać miejsce później.',
                            'No database will be created until you choose a folder — you can cancel and choose a location later.',
                          ),
                    style: const TextStyle(
                      color: muted,
                      fontSize: 12,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 26),
                  if (_choosingCredentials && !_android) ...[
                    CredentialModePicker(
                      mode: _credentialMode,
                      onChanged: _busy || _accessBusy || _restartRequired
                          ? null
                          : (mode) => setState(() {
                              _credentialMode = mode;
                              _localConsent = false;
                            }),
                    ),
                    if (_credentialMode == CredentialMode.local)
                      CheckboxListTile(
                        key: const Key('credential-local-consent'),
                        contentPadding: EdgeInsets.zero,
                        value: _localConsent,
                        onChanged: _busy || _accessBusy || _restartRequired
                            ? null
                            : (value) => setState(
                                () => _localConsent = value ?? false,
                              ),
                        title: Text(
                          tr(
                            'Rozumiem ryzyko i wybieram mniej bezpieczny lokalny plik.',
                            'I understand the risk and choose the less secure local file.',
                          ),
                        ),
                      ),
                    const SizedBox(height: 20),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const Key('choose-location'),
                      onPressed:
                          _busy ||
                              _accessBusy ||
                              _restartRequired ||
                              !_credentialConsent
                          ? null
                          : _choose,
                      icon: const Icon(Icons.folder_open_outlined),
                      label: Text(
                        widget.recovering
                            ? tr(
                                'Wskaż istniejące dane',
                                'Locate existing data',
                              )
                            : _error == null
                            ? tr('Wybierz folder', 'Choose a folder')
                            : tr(
                                'Wybierz folder ponownie',
                                'Choose a folder again',
                              ),
                      ),
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 18),
                      child: Text(
                        _error!(),
                        key: const Key('location-error'),
                        style: const TextStyle(
                          color: Colors.orangeAccent,
                          height: 1.6,
                        ),
                      ),
                    ),
                  if (_inspectionRoot != null)
                    WindowsFolderAccessPanel(
                      key: ValueKey(_inspectionRoot),
                      root: _inspectionRoot!,
                      service: widget.folderAccessService,
                      enabled: !_busy,
                      onBusyChanged: (value) =>
                          setState(() => _accessBusy = value),
                      onRestartRequired: () =>
                          setState(() => _restartRequired = true),
                    ),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 20),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  const SizedBox(height: 24),
                  Text(
                    widget.recovering
                        ? tr(
                            'Szukaj katalogu z plikiem silique.sqlite — to Twoje notatki. '
                                'Jeśli dane są na dysku zewnętrznym lub w chmurze, najpierw '
                                'udostępnij ten katalog w systemie.',
                            'Look for the folder containing silique.sqlite — these are your notes. If it is on an external drive or in the cloud, make the folder available to the system first.',
                          )
                        : tr(
                            'Wybrany katalog musi pozwalać na zapis plików. '
                                'Na macOS system może poprosić o zgodę na dostęp do folderu.',
                            'The selected folder must allow file writes. On macOS, the system may ask for permission to access the folder.',
                          ),
                    style: const TextStyle(
                      fontSize: 11,
                      color: muted,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
