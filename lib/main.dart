import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'dart:io' show Directory, File;

import 'storage/native_storage_recovery.dart';
import 'storage/windows_folder_access.dart';
import 'storage/startup_notebook.dart';
import 'storage/native_files.dart';
import 'services/notebook.dart';
import 'storage/native_storage.dart';
import 'storage/native_window.dart';
import 'storage/secure_keys.dart';
import 'core/credential_mode.dart';
import 'storage/credential_files.dart';
import 'storage/credential_startup.dart';
import 'storage/managed_keys.dart';
import 'ui/credential_recovery.dart';
import 'ui/android_credential_migration.dart';
import 'ui/home.dart';
import 'l10n/app_language.dart';
import 'ui/location_setup.dart';
import 'ui/windows_folder_access_panel.dart';

export 'ui/windows_folder_access_panel.dart';
import 'ui/theme.dart';
import 'ui/menus.dart';

final notebookProvider = Provider<Notebook>(
  (ref) => throw StateError('Notebook is not initialized'),
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  NativeWindow.installLifecycleHandler();
  runApp(const _StartingApp());
  final Directory support;
  try {
    await NativeWindow.initialize();
    support = await getApplicationSupportDirectory();
    await appLanguage.initialize(support);
  } catch (error) {
    runApp(StartupFailureScreen(error: '$error'));
    return;
  }
  // Keep startup diagnostics next to the app's own state, never inside the
  // vault folder: that folder is checked for foreign files before it is used.
  NativeStorage.diagnosticsDirectory = support.path;
  final recorded = NativeStorage.recordedRoot(support.path);
  var accessDenied = false;
  try {
    await restoreStorageAccess();
  } catch (_) {
    // A missing or stale macOS bookmark is recoverable: ask for the folder
    // again instead of failing with a dead-end retry screen.
    if (recorded == null) {
      runApp(
        StartupFailureScreen(
          error: tr(
            'Brak dostępu do katalogu danych.',
            'No access to the data directory.',
          ),
        ),
      );
      return;
    }
    accessDenied = true;
  }
  try {
    final existing = accessDenied
        ? null
        : NativeStorage.existingRoot(support.path);
    if (existing != null) {
      await _openAndRun(existing);
      return;
    }
    if (accessDenied) {
      await _showLocationChoice(support.path, recorded, recovering: true);
      return;
    }
    // Fresh installation: nothing is created until the user confirms a real
    // directory, so cancelling never leaves an empty database behind.
    await _showLocationChoice(support.path, null, recovering: false);
  } on StorageRootWriteBlocked catch (error) {
    // Retrying this folder is a dead end: the system refuses every write, and a
    // folder picker cannot import notes that are still there. Offer the move.
    runApp(startupFailureFor(error, support));
  } on StorageLocationUnavailable catch (error) {
    await _showLocationChoice(support.path, error.path, recovering: true);
  } catch (error) {
    runApp(startupFailureFor(error, support));
  }
}

/// The failure screen for an error that happened before the notebook opened.
///
/// A database I/O failure gets its own wording and an escape into choosing a
/// copy of the folder: retrying the same locked file forever is a dead end,
/// while the keychain text would point at the wrong cause.
Widget startupFailureFor(
  Object error,
  Directory support, {
  WindowsFolderAccess? folderAccessService,
}) {
  if (error is StorageRootWriteBlocked) {
    return StartupFailureScreen(
      error: error.reason,
      storageRoot: error.path,
      folderAccessService: folderAccessService,
      hint: tr(
        'System blokuje zapis w folderze z Twoimi notatkami. Baza nie jest '
            'uszkodzona — Silique nie zdążył jej otworzyć. Możesz przenieść notatki '
            'do innego folderu. Oryginał pozostanie bez zmian.',
        'The system is blocking writes to your notes folder. The database is not damaged — Silique has not opened it yet. You can move your notes to another folder. The original will remain unchanged.',
      ),
      onRelocate: () async {
        final choice = await chooseStorageDirectory();
        if (choice == null) return null;
        if (!choice.usable) {
          throw StateError(
            tr(
              'Wybierz folder zapisywalny na tym urządzeniu. Oryginał zachowano.',
              'Choose a writable folder on this device. The original has been preserved.',
            ),
          );
        }
        final moved = NativeStorage.relocateBlockedRoot(
          support.path,
          error.path,
          choice.path!,
        );
        await rememberStorageAccess(moved);
        await _openAndRun(moved);
        return moved;
      },
    );
  }
  if (error is StorageOpenFailure) {
    return StartupFailureScreen(
      error: error.summary,
      storageRoot: File(error.path).parent.path,
      folderAccessService: folderAccessService,
      hint: error.reason,
      onChooseFolder: () =>
          _showLocationChoice(support.path, error.path, recovering: true),
      onRecover: () async {
        final choice = await chooseStorageDirectory();
        if (choice == null) return null;
        if (!choice.usable) {
          throw StateError(
            tr(
              'Wybierz lokalny folder z dostępem do zapisu. Oryginał zachowano.',
              'Choose a writable local folder. The original has been preserved.',
            ),
          );
        }
        final source = File(error.path).parent.path;
        final destination =
            '${choice.path}/Silique Recovered-${DateTime.now().microsecondsSinceEpoch}';
        // Snapshot only: a concurrent writer may continue after the snapshot.
        // Never silently activate a potentially older copy.
        return NativeStorageRecovery.recover(source, destination);
      },
    );
  }
  return StartupFailureScreen(error: '$error');
}

Future<void> _showLocationChoice(
  String applicationSupport,
  String? unavailable, {
  required bool recovering,
}) async {
  try {
    final files = await NativeCredentialFiles.forSupport(
      Directory(applicationSupport),
    );
    final chooseCredentials = await credentialChoiceRequired(
      files,
      recovering: recovering,
    );
    final expectedRoot = StorageRootExpectation(
      NativeStorage.recordedRoot(applicationSupport),
    );
    runApp(
      LocationSetupScreen(
        recovering: recovering,
        unavailable: unavailable,
        chooseCredentialMode: chooseCredentials,
        onChosenWithCredentialMode: (root, mode) async {
          await _openAndRun(
            root,
            applicationSupport: applicationSupport,
            expectedRoot: expectedRoot,
            credentialMode: mode,
          );
        },
        onChosen: (root) async {
          await _openAndRun(
            root,
            applicationSupport: applicationSupport,
            expectedRoot: expectedRoot,
          );
        },
      ),
    );
  } catch (error) {
    runApp(startupFailureFor(error, Directory(applicationSupport)));
  }
}

/// Resolve explicit credential decisions before opening or creating a notebook.
/// Interrupted moves take priority over Android's one-time legacy offer.
Future<Widget?> credentialStartupGate(
  ManagedKeys keys,
  CredentialStartupPolicy policy, {
  required Future<void> Function() onContinue,
}) async {
  if (keys.cleanupPending) {
    return CredentialRecoveryScreen(control: keys, onContinue: onContinue);
  }
  if (await policy.shouldOfferAndroidMigration(keys)) {
    return AndroidCredentialMigrationScreen(
      control: keys,
      onKeepLocal: policy.keepLocalCredentials,
      onContinue: onContinue,
    );
  }
  return null;
}

Future<void> _openAndRun(
  String root, {
  String? applicationSupport,
  StorageRootExpectation? expectedRoot,
  CredentialMode? credentialMode,
}) async {
  final support = applicationSupport == null
      ? await getApplicationSupportDirectory()
      : Directory(applicationSupport);
  final files = await NativeCredentialFiles.forSupport(support);
  final policy = CredentialStartupPolicy(files: files);
  final keys = ManagedKeys(files: files, system: const SecureKeys());
  await policy.initialize(
    keys,
    firstRunMode: credentialMode,
    requireExistingKey: File('$root/silique.sqlite').existsSync(),
  );
  final gate = await credentialStartupGate(
    keys,
    policy,
    onContinue: () => _openAndRun(
      root,
      applicationSupport: support.path,
      expectedRoot: expectedRoot,
    ),
  );
  if (gate != null) {
    runApp(gate);
    return;
  }
  final notebook = await openStartupNotebook(
    root,
    keys: keys,
    applicationSupport: support.path,
    expectedRoot: expectedRoot,
  );
  runApp(
    ProviderScope(
      overrides: [notebookProvider.overrideWithValue(notebook)],
      child: const SiliqueApp(),
    ),
  );
}

class _StartingApp extends StatelessWidget {
  const _StartingApp();

  @override
  Widget build(BuildContext context) => LanguageBuilder(
    builder: (context) => SiliqueMaterialApp(
      title: 'Silique',
      debugShowCheckedModeBanner: false,
      theme: siliqueTheme(),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SiliqueMark(size: 56),
                  const SizedBox(height: 24),
                  Text(
                    tr('Otwieranie notatek…', 'Opening notes…'),
                    style: TextStyle(fontSize: 24),
                  ),
                  const SizedBox(height: 20),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 20),
                  Text(
                    tr(
                      'Otwieranie wybranego magazynu poświadczeń. Jeśli używasz '
                          'magazynu systemowego, system może poprosić o jego odblokowanie.',
                      'Opening the selected credential store. If you use system storage, your operating system may ask you to unlock it.',
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  TextButton(
                    onPressed: NativeWindow.close,
                    child: Text(tr('Zamknij', 'Close')),
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

class StartupFailureScreen extends StatefulWidget {
  const StartupFailureScreen({
    super.key,
    required this.error,
    this.hint,
    this.onChooseFolder,
    this.onRecover,
    this.onRelocate,
    this.storageRoot,
    this.folderAccessService,
  });

  /// Original error text, selectable so it can be reported verbatim.
  final String error;

  /// Recovery guidance for either credential placement or application files.
  final String? hint;

  /// Present only for folder/database startup errors, never for keychain errors.
  final String? storageRoot;
  final WindowsFolderAccess? folderAccessService;

  /// Offered when the cause is the vault folder rather than the keychain: the
  /// notes still exist, so pointing at a copy of that folder is a real fix.
  final VoidCallback? onChooseFolder;
  final Future<String?> Function()? onRecover;

  /// Offered when the operating system blocks writes in the vault folder: the
  /// notes are intact but SQLite cannot even read them there, so the only
  /// remedy that needs no administrator is copying them to a writable folder.
  final Future<String?> Function()? onRelocate;

  static String get keychainHint => tr(
    'Nie udało się odczytać poświadczeń lub plików aplikacji. Nie usuwaj '
        'lokalnego magazynu ani ustawienia jego trybu. Jeśli używasz magazynu '
        'systemowego i macOS pyta o '
        'dostęp do klucza Silique, wybierz „Zawsze pozwalaj”, aby zapamiętać zgodę '
        'dla tego klucza. Na Linuxie sprawdź dostęp do Secret Service '
        '(np. GNOME Keyring), jeśli wybrano ten tryb. Nie utworzono zastępczego '
        'klucza dla istniejących vaultów.',
    'Could not read credentials or application files. Do not delete local credential storage or its mode preference. If you use system storage and macOS asks for access to the Silique key, choose “Always Allow” to remember permission for that key. On Linux, check access to Secret Service (such as GNOME Keyring) if you selected that mode. No replacement key has been created for existing vaults.',
  );

  @override
  State<StartupFailureScreen> createState() => _StartupFailureScreenState();
}

class _StartupFailureScreenState extends State<StartupFailureScreen> {
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  bool _recovering = false;
  bool _folderAccessBusy = false;
  bool _restartRequired = false;
  bool get _busy => _recovering || _folderAccessBusy;
  String? _recoveryError;
  String? _recoveredRoot;

  Future<void> _recover() async {
    if (_busy || widget.onRecover == null) return;
    setState(() {
      _recovering = true;
      _recoveryError = null;
    });
    try {
      final root = await widget.onRecover!();
      if (mounted && root != null) setState(() => _recoveredRoot = root);
    } catch (error) {
      NativeStorage.recordDiagnostics('recovery_failed: $error');
      if (mounted) setState(() => _recoveryError = '$error');
    } finally {
      if (mounted) setState(() => _recovering = false);
    }
  }

  Future<void> _relocate() async {
    if (_busy || widget.onRelocate == null) return;
    setState(() {
      _recovering = true;
      _recoveryError = null;
    });
    try {
      await widget.onRelocate!();
    } catch (error) {
      NativeStorage.recordDiagnostics('relocation_failed: $error');
      if (mounted) setState(() => _recoveryError = '$error');
    } finally {
      if (mounted) setState(() => _recovering = false);
    }
  }

  Future<void> _copyDiagnostics() async {
    final log = NativeStorage.readDiagnostics();
    final details = StringBuffer()
      ..writeln(tr('Silique — błąd startu', 'Silique — startup error'))
      ..writeln(widget.error);
    if (log != null && log.isNotEmpty) {
      details
        ..writeln()
        ..writeln(tr('--- diagnostyka ---', '--- diagnostics ---'))
        ..write(log);
    }
    await Clipboard.setData(ClipboardData(text: details.toString()));
    if (!mounted) return;
    _messenger.currentState?.showSnackBar(
      SnackBar(
        content: Text(
          tr(
            'Szczegóły skopiowane do schowka.',
            'Details copied to the clipboard.',
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LanguageBuilder(
    builder: (context) => SiliqueMaterialApp(
      theme: siliqueTheme(),
      scaffoldMessengerKey: _messenger,
      home: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SiliqueMark(size: 56),
                    const SizedBox(height: 24),
                    Text(
                      tr(
                        'Nie udało się otworzyć Silique',
                        'Could not open Silique',
                      ),
                      style: TextStyle(fontSize: 24),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      widget.hint ?? StartupFailureScreen.keychainHint,
                      key: const Key('startup-failure-hint'),
                    ),
                    const SizedBox(height: 16),
                    SelectableText(
                      widget.error,
                      key: const Key('startup-failure-error'),
                      contextMenuBuilder: siliqueTextContextMenu,
                      style: const TextStyle(color: muted),
                    ),
                    const SizedBox(height: 20),
                    if (widget.storageRoot != null)
                      WindowsFolderAccessPanel(
                        key: ValueKey(widget.storageRoot),
                        root: widget.storageRoot!,
                        service: widget.folderAccessService,
                        enabled: !_recovering,
                        onBusyChanged: (value) =>
                            setState(() => _folderAccessBusy = value),
                        onRestartRequired: () =>
                            setState(() => _restartRequired = true),
                      ),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        FilledButton(
                          onPressed: _busy || _restartRequired ? null : main,
                          child: Text(tr('Spróbuj ponownie', 'Try again')),
                        ),
                        if (widget.onChooseFolder != null)
                          OutlinedButton(
                            key: const Key('startup-failure-choose-folder'),
                            onPressed: _busy ? null : widget.onChooseFolder,
                            child: Text(
                              tr('Wskaż inny folder', 'Choose another folder'),
                            ),
                          ),
                        if (widget.onRecover != null)
                          OutlinedButton(
                            key: const Key('startup-failure-recover'),
                            onPressed: _busy ? null : _recover,
                            child: Text(
                              tr(
                                'Odzyskaj do nowego folderu',
                                'Recover to a new folder',
                              ),
                            ),
                          ),
                        if (widget.onRelocate != null)
                          OutlinedButton(
                            key: const Key('startup-failure-relocate'),
                            onPressed: _busy ? null : _relocate,
                            child: Text(tr('Przenieś notatki', 'Move notes')),
                          ),
                        TextButton(
                          key: const Key('startup-failure-copy'),
                          onPressed: _copyDiagnostics,
                          child: Text(
                            tr('Kopiuj diagnostykę', 'Copy diagnostics'),
                          ),
                        ),
                      ],
                    ),
                    if (widget.onRecover != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        tr(
                          'Odzyskiwanie tworzy spójną kopię przez SQLite, także ze zmianami '
                              'z dziennika WAL. Wybierz nowy lokalny folder poza obecną lokalizacją. '
                              'Oryginał, klucze i obecne miejsce zapisu zostają zachowane. '
                              'To kopia z chwili odczytu, nie automatyczna zmiana lokalizacji.',
                          'Recovery creates a consistent SQLite snapshot, including WAL changes. Choose a new local folder outside the current location. The original, keys and current storage location are preserved. This is a point-in-time copy, not an automatic location change.',
                        ),
                        style: TextStyle(color: muted),
                      ),
                    ],
                    if (widget.onRelocate != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        tr(
                          'Przenoszenie kopiuje bazę razem z dziennikiem WAL — SQLite nie '
                              'potrafi jej odczytać w zablokowanym folderze, więc kopia jest '
                              'bajtowa i sprawdzana po zapisaniu. Oryginał i klucze zostają bez '
                              'zmian, a nowe miejsce staje się miejscem zapisu notatek.',
                          'Moving copies the database together with its WAL — SQLite cannot read it in the blocked folder, so the copy is byte-for-byte and verified after writing. The original and keys remain unchanged, and the new location becomes the notes storage location.',
                        ),
                        key: Key('startup-failure-relocate-hint'),
                        style: TextStyle(color: muted),
                      ),
                    ],
                    if (_recovering) ...[
                      const SizedBox(height: 12),
                      const LinearProgressIndicator(),
                    ],
                    if (_recoveredRoot != null) ...[
                      const SizedBox(height: 12),
                      SelectableText(
                        tr(
                          'Utworzono sprawdzoną kopię: $_recoveredRoot\n'
                              'Nie została aktywowana. Zamknij inne kopie Silique; '
                              'potem użyj „Wskaż inny folder”, jeśli chcesz otworzyć tę kopię. '
                              'Późniejsze zmiany w oryginale nie znajdują się w tej kopii.',
                          'Verified copy created: $_recoveredRoot\nIt has not been activated. Close other copies of Silique, then use “Choose another folder” to open this copy if you wish. Later changes to the original are not included in this copy.',
                        ),
                        key: const Key('recovery-snapshot-ready'),
                      ),
                    ],
                    if (_recoveryError != null) ...[
                      const SizedBox(height: 12),
                      SelectableText(
                        _recoveryError!,
                        key: const Key('recovery-error'),
                      ),
                    ],
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

class SiliqueApp extends StatelessWidget {
  const SiliqueApp({super.key});
  @override
  Widget build(BuildContext context) => LanguageBuilder(
    builder: (context) => SiliqueMaterialApp(
      title: 'Silique',
      debugShowCheckedModeBanner: false,
      theme: siliqueTheme(),
      home: const HomeScreen(),
    ),
  );
}
