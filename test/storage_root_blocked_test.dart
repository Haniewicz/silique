import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/main.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:sqlite3/sqlite3.dart';

// Windows Controlled folder access rejects a create with error 2 or 5 while the
// folder stays readable. Inject only that OS boundary, not storage.
class _BlockedProbe implements File {
  _BlockedProbe(this.path, {this.present = false});

  @override
  final String path;

  /// The database is already there and readable; only a new file is refused.
  final bool present;

  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => throw FileSystemException(
    'Nie można odnaleźć określonego pliku',
    path,
    const OSError('blocked', 2),
  );

  @override
  bool existsSync() => present;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Directory _tempRoot() {
  final root = Directory.systemTemp.createTempSync('silique-root-blocked-');
  addTearDown(() => root.deleteSync(recursive: true));
  return root;
}

void main() {
  test('a root that refuses the probe is reported as a blocked folder', () {
    final root = _tempRoot();
    final inside = Directory('${root.path}/Documents/Silique Vaults')
      ..createSync(recursive: true);
    File('${inside.path}/silique.sqlite').writeAsStringSync('x');

    final captured = <Object>[];
    IOOverrides.runZoned(
      () {
        try {
          NativeStorage.verifyRootWritable(inside.path);
        } catch (error) {
          captured.add(error);
        }
      },
      createFile: (path) =>
          _BlockedProbe(path, present: path.endsWith('silique.sqlite')),
    );

    expect(captured, hasLength(1));
    final error = captured.single;
    expect(error, isA<StorageRootWriteBlocked>());
    final blocked = error as StorageRootWriteBlocked;
    expect(blocked.path, inside.path);
    // The folder, not the SQLite file, is the subject of the message.
    expect(blocked.reason, contains('folder'));
    // No SQLite error code can be quoted: SQLite was never opened.
    expect(blocked.reason, isNot(contains('778')));
    expect(blocked.reason, contains('Przenieś notatki'));
    if (Platform.isWindows) {
      expect(blocked.reason, contains('Kontrolowany dostęp do folderów'));
    }
  });

  test('a writable root still opens and leaves no probe file behind', () async {
    final root = _tempRoot();
    final store = NativeStorage(root.path);
    await store.close();
    expect(File('${root.path}/silique.sqlite').existsSync(), isTrue);
    expect(
      root
          .listSync(followLinks: false)
          .where((entry) => entry.path.endsWith('.tmp')),
      isEmpty,
    );
  });

  test('relocating keeps notes that exist only in the WAL', () async {
    final root = _tempRoot();
    final source = Directory('${root.path}/Documents/Silique Vaults')
      ..createSync(recursive: true);
    final support = Directory('${root.path}/support')..createSync();
    final chosen = Directory('${root.path}/Notes')..createSync();

    final store = NativeStorage(source.path);
    await store.close();

    // A writer keeps the row in the log instead of the main database file, which
    // is exactly the data a plain database copy would lose.
    final writer = sqlite3.open('${source.path}/silique.sqlite');
    addTearDown(writer.close);
    writer.execute("PRAGMA journal_mode=wal");
    writer.execute('BEGIN IMMEDIATE');
    writer.execute(
      "INSERT OR REPLACE INTO documents(vault_id,note_id,data) "
      "VALUES('vault-1','note-in-wal','{\"title\":\"z WAL\"}')",
    );
    writer.execute('COMMIT');
    expect(
      File('${source.path}/silique.sqlite-wal').lengthSync(),
      greaterThan(0),
    );

    final moved = NativeStorage.relocateBlockedRoot(
      support.path,
      source.path,
      chosen.path,
    );

    expect(moved, '${chosen.path}/${NativeStorage.vaultsFolderName}');
    expect(NativeStorage.recordedRoot(support.path), moved);

    final copy = sqlite3.open('$moved/silique.sqlite');
    addTearDown(copy.close);
    expect(copy.select('PRAGMA quick_check').single.values.single, 'ok');
    expect(
      copy.select("SELECT data FROM documents WHERE note_id='note-in-wal'"),
      hasLength(1),
      reason: 'the committed WAL frame must survive relocation',
    );
    expect(copy.select('PRAGMA journal_mode').single.values.single, 'wal');

    // The blocked folder is reported, never repaired: its bytes stay.
    expect(File('${source.path}/silique.sqlite').existsSync(), isTrue);
    expect(File('${source.path}/silique.sqlite-wal').existsSync(), isTrue);
  });

  test('relocating refuses a destination that holds foreign files', () async {
    final root = _tempRoot();
    final source = Directory('${root.path}/Blocked')..createSync();
    final support = Directory('${root.path}/support')..createSync();
    final chosen = Directory('${root.path}/Notes')..createSync();
    final store = NativeStorage(source.path);
    await store.close();
    final occupied = Directory(
      '${chosen.path}/${NativeStorage.vaultsFolderName}',
    )..createSync();
    File('${occupied.path}/not-ours.txt').writeAsStringSync('keep me');

    expect(
      () => NativeStorage.relocateBlockedRoot(
        support.path,
        source.path,
        chosen.path,
      ),
      throwsA(isA<StateError>()),
    );
    expect(File('${occupied.path}/not-ours.txt').readAsStringSync(), 'keep me');
    expect(NativeStorage.recordedRoot(support.path), isNull);
    expect(File('${source.path}/silique.sqlite').existsSync(), isTrue);
  });

  testWidgets('a blocked folder offers moving the notes, not just retrying', (
    tester,
  ) async {
    var moves = 0;
    await tester.pumpWidget(
      StartupFailureScreen(
        error: 'Zablokowany folder',
        hint: 'Folder nie przyjmuje zapisów.',
        onRelocate: () async {
          moves++;
          return null;
        },
      ),
    );
    final move = find.byKey(const Key('startup-failure-relocate'));
    expect(move, findsOneWidget);
    await tester.tap(move);
    await tester.pumpAndSettle();
    expect(moves, 1);
  });
}
