import '../l10n/strings.dart';

import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:cryptography/cryptography.dart';

import '../core/contracts.dart';
import '../core/models.dart';
import 'sqlite_native_error.dart';

/// Capture the exact pointer (including a missing legacy pointer) before an
/// asynchronous location change, not after the operation has already waited.
class StorageRootExpectation {
  const StorageRootExpectation(this.recorded);
  final String? recorded;
}

/// Raised when a chosen or recorded vault location cannot be used.
///
/// The app must offer to point at the existing data again instead of treating it
/// as a first run: creating an empty store would hide the notes that are still
/// on disk behind a fresh, empty vault list.
class StorageLocationUnavailable implements Exception {
  const StorageLocationUnavailable(this.path, this.reason);

  /// A readable parent does not imply that this app may write to it. Windows
  /// Controlled folder access can report "file not found" as well as "access
  /// denied". Keep the OS details, but never claim that Defender is the cause.
  factory StorageLocationUnavailable.writeFailure(
    String path,
    FileSystemException error, {
    required bool isWindows,
  }) => StorageLocationUnavailable(
    path,
    tr(
          'Nie można zapisać vaultów w katalogu $path. '
              'Sprawdź uprawnienia do zapisu lub wybierz inny katalog. ',
          'Cannot save vaults in $path. '
              'Check write permissions or choose another folder. ',
        ) +
        _writeRemedy(error, isWindows: isWindows),
  );

  /// Advice shared by every write failure, so no path invents its own cause.
  static String _writeRemedy(
    FileSystemException error, {
    required bool isWindows,
  }) =>
      '${isWindows ? tr('Dostęp w Eksploratorze nie oznacza zgody na zapis dla Silique. '
                'W Zabezpieczeniach Windows sprawdź „Historia ochrony” oraz '
                '„Ochrona przed oprogramowaniem wymuszającym okup” → '
                '„Kontrolowany dostęp do folderów”. Jeśli ochrona blokuje Silique, '
                'użyj „Zezwalaj aplikacji na dostęp przez funkcję Kontrolowany dostęp '
                'do folderów” i wskaż zainstalowany silique.exe, a następnie ponów wybór. '
                'Nie wyłączaj ochrony. ', 'Access in File Explorer does not mean Silique has write permission. '
                'In Windows Security, check “Protection history” and '
                '“Ransomware protection” → “Controlled folder access”. '
                'If protection is blocking Silique, use “Allow an app through '
                'Controlled folder access”, select the installed silique.exe, '
                'then try selecting the folder again. Do not disable protection. ') : ''}'
      '${tr('Szczegóły:', 'Details:')} $error';

  final String path;
  final String reason;
  @override
  String toString() => reason;
}

/// Raised when the folder that holds the vault exists and is readable, but the
/// operating system refuses writes from Silique.
///
/// This is not a damaged database: SQLite never reached it, so the app must not
/// suggest corrupt data, and choosing "another folder" is not enough — the notes
/// are still in this one. Controlled folder access, an antivirus filter and a
/// read-only mount look identical from Dart, so the message keeps to the folder
/// and the OS error and offers [NativeStorage.relocateBlockedRoot]: moving the
/// notes is the only remedy that does not need an administrator.
class StorageRootWriteBlocked extends StorageLocationUnavailable {
  const StorageRootWriteBlocked(super.path, super.reason);

  factory StorageRootWriteBlocked.forError(
    String root,
    FileSystemException error,
  ) {
    final summary = tr(
      'Folder $root nie przyjmuje zapisów od Silique, więc baza nie została '
          'otwarta. Nie jest uszkodzona i nie została zmieniona. ',
      'Folder $root is refusing writes from Silique, so the database was not '
          'opened. It is not damaged and has not been changed. ',
    );
    final remedy = StorageLocationUnavailable._writeRemedy(
      error,
      isWindows: Platform.isWindows,
    );
    final move = tr(
      'Jeśli nie chcesz zmieniać ustawień ochrony, użyj „Przenieś notatki”: '
          'Silique skopiuje bazę razem z dziennikiem WAL, sprawdzi kopię i włączy ją '
          'w wybranym folderze, a oryginał pozostawi bez zmian.',
      'If you do not want to change protection settings, use “Move notes”: '
          'Silique will copy the database together with its WAL journal, verify '
          'the copy and activate it in the selected folder, leaving the original unchanged.',
    );
    return StorageRootWriteBlocked(root, '$summary$remedy $move');
  }
}

/// Raised when the folder was accepted but SQLite itself cannot write.
///
/// This is a different failure from [StorageLocationUnavailable]: choosing a
/// folder again is only one of the answers, and the cause is in the operating
/// system's I/O (a locked or cloud-backed file), not in the keychain. The
/// message names the real path and the SQLite error, and it never claims that
/// notes were lost — nothing is deleted or rewritten while opening fails.
class StorageOpenFailure implements Exception {
  const StorageOpenFailure({
    required this.path,
    required this.summary,
    required this.reason,
    this.diagnostics = const {},
  });

  /// Absolute path of the database that could not be opened for writing.
  final String path;

  /// Original SQLite/Dart error text, kept verbatim for support.
  final String summary;

  /// User-facing Polish explanation with the next concrete step.
  final String reason;

  /// File and system facts collected while opening, for the diagnostics log.
  final Map<String, Object?> diagnostics;

  @override
  String toString() => reason;
}

/// The SQLite transaction is authoritative. Markdown exports are recoverable
/// mirrors; a failed mirror never discards a committed revision or outbox item.
class NativeStorage implements NoteStorage {
  /// Name of the folder created inside the platform Documents directory.
  static const vaultsFolderName = 'Silique Vaults';

  /// Set when a new installation could not use the platform Documents folder.
  ///
  /// The value is user-facing Polish text and is shown in Settings, so a failed
  /// default never silently pretends to be the requested location.
  static String? defaultLocationWarning;

  /// Whether [directory] already contains Silique data.
  static bool _hasDatabase(Directory directory) =>
      File('${directory.path}/silique.sqlite').existsSync() ||
      File('${directory.path}/nova.sqlite').existsSync();

  /// Files and folders that Silique itself creates in its root.
  static const _ownedEntries = {
    'silique.sqlite',
    'silique.sqlite-wal',
    'silique.sqlite-shm',
    'nova.sqlite',
    'nova.sqlite-wal',
    'nova.sqlite-shm',
    'markdown',
  };

  static bool _isEmptyOrOwned(Directory directory) {
    if (!directory.existsSync()) return true;
    for (final entity in directory.listSync(followLinks: false)) {
      final name = entity.path.split(Platform.pathSeparator).last;
      if (!_ownedEntries.contains(name) && !name.endsWith('.tmp')) return false;
    }
    return true;
  }

  /// Resolves the authoritative data root for an existing installation.
  ///
  /// 1. an explicitly chosen location recorded in `silique-location.txt`,
  /// 2. an existing `Application Support/Silique` database (never migrated
  ///    automatically),
  /// 3. the legacy application-support directory, renamed in place.
  ///
  /// A fresh installation has no root yet: it must ask the user where the
  /// vaults should live, so this method throws instead of silently creating a
  /// database in an application-private directory. Use [existingRoot] to test
  /// whether a location already exists.
  static String resolveRoot(String applicationSupport) {
    final existing = existingRoot(applicationSupport);
    if (existing != null) return existing;
    throw StateError(
      tr(
        'Nie wybrano miejsca zapisu vaultów. Wybierz katalog, aby utworzyć bazę.',
        'No vault storage location selected. Choose a folder to create the database.',
      ),
    );
  }

  /// Returns the existing data root, or `null` for a fresh installation.
  static String? existingRoot(String applicationSupport) {
    defaultLocationWarning = null;
    final location = File('$applicationSupport/silique-location.txt');
    if (location.existsSync()) {
      final path = location.readAsStringSync().trim();
      final directory = Directory(path);
      if (!directory.existsSync()) {
        throw StorageLocationUnavailable(
          path,
          tr(
            'Zapisany katalog danych jest niedostępny: $path. '
                'Wskaż ponownie miejsce, w którym znajdują się Twoje notatki.',
            'The saved data folder is unavailable: $path. '
                'Select the location containing your notes again.',
          ),
        );
      }
      if (_hasDatabase(directory)) return path;
      // An interrupted first run leaves an empty folder; finishing it is safe.
      // Existing Markdown/WAL without the database is recovery data, not an
      // empty installation. Never replace it with a newly created store.
      if (directory.listSync(followLinks: false).isEmpty) return path;
      throw StorageLocationUnavailable(
        path,
        tr(
          'W katalogu $path nie ma bazy Silique, a znajdują się w nim inne pliki. '
              'Wskaż miejsce z Twoimi notatkami.',
          'Folder $path does not contain a Silique database, but contains other files. '
              'Select the location containing your notes.',
        ),
      );
    }
    final current = Directory('$applicationSupport/Silique');
    final legacy = Directory('$applicationSupport/Nova Notes');
    if (legacy.existsSync()) {
      if (current.existsSync()) {
        throw StateError(
          tr(
            'Znaleziono dwa katalogi notatek. Zachowano oba; wymagają sprawdzenia przed otwarciem.',
            'Two notes folders were found. Both were preserved; they must be checked before opening.',
          ),
        );
      }
      legacy.renameSync(current.path);
    }
    return _hasDatabase(current) ? current.path : null;
  }

  /// Validates a user-selected directory and makes it the vault location.
  ///
  /// A `Silique Vaults` folder is created inside [chosenDirectory] (the chosen
  /// directory is never used directly, so unrelated files cannot mix with the
  /// database). The directory must be writable; a non-empty folder that Silique
  /// does not own is rejected instead of being overwritten. The location is
  /// recorded last, atomically, so a failed attempt never leaves a half-created
  /// vault and a cancelled dialog creates nothing at all.
  static String prepareChosenRoot(String chosenDirectory) {
    final chosen = Directory(chosenDirectory).absolute;
    if (!chosen.existsSync()) {
      throw StateError(
        tr(
          'Wybrany katalog nie istnieje: ${chosen.path}',
          'The selected folder does not exist: ${chosen.path}',
        ),
      );
    }
    final target = Directory('${chosen.path}/$vaultsFolderName');
    if (target.existsSync() && !_isEmptyOrOwned(target)) {
      throw StateError(
        tr(
          'Katalog $vaultsFolderName zawiera pliki, których Silique nie utworzyło. '
              'Wybierz inny katalog, aby nie nadpisać danych.',
          'Folder $vaultsFolderName contains files not created by Silique. '
              'Choose another folder to avoid overwriting data.',
        ),
      );
    }
    try {
      target.createSync(recursive: true);
      // A real write proves the sandbox/SAF grant covers this directory.
      final probe = File('${target.path}/.silique-write-test');
      try {
        probe.writeAsStringSync('ok', flush: true);
        if (probe.readAsStringSync() != 'ok') {
          throw FileSystemException(
            tr(
              'Nie udało się zweryfikować zapisu.',
              'Could not verify the write.',
            ),
          );
        }
      } finally {
        if (probe.existsSync()) probe.deleteSync();
      }
      return target.path;
    } on FileSystemException catch (error) {
      throw StorageLocationUnavailable.writeFailure(
        target.path,
        error,
        isWindows: Platform.isWindows,
      );
    }
  }

  /// Records [root] as the chosen location so it is reused after a restart.
  static void persistChosenRoot(
    String applicationSupport,
    String root, {
    StorageRootExpectation? expected,
  }) {
    final lock = File('$applicationSupport/silique-location.lock')
        .openSync(mode: FileMode.append);
    try {
      lock.lockSync(FileLock.exclusive);
      if (expected != null &&
          recordedRoot(applicationSupport) != expected.recorded) {
        throw StateError(
          tr(
            'Lokalizacja danych zmieniła się podczas operacji. '
                'Zachowano nowszy wybór; odzyskana kopia nie została aktywowana.',
            'The data location changed during the operation. '
                'The newer choice was preserved; the recovered copy was not activated.',
          ),
        );
      }
      final pointer = File('$applicationSupport/silique-location.txt');
      final temporary = File('${pointer.path}.tmp');
      temporary.writeAsStringSync(root, flush: true);
      temporary.renameSync(pointer.path);
    } finally {
      lock.closeSync();
    }
  }

  /// The location recorded in `silique-location.txt`, if any.
  static String? recordedRoot(String applicationSupport) {
    final pointer = File('$applicationSupport/silique-location.txt');
    if (!pointer.existsSync()) return null;
    final path = pointer.readAsStringSync().trim();
    return path.isEmpty ? null : path;
  }

  /// Adopts an existing store instead of creating an empty one.
  ///
  /// Used when the recorded location is gone (moved folder, revoked macOS
  /// permission, unmounted volume): the user points at the directory that still
  /// holds `silique.sqlite`, and the same data — with the same keys, because the
  /// keychain entry is untouched — is opened again.
  static String adoptExistingRoot(String chosenDirectory) {
    final chosen = Directory(chosenDirectory).absolute;
    for (final candidate in [chosen.path, '${chosen.path}/$vaultsFolderName']) {
      if (_hasDatabase(Directory(candidate))) return candidate;
    }
    throw StorageLocationUnavailable(
      chosen.path,
      tr(
        'W tym katalogu nie ma bazy Silique (silique.sqlite). '
            'Wskaż katalog z istniejącymi notatkami.',
        'This folder does not contain a Silique database (silique.sqlite). '
            'Select the folder containing your existing notes.',
      ),
    );
  }

  /// Proves that [root] accepts a write before SQLite is asked to open the
  /// database inside it.
  ///
  /// A folder blocked by the system (Windows Controlled folder access, an
  /// antivirus filter, a read-only mount) reaches SQLite as a generic I/O error
  /// — 778 on Windows — which points at the database file even though the file
  /// is intact, and such a folder cannot be read either: even a read-only open
  /// has to publish the WAL index. Probing here keeps the diagnosis on the
  /// folder and lets the user move the notes instead of retrying a path the
  /// system will keep refusing.
  static void verifyRootWritable(String root) {
    final directory = Directory(root);
    // A root without a database is a first run: prepareChosenRoot already
    // proved the folder, and creating the store will surface its own error.
    final existing = _hasDatabase(directory);
    try {
      directory.createSync(recursive: true);
      if (!existing) return;
      final probe = File('${directory.path}/silique-io-probe.tmp');
      try {
        probe.writeAsStringSync('ok', flush: true);
        if (probe.readAsStringSync() != 'ok') {
          throw FileSystemException(
            tr(
              'Nie potwierdzono próbnego zapisu.',
              'The test write was not confirmed.',
            ),
          );
        }
      } finally {
        if (probe.existsSync()) probe.deleteSync();
      }
    } on FileSystemException catch (error) {
      throw StorageRootWriteBlocked.forError(root, error);
    }
  }

  /// Moves a vault out of a folder that the operating system refuses to write
  /// into, without an administrator and without touching the original.
  ///
  /// SQLite's own WAL-aware backup is unavailable here — that connection fails
  /// with `SQLITE_IOERR_LOCK` inside such a folder — so the fallback is a byte
  /// copy of the database together with its write-ahead log, which is what keeps
  /// notes that were committed but not checkpointed. The same block that stops
  /// Silique stops every writer, so the files are quiescent while they are
  /// copied. The copy is staged inside [chosenDirectory], opened, checked with
  /// `quick_check` and only then renamed into place and recorded as the
  /// location. The source is never written, moved or deleted.
  static String relocateBlockedRoot(
    String applicationSupport,
    String sourceRoot,
    String chosenDirectory,
  ) {
    final source = Directory(sourceRoot).absolute;
    final databases = [
      for (final name in ['silique.sqlite', 'nova.sqlite'])
        File('${source.path}/$name'),
    ].where((file) => file.existsSync()).toList();
    if (databases.length != 1) {
      throw StateError(
        tr(
          'W folderze $sourceRoot nie ma dokładnie jednej bazy Silique. '
              'Nic nie zostało skopiowane.',
          'Folder $sourceRoot does not contain exactly one Silique database. '
              'Nothing was copied.',
        ),
      );
    }
    final database = databases.single;
    final chosen = Directory(chosenDirectory).absolute;
    if (!chosen.existsSync()) {
      throw StateError(
        tr(
          'Wybrany katalog nie istnieje: ${chosen.path}',
          'The selected folder does not exist: ${chosen.path}',
        ),
      );
    }
    final destination = '${chosen.path}/$vaultsFolderName';
    final existingTarget = Directory(destination);
    if (existingTarget.existsSync() && !_isEmptyOrOwned(existingTarget)) {
      throw StateError(
        tr(
          'Katalog $vaultsFolderName zawiera pliki, których Silique nie utworzyło. '
              'Wybierz inny katalog, aby nie nadpisać danych.',
          'Folder $vaultsFolderName contains files not created by Silique. '
              'Choose another folder to avoid overwriting data.',
        ),
      );
    }
    String comparison(String path) =>
        Platform.isWindows ? path.replaceAll('/', r'\').toLowerCase() : path;
    if (comparison(source.path) == comparison(destination)) {
      throw StateError(
        tr(
          'Nowy folder musi być inny niż zablokowany folder.',
          'The new folder must be different from the blocked folder.',
        ),
      );
    }
    Directory? stage;
    try {
      stage = chosen.createTempSync('.silique-move-');
      final name = database.uri.pathSegments.where((p) => p.isNotEmpty).last;
      for (final suffix in ['', '-wal', '-journal']) {
        final file = File('${database.path}$suffix');
        if (file.existsSync()) file.copySync('${stage.path}/$name$suffix');
      }
      // The shared-memory index is deliberately not copied: SQLite rebuilds it
      // from the log, and a stale index is the only part that would lie.
      final markdown = Directory('${source.path}/markdown');
      if (markdown.existsSync()) {
        _copyTreeWithoutLinks(markdown.path, '${stage.path}/markdown');
      }
      final documents = _verifyRelocatedCopy(
        '${stage.path}/$name',
        source.path,
      );
      if (existingTarget.existsSync()) existingTarget.deleteSync();
      stage.renameSync(destination);
      stage = null;
      persistChosenRoot(applicationSupport, destination);
      recordDiagnostics(
        'relocated_blocked_root from=${source.path} to=$destination '
        'documents=$documents',
      );
      return destination;
    } on FileSystemException catch (error) {
      throw StorageLocationUnavailable.writeFailure(
        chosen.path,
        error,
        isWindows: Platform.isWindows,
      );
    } finally {
      if (stage != null && stage.existsSync()) {
        try {
          stage.deleteSync(recursive: true);
        } catch (_) {
          /* A leftover staging folder is inert; the location was not changed. */
        }
      }
    }
  }

  /// Opens the relocated copy once and refuses to act on anything that SQLite
  /// would not read back as a healthy database.
  static int _verifyRelocatedCopy(String path, String sourceRoot) {
    final Database copy;
    try {
      copy = sqlite3.open(path);
    } on SqliteException catch (error) {
      throw StateError(
        tr(
          'Nie można otworzyć skopiowanej bazy ($error). '
              'Oryginał w $sourceRoot pozostał bez zmian.',
          'Could not open the copied database ($error). '
              'The original in $sourceRoot remains unchanged.',
        ),
      );
    }
    try {
      final check = copy.select('PRAGMA quick_check');
      if (check.length != 1 || check.single.values.single != 'ok') {
        throw StateError(
          tr(
            'Skopiowana baza nie przeszła quick_check. '
                'Oryginał w $sourceRoot pozostał bez zmian.',
            'The copied database failed quick_check. '
                'The original in $sourceRoot remains unchanged.',
          ),
        );
      }
      return copy.select('SELECT count(*) AS n FROM documents').single['n']
          as int;
    } on SqliteException catch (error) {
      throw StateError(
        tr(
          'Nie udało się sprawdzić skopiowanej bazy ($error). '
              'Oryginał w $sourceRoot pozostał bez zmian.',
          'Could not verify the copied database ($error). '
              'The original in $sourceRoot remains unchanged.',
        ),
      );
    } finally {
      copy.close();
    }
  }

  /// Copies a Markdown mirror byte-for-byte. Links are skipped, never followed.
  static void _copyTreeWithoutLinks(String from, String to) {
    Directory(to).createSync(recursive: true);
    for (final entry in Directory(from).listSync(followLinks: false)) {
      final name = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
      if (entry is File) {
        entry.copySync('$to/$name');
      } else if (entry is Directory) {
        _copyTreeWithoutLinks(entry.path, '$to/$name');
      }
    }
  }

  /// Checkpoints a legacy `nova.sqlite` WAL before renaming, so no journal
  /// frames are lost or carry a stale path across the rename.
  static void _checkpointLegacy(File legacy) {
    final previous = sqlite3.open(legacy.path);
    try {
      previous.execute('PRAGMA busy_timeout=5000');
      final checkpoint = previous.select('PRAGMA wal_checkpoint(TRUNCATE)');
      if (checkpoint.isNotEmpty && checkpoint.first.values.first != 0) {
        throw StateError(
          tr(
            'Baza notatek jest używana. Zamknij poprzednią wersję aplikacji.',
            'The notes database is in use. Close the previous version of the app.',
          ),
        );
      }
    } finally {
      previous.close();
    }
  }

  static void _clearPendingRename(File marker) {
    try {
      if (marker.existsSync()) marker.deleteSync();
    } catch (_) {
      // A stale marker only triggers a redundant retry on the next launch.
    }
  }

  NativeStorage(this.root, {bool? exclusiveAccess})
    : _exclusiveAccess = exclusiveAccess ?? Platform.isWindows {
    Directory(root).createSync(recursive: true);
    final legacy = File('$root/nova.sqlite');
    final current = File('$root/silique.sqlite');
    final pendingMarker = File('$root/.silique-pending-rename');
    if (legacy.existsSync()) {
      if (current.existsSync()) {
        throw StateError(
          tr(
            'Znaleziono dwie bazy notatek. Żadnej nie nadpisano.',
            'Two notes databases were found. Neither was overwritten.',
          ),
        );
      }
      _checkpointLegacy(legacy);
      // A prior failed rename (missing write permission) retries here. Neither
      // outcome is a startup error: success activates silique.sqlite, failure
      // keeps running on nova.sqlite with the pending marker for the next try.
      try {
        legacy.renameSync(current.path);
        _clearPendingRename(pendingMarker);
        _databaseFile = current;
      } on FileSystemException {
        _databaseFile = legacy;
        try {
          pendingMarker.writeAsStringSync('');
        } catch (_) {
          // The marker is best-effort; a missing marker only delays the retry.
        }
      }
    } else if (pendingMarker.existsSync()) {
      // The previous run already fell back to nova.sqlite, but that database is
      // gone now (e.g. it was concurrently renamed). Start fresh on the new
      // name and clear the stale marker.
      _databaseFile = current;
      _clearPendingRename(pendingMarker);
    } else {
      _databaseFile = current;
    }
    final existingDatabase =
        _databaseFile.existsSync() && _databaseFile.lengthSync() > 0;
    db = _openDatabase(_databaseFile);
    try {
      _configureJournal(existingDatabase: existingDatabase);
      db.execute(
        'CREATE TABLE IF NOT EXISTS vaults(id TEXT PRIMARY KEY,data TEXT NOT NULL)',
      );
      db.execute(
        'CREATE TABLE IF NOT EXISTS documents(vault_id TEXT NOT NULL,note_id TEXT NOT NULL,data TEXT NOT NULL,PRIMARY KEY(vault_id,note_id))',
      );
      db.execute(
        'CREATE TABLE IF NOT EXISTS revisions(id TEXT PRIMARY KEY,vault_id TEXT NOT NULL,note_id TEXT NOT NULL,parents TEXT NOT NULL,payload TEXT NOT NULL,seq INTEGER NOT NULL,pending INTEGER NOT NULL)',
      );
      db.execute(
        'CREATE TABLE IF NOT EXISTS batches(vault_id TEXT PRIMARY KEY,data TEXT NOT NULL)',
      );
      db.execute(
        'CREATE TABLE IF NOT EXISTS cursors(vault_id TEXT PRIMARY KEY,cursor INTEGER NOT NULL)',
      );
      db.execute(
        'CREATE INDEX IF NOT EXISTS revisions_vault ON revisions(vault_id,note_id)',
      );
      db.execute(
        'CREATE TABLE IF NOT EXISTS image_assets(vault_id TEXT NOT NULL,note_id TEXT NOT NULL,id TEXT NOT NULL,manifest TEXT NOT NULL,uploaded INTEGER NOT NULL,PRIMARY KEY(vault_id,id))',
      );
      db.execute(
        'CREATE TABLE IF NOT EXISTS image_chunks(vault_id TEXT NOT NULL,asset_id TEXT NOT NULL,chunk_index INTEGER NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(vault_id,asset_id,chunk_index),FOREIGN KEY(vault_id,asset_id) REFERENCES image_assets(vault_id,id) ON DELETE CASCADE)',
      );
      db.execute(
        'CREATE TABLE IF NOT EXISTS vault_deletion_intents(vault_id TEXT PRIMARY KEY,payload TEXT NOT NULL)',
      );
      db.execute(
        'CREATE TABLE IF NOT EXISTS deleted_vaults(vault_id TEXT PRIMARY KEY)',
      );
      db.execute(
        'CREATE TABLE IF NOT EXISTS vault_deletion_cleanup(vault_id TEXT PRIMARY KEY)',
      );
      for (final table in [
        'vaults',
        'documents',
        'revisions',
        'batches',
        'cursors',
        'image_assets',
        'image_chunks',
      ]) {
        final column = table == 'vaults' ? 'id' : 'vault_id';
        String blocked(String row) {
          final field = '$row.$column';
          final base =
              '(CASE ${_namespacePrefixes.map((p) => "WHEN substr($field,1,${p.length})='$p' THEN substr($field,${p.length + 1})").join(' ')} ELSE $field END)';
          return 'EXISTS(SELECT 1 FROM deleted_vaults WHERE vault_id=$base) OR '
              'EXISTS(SELECT 1 FROM vault_deletion_intents WHERE vault_id=$base)';
        }

        for (final action in ['INSERT', 'UPDATE']) {
          // Persist the fence in SQLite too: another connection/older binary can
          // otherwise pass a preflight check just before deletion commits.
          db.execute(
            '''CREATE TRIGGER IF NOT EXISTS vault_write_fence_${table}_$action
          BEFORE $action ON $table
          WHEN (${blocked('NEW')}) ${action == 'UPDATE' ? 'OR (${blocked('OLD')})' : ''}
          BEGIN SELECT RAISE(ABORT, 'Vault deletion is pending or committed'); END''',
          );
        }
      }
      db.execute('PRAGMA user_version=1');
      _checkpoint();
      // Revisit even completed tombstones: a crash can occur after removing the
      // cleanup marker but before the final checkpoint truncates its WAL frame.
      // Pending remote intents without tombstones must NEVER be auto-erased.
      for (final row in db.select('SELECT vault_id FROM deleted_vaults')) {
        final vaultId = row['vault_id'] as String;
        _validateDeletionId(vaultId);
        _finishVaultDeletion(vaultId);
      }
    } catch (error, stack) {
      final failure = error is SqliteException
          ? _openFailure(current, error)
          : error;
      // A half-opened database must not stay locked. On Windows a leaked handle
      // keeps the file busy for the retry, the updater and any copy the user
      // makes, and it turned one failed start into a folder that stayed stuck.
      try {
        db.close();
      } catch (_) {
        /* The connection may already be unusable. */
      }
      Error.throwWithStackTrace(failure, stack);
    }
  }

  /// How many times a refused file operation is retried while opening.
  ///
  /// Antivirus scanners, cloud-sync clients and the Windows installer can hold
  /// a handle on the database for a moment right after launch. A single attempt
  /// turned such a transient lock into the permanent "Spróbuj ponownie" screen.
  static const _startupAttempts = 3;
  static const _startupRetryDelay = Duration(milliseconds: 300);

  /// Folder where startup diagnostics are appended. Set by `main` to the
  /// application support directory, so a failure leaves a record outside the
  /// vault folder. Never inside the vault: that folder holds user data.
  static String? diagnosticsDirectory;
  static const diagnosticsFileName = 'silique-diagnostics.log';
  static const _diagnosticsLimit = 64 * 1024;

  /// Journal mode the open database really uses: `wal`, or `delete` when the
  /// folder refused WAL files. Silique writes from a single connection, so a
  /// rollback journal keeps the same durability guarantees.
  String get journalMode => _journalMode;
  String _journalMode = 'unknown';

  bool _closed = false;

  /// Appends one line to the diagnostics log, ignoring failures.
  ///
  /// Diagnostics must never turn a recoverable start into a crash, and the log
  /// lives outside the vault so it cannot disturb the owned-file check.
  static void recordDiagnostics(String message) {
    final directory = diagnosticsDirectory;
    if (directory == null) return;
    try {
      Directory(directory).createSync(recursive: true);
      final file = File('$directory/$diagnosticsFileName');
      if (file.existsSync() && file.lengthSync() > _diagnosticsLimit) {
        final text = file.readAsStringSync();
        file.writeAsStringSync(text.substring(text.length ~/ 2));
      }
      file.writeAsStringSync(
        '[${DateTime.now().toUtc().toIso8601String()}] $message\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      /* A missing or unwritable log must not stop the application. */
    }
  }

  /// The diagnostics log as shown/copied from the startup failure screen.
  static String? readDiagnostics() {
    final directory = diagnosticsDirectory;
    if (directory == null) return null;
    try {
      final file = File('$directory/$diagnosticsFileName');
      return file.existsSync() ? file.readAsStringSync() : null;
    } catch (_) {
      return null;
    }
  }

  /// Opens the database, retrying a transient lock instead of giving up.
  Database _openDatabase(File file) {
    prepareNativeErrorCapture();
    SqliteException? failure;
    for (var attempt = 1; attempt <= _startupAttempts; attempt++) {
      try {
        return sqlite3.open(file.path);
      } on SqliteException catch (error) {
        failure = error;
        if (attempt < _startupAttempts) sleep(_startupRetryDelay);
      }
    }
    throw _openFailure(file, failure!);
  }

  /// Preserve persisted mode when reopening. SQLITE_IOERR_WRITE (778) is a
  /// failure of a VFS write, not evidence that only WAL is unavailable. Switching
  /// to DELETE needs the same recovery/checkpoint and is not a repair.
  /// Only a new, empty database needs an initial journal-mode setter.
  void _configureJournal({required bool existingDatabase}) {
    db.execute('PRAGMA busy_timeout=5000');
    if (_exclusiveAccess) {
      // Must precede the FIRST schema/journal access. With exclusive locking
      // SQLite keeps the WAL index in process memory, bypassing the stale SHM
      // mapping/zero-header write path that can fail with IOERR_WRITE on Windows.
      // The real database lock remains enforced: another active client yields
      // BUSY, never a concurrent writer without coordination.
      db.execute('PRAGMA locking_mode=EXCLUSIVE');
    }
    if (!existingDatabase) db.execute('PRAGMA journal_mode=WAL');
    _journalMode =
        db.select('PRAGMA journal_mode').single.values.single as String;
    db.execute(
      'PRAGMA foreign_keys=ON; PRAGMA secure_delete=ON; PRAGMA synchronous=FULL',
    );
    _verifyWritable();
  }

  /// Proves the database accepts writes before the notebook is handed to the UI.
  ///
  /// The probe is rolled back, so a start is never reported as successful for a
  /// file that only supports reads.
  void _verifyWritable() {
    final file = File(_databaseFile.path);
    var began = false;
    try {
      db.execute('BEGIN IMMEDIATE');
      began = true;
      db.execute(
        'CREATE TABLE IF NOT EXISTS silique_io_probe(id INTEGER PRIMARY KEY)',
      );
      db.execute('INSERT OR REPLACE INTO silique_io_probe(id) VALUES(1)');
    } on SqliteException catch (error) {
      throw _openFailure(file, error);
    } finally {
      if (began) {
        try {
          db.execute('ROLLBACK');
        } catch (_) {
          /* The transaction may already be gone after an I/O failure. */
        }
      }
    }
  }

  /// Truncates a leftover WAL so the next launch has nothing to recover.
  void _checkpoint() {
    if (_journalMode != 'wal') return;
    try {
      db.select('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (_) {
      /* A busy reader keeps frames; that is not a start-up error. */
    }
  }

  /// Builds the failure with the real path, the SQLite error and file facts.
  StorageOpenFailure _openFailure(
    File file,
    SqliteException error, {
    Map<String, Object?> extra = const {},
  }) {
    final nativeError = sqliteNativeError();
    final parent = file.parent.path;
    final cloud = _cloudSyncMarker(parent);
    final facts = <String, Object?>{
      'path': file.path,
      'exists': file.existsSync(),
      'bytes': file.existsSync() ? file.lengthSync() : 0,
      'wal_present': File('${file.path}-wal').existsSync(),
      'shm_present': File('${file.path}-shm').existsSync(),
      'platform': Platform.operatingSystem,
      'sqlite': sqlite3.version.libVersion,
      'sqlite_primary_code': error.resultCode,
      'sqlite_extended_code': error.extendedResultCode,
      'sqlite_error_name': switch (error.extendedResultCode) {
        778 => 'SQLITE_IOERR_WRITE',
        5 => 'SQLITE_BUSY',
        6 => 'SQLITE_LOCKED',
        8 => 'SQLITE_READONLY',
        _ => 'SQLITE_${error.resultCode}',
      },
      ...nativeError,
      'journal_mode': _journalMode,
      'exclusive_access': _exclusiveAccess,
      'cloud_folder': ?cloud,
      ...extra,
    };
    recordDiagnostics(
      'storage_open_failure ${facts.entries.map((e) => '${e.key}=${e.value}').join(' ')}\n'
      '  sqlite_error: $error',
    );
    final buffer = StringBuffer()
      ..write(
        tr(
          'Nie można otworzyć bazy notatek w ${file.path}. '
              'SQLite zgłosił błąd (${error.message.trim()}). '
              'Nie usunięto bazy, dziennika WAL ani kluczy. ',
          'Could not open the notes database at ${file.path}. '
              'SQLite reported an error (${error.message.trim()}). '
              'The database, WAL journal and keys were not deleted. ',
        ),
      );
    if (error.resultCode == 5 || error.resultCode == 6) {
      buffer.write(
        tr(
          'Zamknij inne uruchomione kopie Silique korzystające z tego folderu. ',
          'Close other running copies of Silique using this folder. ',
        ),
      );
    }
    if (cloud != null) {
      buffer.write(
        tr(
          'Ten folder wygląda na synchronizowany z chmurą ($cloud); klient '
              'synchronizacji potrafi zablokować pliki bazy na czas wysyłania. ',
          'This folder appears to be cloud-synced ($cloud); the sync client '
              'may lock database files while uploading. ',
        ),
      );
    }
    if (Platform.isWindows) {
      buffer.write(
        tr(
          'Sprawdź w Zabezpieczeniach Windows „Ochrona przed oprogramowaniem '
              'wymuszającym okup” → „Kontrolowany dostęp do folderów”, czy Silique nie '
              'jest blokowany. ',
          'In Windows Security, check “Ransomware protection” → '
              '“Controlled folder access” to see whether Silique is being blocked. ',
        ),
      );
    }
    buffer.write(
      tr(
        'Zamknij inne programy i naciśnij „Spróbuj ponownie”; możesz też wskazać '
            'istniejący folder danych. Aby zachować także zmiany z dziennika WAL, '
            'użyj „Odzyskaj do nowego folderu” zamiast kopiować sam plik bazy.',
        'Close other programs and press “Try again”; you can also select '
            'an existing data folder. To preserve changes in the WAL journal too, '
            'use “Recover to a new folder” instead of copying only the database file.',
      ),
    );
    return StorageOpenFailure(
      path: file.path,
      summary: '$error',
      reason: buffer.toString(),
      diagnostics: facts,
    );
  }

  /// Recognises a sync-client folder to *adjust the wording*, never to claim a
  /// diagnosis: the block can equally come from antivirus or a locked volume.
  static String? _cloudSyncMarker(String path) {
    const markers = {
      'onedrive': 'OneDrive',
      'dropbox': 'Dropbox',
      'google drive': 'Dysk Google',
      'googledrive': 'Dysk Google',
      'icloud': 'iCloud',
      'creative cloud files': 'Creative Cloud',
    };
    final lower = path.toLowerCase();
    for (final entry in markers.entries) {
      if (lower.contains(entry.key)) return entry.value;
    }
    return null;
  }

  final String root;
  final bool _exclusiveAccess;
  late final Database db;

  /// The database file actually opened this run: `silique.sqlite` once the
  /// legacy rename has succeeded, or `nova.sqlite` while a rename is still
  /// pending (never blocks startup; the rename is retried on the next launch).
  late final File _databaseFile;

  /// Exposed for tests: true when the legacy rename could not complete and the
  /// app is running on `nova.sqlite` with a retry scheduled for the next start.
  bool get pendingRename => _databaseFile.path.endsWith('nova.sqlite');

  static void _validateDeletionId(String vaultId) {
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(vaultId)) {
      throw const FormatException('Invalid vault identifier');
    }
  }

  @override
  Future<Map<String, String>> deletionIntents() async => {
    for (final row in db.select(
      'SELECT vault_id,payload FROM vault_deletion_intents',
    ))
      row['vault_id'] as String: row['payload'] as String,
  };

  @override
  Future<void> beginVaultDeletion(String vaultId, String payload) async {
    _validateDeletionId(vaultId);
    if (isVaultDeleted(vaultId)) throw StateError('Vault already deleted');
    db.execute('INSERT OR REPLACE INTO vault_deletion_intents VALUES(?,?)', [
      vaultId,
      payload,
    ]);
  }

  @override
  Future<void> cancelVaultDeletion(String vaultId) async {
    _validateDeletionId(vaultId);
    if (isVaultDeleted(vaultId)) throw StateError('Vault already deleted');
    db.execute('DELETE FROM vault_deletion_intents WHERE vault_id=?', [
      vaultId,
    ]);
  }

  @override
  bool isVaultDeleted(String vaultId) => db.select(
    'SELECT 1 FROM deleted_vaults WHERE vault_id=?',
    [vaultId],
  ).isNotEmpty;

  static const _namespacePrefixes = [
    'hidden:',
    'hidden-sync:',
    'hidden-config:',
    'hidden-retired:',
  ];

  static String _baseVaultId(String namespace) {
    for (final prefix in _namespacePrefixes) {
      if (namespace.startsWith(prefix)) {
        return namespace.substring(prefix.length);
      }
    }
    return namespace;
  }

  void _requireWritable(String namespace, {bool create = false}) {
    final vaultId = _baseVaultId(namespace);
    if (isVaultDeleted(vaultId) ||
        db.select('SELECT 1 FROM vault_deletion_intents WHERE vault_id=?', [
          vaultId,
        ]).isNotEmpty) {
      throw StateError('Vault deletion is pending or committed');
    }
    if (!create &&
        db.select('SELECT 1 FROM vaults WHERE id=?', [vaultId]).isEmpty) {
      throw StateError('Unknown vault');
    }
  }

  @override
  Future<void> eraseVault(String vaultId) async {
    _validateDeletionId(vaultId);
    atomic(() {
      db.execute('INSERT OR IGNORE INTO deleted_vaults VALUES(?)', [vaultId]);
      db.execute('INSERT OR IGNORE INTO vault_deletion_cleanup VALUES(?)', [
        vaultId,
      ]);
      final namespaces = [
        vaultId,
        for (final p in _namespacePrefixes) '$p$vaultId',
      ];
      for (final table in [
        'image_chunks',
        'image_assets',
        'documents',
        'revisions',
        'batches',
        'cursors',
      ]) {
        db.execute(
          'DELETE FROM $table WHERE vault_id IN (?,?,?,?,?)',
          namespaces,
        );
      }
      db.execute('DELETE FROM vaults WHERE id=?', [vaultId]);
    });
    _finishVaultDeletion(vaultId);
  }

  void _checkpointDeletion() {
    final checkpoint = db.select('PRAGMA wal_checkpoint(TRUNCATE)');
    if (checkpoint.isEmpty || checkpoint.first.values.first != 0) {
      throw StateError('Vault deleted; local WAL cleanup is pending');
    }
  }

  void _finishVaultDeletion(String vaultId) {
    final markdown = '$root/markdown';
    final parentType = FileSystemEntity.typeSync(markdown, followLinks: false);
    if (parentType != FileSystemEntityType.notFound &&
        parentType != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Unsafe mirror parent; local cleanup is pending',
        markdown,
      );
    }
    if (parentType == FileSystemEntityType.directory) {
      _deleteMirrorEntry('$markdown/$vaultId');
    }
    _checkpointDeletion();
    final intents = db.select(
      'SELECT payload FROM vault_deletion_intents WHERE vault_id=?',
      [vaultId],
    );
    final payload = intents.isEmpty
        ? null
        : intents.single['payload'] as String;
    atomic(() {
      db.execute('DELETE FROM vault_deletion_intents WHERE vault_id=?', [
        vaultId,
      ]);
      db.execute('DELETE FROM vault_deletion_cleanup WHERE vault_id=?', [
        vaultId,
      ]);
    });
    try {
      _checkpointDeletion();
    } catch (_) {
      atomic(() {
        db.execute('INSERT OR IGNORE INTO vault_deletion_cleanup VALUES(?)', [
          vaultId,
        ]);
        if (payload != null) {
          db.execute(
            'INSERT OR REPLACE INTO vault_deletion_intents VALUES(?,?)',
            [vaultId, payload],
          );
        }
      });
      rethrow;
    }
  }

  /// Never follow a link, including broken links and links nested in an
  /// interrupted mirror. The managed UUID child alone belongs to this vault.
  static void _deleteMirrorEntry(String path) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type == FileSystemEntityType.link) {
      Link(path).deleteSync();
    } else if (type == FileSystemEntityType.directory) {
      for (final child in Directory(path).listSync(followLinks: false)) {
        _deleteMirrorEntry(child.path);
      }
      Directory(path).deleteSync();
    } else {
      File(path).deleteSync();
    }
  }

  @override
  List<Vault> vaults() => db
      .select('SELECT data FROM vaults')
      .map((r) => Vault.fromJson(jsonDecode(r['data'] as String) as Json))
      .toList();
  @override
  void putVault(Vault vault) {
    _requireWritable(vault.id, create: true);
    db.execute('INSERT OR REPLACE INTO vaults VALUES(?,?)', [
      vault.id,
      jsonEncode(vault.toJson()),
    ]);
  }

  @override
  Map<String, String> documents(String vaultId) => {
    for (final r in db.select(
      'SELECT note_id,data FROM documents WHERE vault_id=?',
      [vaultId],
    ))
      r['note_id'] as String: r['data'] as String,
  };
  @override
  void putDocument(String vaultId, String noteId, String document) {
    _requireWritable(vaultId);
    db.execute('INSERT OR REPLACE INTO documents VALUES(?,?,?)', [
      vaultId,
      noteId,
      document,
    ]);
  }

  @override
  void removeDocument(String vaultId, String noteId) {
    _requireWritable(vaultId);
    db.execute('DELETE FROM documents WHERE vault_id=? AND note_id=?', [
      vaultId,
      noteId,
    ]);
  }

  @override
  List<Revision> revisions(String vaultId, {String? noteId}) => db
      .select(
        'SELECT * FROM revisions WHERE vault_id=? ${noteId == null ? '' : 'AND note_id=?'} ORDER BY rowid',
        [vaultId, ?noteId],
      )
      .map(
        (r) => Revision(
          id: r['id'] as String,
          vaultId: vaultId,
          noteId: r['note_id'] as String,
          parents: (jsonDecode(r['parents'] as String) as List).cast<String>(),
          payload: r['payload'] as String,
          seq: r['seq'] as int,
        ),
      )
      .toList();
  @override
  void putRevision(Revision r, {bool pending = false}) {
    _requireWritable(r.vaultId);
    db.execute(
      'INSERT INTO revisions VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET seq=MAX(seq,excluded.seq)',
      [
        r.id,
        r.vaultId,
        r.noteId,
        jsonEncode(r.parents),
        r.payload,
        r.seq,
        pending ? 1 : 0,
      ],
    );
  }

  @override
  List<Revision> pending(String vaultId) {
    final ids = db
        .select(
          'SELECT id FROM revisions WHERE vault_id=? AND pending=1 ORDER BY rowid LIMIT 100',
          [vaultId],
        )
        .map((r) => r['id'])
        .toSet();
    return revisions(vaultId).where((r) => ids.contains(r.id)).toList();
  }

  @override
  Json? batch(String vaultId) {
    final rows = db.select('SELECT data FROM batches WHERE vault_id=?', [
      vaultId,
    ]);
    return rows.isEmpty
        ? null
        : jsonDecode(rows.first['data'] as String) as Json;
  }

  @override
  void putBatch(String vaultId, Json batch) {
    _requireWritable(vaultId);
    db.execute('INSERT OR REPLACE INTO batches VALUES(?,?)', [
      vaultId,
      jsonEncode(batch),
    ]);
  }

  @override
  void acknowledge(String vaultId, List<String> ids) {
    _requireWritable(vaultId);
    for (final id in ids) {
      db.execute('UPDATE revisions SET pending=0 WHERE id=? AND vault_id=?', [
        id,
        vaultId,
      ]);
    }
    db.execute('DELETE FROM batches WHERE vault_id=?', [vaultId]);
  }

  @override
  int cursor(String vaultId) {
    final rows = db.select('SELECT cursor FROM cursors WHERE vault_id=?', [
      vaultId,
    ]);
    return rows.isEmpty ? 0 : rows.first['cursor'] as int;
  }

  @override
  void setCursor(String vaultId, int cursor) {
    _requireWritable(vaultId);
    db.execute('INSERT OR REPLACE INTO cursors VALUES(?,?)', [vaultId, cursor]);
  }

  @override
  void atomic(void Function() operation) {
    db.execute('BEGIN IMMEDIATE');
    try {
      operation();
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> mirror(Note note) async {
    _requireWritable(note.vaultId);
    // IDs, rather than untrusted user titles/paths, form all filesystem paths.
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(note.id) ||
        !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(note.vaultId)) {
      throw const FormatException('Invalid note identifier');
    }
    final directory = Directory('$root/markdown/${note.vaultId}');
    await directory.create(recursive: true);
    _requireWritable(note.vaultId);
    final target = File('${directory.path}/${note.id}.md');
    if (note.deleted) {
      if (await target.exists()) await target.delete();
      return;
    }
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(
      '# ${note.title}\n\n${note.body}',
      flush: true,
    );
    _requireWritable(note.vaultId);
    if (Platform.isWindows && await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }

  @override
  Future<void> eraseNote(
    String vaultId,
    String noteId, {
    List<String> retainImages = const [],
    String? hiddenDocument,
  }) async {
    _requireWritable(vaultId);
    atomic(() {
      for (final row in db.select(
        'SELECT id FROM image_assets WHERE vault_id=? AND note_id=?',
        [vaultId, noteId],
      )) {
        if (!retainImages.contains(row['id'])) {
          db.execute('DELETE FROM image_assets WHERE vault_id=? AND id=?', [
            vaultId,
            row['id'],
          ]);
        }
      }
      db.execute('DELETE FROM documents WHERE vault_id=? AND note_id=?', [
        vaultId,
        noteId,
      ]);
      db.execute('DELETE FROM revisions WHERE vault_id=? AND note_id=?', [
        vaultId,
        noteId,
      ]);
      for (final row in db.select(
        'SELECT id FROM image_assets a WHERE vault_id=? AND NOT EXISTS (SELECT 1 FROM documents d WHERE d.vault_id=a.vault_id AND d.note_id=a.note_id)',
        [vaultId],
      )) {
        if (!retainImages.contains(row['id'])) {
          db.execute('DELETE FROM image_assets WHERE vault_id=? AND id=?', [
            vaultId,
            row['id'],
          ]);
        }
      }
      if (hiddenDocument != null) {
        putDocument('hidden:$vaultId', noteId, hiddenDocument);
      }
    });
    final file = File('$root/markdown/$vaultId/$noteId.md');
    if (await file.exists()) await file.delete();
    final temporary = File('${file.path}.tmp');
    if (await temporary.exists()) await temporary.delete();
    // Deleted rows can otherwise remain in older WAL frames even when the
    // current tables no longer contain them. Do not claim successful hiding
    // while an active reader prevents truncating those former plaintext pages.
    final checkpoint = db.select('PRAGMA wal_checkpoint(TRUNCATE)');
    if (checkpoint.isNotEmpty && checkpoint.first.values.first != 0) {
      throw StateError(
        tr(
          'Zamknij inne procesy korzystające z bazy i ponów operację.',
          'Close other processes using the database and try again.',
        ),
      );
    }
  }

  @override
  Json? imageAsset(String vaultId, String id) {
    final rows = db.select(
      'SELECT * FROM image_assets WHERE vault_id=? AND id=?',
      [vaultId, id],
    );
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.single);
  }

  @override
  List<Json> pendingImages(String vaultId) => db
      .select('SELECT * FROM image_assets WHERE vault_id=? AND uploaded=0', [
        vaultId,
      ])
      .map((row) => Map<String, dynamic>.from(row))
      .toList();
  @override
  void putImageAsset(
    String vaultId,
    String noteId,
    String id,
    String manifest, {
    required bool uploaded,
  }) {
    _requireWritable(vaultId);
    final existing = imageAsset(vaultId, id);
    if (existing != null &&
        (existing['note_id'] != noteId || existing['manifest'] != manifest)) {
      throw StateError(
        tr('Niezgodna tożsamość załącznika.', 'Attachment identity mismatch.'),
      );
    }
    db.execute('INSERT OR IGNORE INTO image_assets VALUES(?,?,?,?,?)', [
      vaultId,
      noteId,
      id,
      manifest,
      uploaded ? 1 : 0,
    ]);
  }

  @override
  void putImageChunk(String vaultId, String id, int index, String payload) {
    _requireWritable(vaultId);
    db.execute('INSERT OR REPLACE INTO image_chunks VALUES(?,?,?,?)', [
      vaultId,
      id,
      index,
      payload,
    ]);
  }

  @override
  String? imageChunk(String vaultId, String id, int index) {
    final rows = db.select(
      'SELECT payload FROM image_chunks WHERE vault_id=? AND asset_id=? AND chunk_index=?',
      [vaultId, id, index],
    );
    return rows.isEmpty ? null : rows.single['payload'] as String;
  }

  @override
  void markImageUploaded(String vaultId, String id) {
    _requireWritable(vaultId);
    db.execute('UPDATE image_assets SET uploaded=1 WHERE vault_id=? AND id=?', [
      vaultId,
      id,
    ]);
  }

  Future<NativeStorage> relocate(
    String destination,
    String applicationSupport,
  ) async {
    final target = Directory(destination).absolute;
    final source = Directory(root).absolute;
    if (target.path == source.path ||
        target.path.startsWith('${source.path}/')) {
      throw StateError(
        tr(
          'Wybierz katalog poza obecnym miejscem zapisu.',
          'Choose a folder outside the current storage location.',
        ),
      );
    }
    if (target.existsSync() && target.listSync().isNotEmpty) {
      throw StateError(
        tr(
          'Katalog docelowy musi być pusty.',
          'The destination folder must be empty.',
        ),
      );
    }
    db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    target.createSync(recursive: true);
    try {
      for (final entity in source.listSync(
        recursive: true,
        followLinks: false,
      )) {
        final relative = entity.path.substring(source.path.length);
        if (relative.endsWith('-wal') || relative.endsWith('-shm')) continue;
        if (entity is Directory) {
          Directory('${target.path}$relative').createSync(recursive: true);
        }
        if (entity is File) {
          final copy = await entity.copy('${target.path}$relative');
          final originalHash = await Sha256().hash(await entity.readAsBytes());
          final copyHash = await Sha256().hash(await copy.readAsBytes());
          if (base64Encode(originalHash.bytes) !=
              base64Encode(copyHash.bytes)) {
            throw StateError(
              tr('Niepełna kopia danych.', 'Incomplete data copy.'),
            );
          }
        }
      }
      final replacement = NativeStorage(target.path);
      if (replacement.db
              .select('PRAGMA integrity_check')
              .single
              .values
              .single !=
          'ok') {
        await replacement.close();
        throw StateError(
          tr(
            'Weryfikacja kopii bazy nie powiodła się.',
            'Database copy verification failed.',
          ),
        );
      }
      final pointer = File('$applicationSupport/silique-location.txt');
      final temporary = File('${pointer.path}.tmp');
      try {
        await temporary.writeAsString(target.path, flush: true);
        await temporary.rename(pointer.path);
      } catch (_) {
        await replacement.close();
        rethrow;
      }
      await close();
      // Keep the original as a recovery copy; the pointer makes the new root authoritative.
      return replacement;
    } catch (_) {
      rethrow;
    }
  }

  /// Checkpoints committed WAL pages without changing their durability.
  ///
  /// Normal window close uses PASSIVE: readers may still need committed frames,
  /// and waiting for their release is unrelated to saving the editor. Retain
  /// those frames for SQLite recovery, never delete/truncate sidecars manually.
  /// Callers explicitly requiring an empty WAL keep the truncating behaviour.
  /// The updater has its own strict, result-checked checkpoint after quiescence.
  void checkpointJournal({bool truncate = true}) {
    if (truncate) {
      _checkpoint();
    } else if (_journalMode == 'wal') {
      db.select('PRAGMA wal_checkpoint(PASSIVE)');
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _checkpoint();
    db.close();
  }
}
