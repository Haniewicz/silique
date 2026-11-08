import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqlite3/sqlite3.dart';

/// Test-only fault boundary immediately before the first source schema read.
@visibleForTesting
void Function(Database source, bool exclusive)? debugRecoveryBeforeSourceRead;

/// Explicit, WAL-aware recovery into a different empty user-selected directory.
///
/// The entire SQLite database is backed up without interpreting tables, IDs,
/// ciphertext, tombstones, outbox receipts or key metadata. No SecureKeys are
/// read or generated, and no location pointer is changed. After this returns,
/// the caller must open/initialize the result with its existing keys and only
/// then persist the new location. Other source-root files are not adopted.
///
/// Source connections always use [OpenMode.readOnly], never `immutable`.
/// This helper issues no source data writes, permission/journal changes or
/// source-file deletions. SQLite itself can update/rebuild SHM read marks even
/// on a read-only connection: this is not a byte-for-byte forensic SHM image.
/// Ordinary readers can coexist with a WAL writer. A source I/O/SHM admission
/// failure gets at most one fresh, read-only EXCLUSIVE attempt, before any
/// schema access, so SQLite can use an in-memory WAL index. Real database locks
/// still apply. POSIX may reject that attempt with IOERR_LOCK because its
/// read-only descriptor cannot acquire a write lock; recovery then fails closed.
///
/// Lock waits are zero, the source snapshot is pinned and the private target
/// is exclusively locked before a single all-pages backup step. This avoids
/// sqlite3's retrying backup-stream path; it is not a hard wall-clock deadline
/// on a blocked native filesystem call. There is no raw DB/WAL copy fallback.
///
/// Markdown is copied byte-for-byte without link traversal, but is not part of
/// the SQLite transaction. Close other app instances for a quiescent mirror.
/// Filesystem checks reject existing links/overlaps and unexpected files;
/// Dart path-based APIs cannot guarantee safety against a hostile process
/// replacing filesystem entries between a check and a native open/rename.
abstract final class NativeStorageRecovery {
  static Future<String> recover(String sourceRoot, String destination) async {
    _rejectLinks(sourceRoot);
    _rejectLinks(destination);
    for (final name in ['silique.sqlite', 'nova.sqlite']) {
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        _rejectLinks('$sourceRoot/$name$suffix');
      }
    }
    final sourcePath = Directory(sourceRoot).resolveSymbolicLinksSync();
    if (File('$sourcePath/silique.sqlite').existsSync() &&
        File('$sourcePath/nova.sqlite').existsSync()) {
      throw FileSystemException(
        'Both current and legacy databases exist; preserve both for inspection',
        sourcePath,
      );
    }
    final databaseName = File('$sourcePath/silique.sqlite').existsSync()
        ? 'silique.sqlite'
        : 'nova.sqlite';
    final targetDirectory = Directory(destination);
    final targetPath = targetDirectory.existsSync()
        ? targetDirectory.resolveSymbolicLinksSync()
        : '${targetDirectory.parent.resolveSymbolicLinksSync()}/${targetDirectory.uri.pathSegments.where((part) => part.isNotEmpty).last}';
    String comparison(String path) =>
        Platform.isWindows ? path.replaceAll('/', r'\').toLowerCase() : path;
    bool within(String child, String parent) => child.startsWith(
      parent.endsWith(Platform.pathSeparator)
          ? parent
          : '$parent${Platform.pathSeparator}',
    );
    final sourceName = comparison(sourcePath);
    final targetName = comparison(targetPath);
    if (sourceName == targetName ||
        within(sourceName, targetName) ||
        within(targetName, sourceName)) {
      throw FileSystemException(
        'Source and destination must not overlap',
        destination,
      );
    }
    final target = Directory(targetPath);
    if (target.existsSync() && target.listSync(followLinks: false).isNotEmpty) {
      throw FileSystemException(
        'Recovery destination must be empty',
        destination,
      );
    }
    final owned = _RecoveryFiles();
    if (!target.existsSync()) {
      target.createSync();
      owned.directories.add(target.path);
    }
    Database? source;
    try {
      final stage = target.createTempSync('.silique-recovery-');
      owned.directories.add(stage.path);
      final temporary = File('${stage.path}/backup.sqlite');
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        owned.files.add('${temporary.path}$suffix');
      }
      // This produces a snapshot only. Do not automatically activate a snapshot
      // while another source writer might keep committing to the old root.
      source = _openSnapshot('$sourcePath/$databaseName');
      final output = sqlite3.open(temporary.path);
      try {
        output.execute('PRAGMA busy_timeout=0');
        output.execute('PRAGMA locking_mode=EXCLUSIVE');
        output.execute('BEGIN EXCLUSIVE');
        output.execute('COMMIT');
        await source.backup(output, nPage: -1).drain<void>();
        output.execute('PRAGMA journal_mode=DELETE');
        final check = output.select('PRAGMA quick_check');
        if (check.length != 1 || check.single.values.single != 'ok') {
          throw StateError('Recovered database failed quick_check');
        }
      } finally {
        output.close();
      }
      final markdown = '$sourcePath/markdown';
      final markdownType = FileSystemEntity.typeSync(
        markdown,
        followLinks: false,
      );
      if (markdownType != FileSystemEntityType.notFound) {
        _copyMarkdown(markdown, '${stage.path}/markdown', owned);
      }
      final entries = target.listSync(followLinks: false);
      if (entries.length != 1 || entries.single.path != stage.path) {
        throw FileSystemException(
          'Recovery destination changed during backup',
          target.path,
        );
      }
      temporary.renameSync('${target.path}/silique.sqlite');
      owned.files.add('${target.path}/silique.sqlite');
      final stagedMarkdown = Directory('${stage.path}/markdown');
      if (stagedMarkdown.existsSync()) {
        final published = '${target.path}/markdown';
        stagedMarkdown.renameSync(published);
        owned.rebase(stagedMarkdown.path, published);
      }
      // No recursive deletion: unexpected files, including links, are not ours.
      stage.deleteSync();
      return target.path;
    } catch (error) {
      owned.cleanup();
      if (error is SqliteException &&
          (error.resultCode == SqlError.SQLITE_BUSY ||
              error.resultCode == SqlError.SQLITE_LOCKED)) {
        throw NativeStorageRecoveryFailure(
          'Source SQLite database is busy or locked. Close other Silique instances and retry; '
          'the original database was not replaced.',
          error,
        );
      }
      rethrow;
    } finally {
      source?.close();
    }
  }

  static Database _openSnapshot(String databasePath) {
    try {
      return _readSnapshot(databasePath, exclusive: false);
    } on SqliteException catch (error) {
      // Only one fresh-handle retry for I/O/shared-memory admission failures.
      // A legitimate BUSY/LOCKED reader or writer is never bypassed.
      if (error.resultCode != SqlError.SQLITE_IOERR &&
          error.resultCode != SqlError.SQLITE_CANTOPEN &&
          error.extendedResultCode !=
              SqlExtendedError.SQLITE_READONLY_CANTINIT &&
          error.extendedResultCode !=
              SqlExtendedError.SQLITE_READONLY_CANTLOCK &&
          error.extendedResultCode !=
              SqlExtendedError.SQLITE_READONLY_RECOVERY) {
        rethrow;
      }
      return _readSnapshot(databasePath, exclusive: true);
    }
  }

  static Database _readSnapshot(
    String databasePath, {
    required bool exclusive,
  }) {
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      _rejectLinks('$databasePath$suffix');
    }
    final database = sqlite3.open(databasePath, mode: OpenMode.readOnly);
    try {
      database.execute('PRAGMA busy_timeout=0');
      if (exclusive) {
        // Must precede the first schema/WAL read: SQLite then holds the real
        // database lock and builds its WAL index in heap memory, not in SHM.
        database.execute('PRAGMA locking_mode=EXCLUSIVE');
      }
      database.execute('BEGIN');
      debugRecoveryBeforeSourceRead?.call(database, exclusive);
      database.select('SELECT * FROM sqlite_schema');
      return database;
    } catch (_) {
      database.close();
      rethrow;
    }
  }

  static void _copyMarkdown(String from, String to, _RecoveryFiles owned) {
    _rejectLinks(from);
    if (FileSystemEntity.typeSync(from, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException('Markdown entry must be a directory', from);
    }
    Directory(to).createSync();
    owned.directories.add(to);
    for (final entry in Directory(from).listSync(followLinks: false)) {
      _rejectLinks(entry.path);
      final name = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
      final destination = '$to/$name';
      if (entry is Directory) {
        _copyMarkdown(entry.path, destination, owned);
      } else if (entry is File) {
        // Reserve ownership before copying so a partial write can be removed.
        File(destination).createSync(exclusive: true);
        owned.files.add(destination);
        entry.copySync(destination);
      } else {
        throw FileSystemException('Unsupported Markdown entry', entry.path);
      }
    }
  }

  static void _rejectLinks(String path) {
    var current = File(path).absolute.path;
    while (true) {
      if (FileSystemEntity.typeSync(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw FileSystemException(
          'Recovery does not follow symbolic links',
          current,
        );
      }
      final parent = Directory(current).parent.path;
      if (parent == current) return;
      current = parent;
    }
  }
}

class NativeStorageRecoveryFailure implements Exception {
  const NativeStorageRecoveryFailure(this.reason, this.cause);

  final String reason;
  final SqliteException cause;

  @override
  String toString() => '$reason $cause';
}

class _RecoveryFiles {
  final files = <String>[];
  final directories = <String>[];

  void rebase(String from, String to) {
    String replace(String path) =>
        path == from || path.startsWith('$from/') || path.startsWith('$from\\')
        ? '$to${path.substring(from.length)}'
        : path;
    for (var i = 0; i < files.length; i++) {
      files[i] = replace(files[i]);
    }
    for (var i = 0; i < directories.length; i++) {
      directories[i] = replace(directories[i]);
    }
  }

  void cleanup() {
    for (final path in files.reversed) {
      try {
        NativeStorageRecovery._rejectLinks(path);
        if (FileSystemEntity.typeSync(path, followLinks: false) ==
            FileSystemEntityType.file) {
          File(path).deleteSync();
        }
      } on FileSystemException {
        // Keep unexpected links/locked files; never follow or change permissions.
      }
    }
    for (final path in directories.reversed) {
      try {
        NativeStorageRecovery._rejectLinks(path);
        final directory = Directory(path);
        if (FileSystemEntity.typeSync(path, followLinks: false) ==
                FileSystemEntityType.directory &&
            directory.listSync(followLinks: false).isEmpty) {
          directory.deleteSync();
        }
      } on FileSystemException {
        // Cleanup is best effort and never hides the original recovery error.
      }
    }
  }
}
