import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/storage/native_storage.dart';

// Explorer can see the parent while Windows rejects a create with error 2
// (e.g. Controlled folder access). Inject only this OS boundary, not storage.
class _BlockedDirectory implements Directory {
  _BlockedDirectory(this.path, {required this.present, required this.failure});

  @override
  final String path;
  final bool present;
  final FileSystemException failure;

  @override
  Directory get absolute => this;

  @override
  bool existsSync() => present;

  @override
  void createSync({bool recursive = false}) => throw failure;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _BlockedProbe implements File {
  _BlockedProbe(this.path);

  @override
  final String path;

  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => throw FileSystemException(
    'Access denied',
    path,
    const OSError('denied', 5),
  );

  @override
  bool existsSync() => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('Windows write failures explain per-app protection without claiming a cause', () {
    const path = r'C:\Users\Ultro\Documents\Silique Vaults';
    for (final code in [2, 3, 5]) {
      final failure = FileSystemException(
        'Creation failed',
        path,
        OSError('blocked', code),
      );
      final error = StorageLocationUnavailable.writeFailure(
        path,
        failure,
        isWindows: true,
      );
      expect(error.path, path);
      expect(error.reason, contains('Historia ochrony'));
      expect(error.reason, contains('Kontrolowany dostęp do folderów'));
      expect(error.reason, contains('silique.exe'));
      expect(error.reason, contains('Jeśli'));
      expect(error.reason, contains('Nie wyłączaj ochrony'));
      expect(error.toString(), contains(failure.toString()));
    }
  });

  test('non-Windows failures keep OS details without Windows advice', () {
    const failure = FileSystemException(
      'Read-only file system',
      '/notes',
      OSError('read-only', 30),
    );
    final error = StorageLocationUnavailable.writeFailure(
      '/notes',
      failure,
      isWindows: false,
    );
    expect(error.reason, contains('zapis'));
    expect(error.reason, contains(failure.toString()));
    expect(error.reason, isNot(contains('Windows')));
  });

  test(
    'a blocked write probe preserves the recorded store and existing data',
    () {
      final root = Directory.systemTemp.createTempSync('silique-write-denied-');
      addTearDown(() => root.deleteSync(recursive: true));
      final support = Directory('${root.path}/support')..createSync();
      final chosen = Directory('${root.path}/Documents')..createSync();
      final target = Directory(
        '${chosen.path}/${NativeStorage.vaultsFolderName}',
      )..createSync();
      final database = File('${target.path}/silique.sqlite')
        ..writeAsStringSync('existing database bytes');
      NativeStorage.persistChosenRoot(support.path, target.path);
      IOOverrides.runZoned(
        () => expect(
          () => NativeStorage.prepareChosenRoot(chosen.path),
          throwsA(
            isA<StorageLocationUnavailable>().having(
              (error) => error.reason,
              'retained OS error',
              contains('errno = 5'),
            ),
          ),
        ),
        createFile: (path) => _BlockedProbe(path),
      );
      expect(NativeStorage.recordedRoot(support.path), target.path);
      expect(database.readAsStringSync(), 'existing database bytes');
      expect(
        File(target.listSync().single.path).readAsStringSync(),
        'existing database bytes',
      );
    },
  );

  test(
    'existing Documents with mkdir error 2 gives a recoverable write error',
    () {
      const parent = r'C:\Users\Ultro\Documents';
      const failedPath = '$parent/Silique Vaults';
      const failure = PathNotFoundException(
        failedPath,
        OSError('Nie można odnaleźć określonego pliku', 2),
        'Creation failed',
      );
      final requested = <String>[];

      IOOverrides.runZoned(
        () {
          expect(
            () => NativeStorage.prepareChosenRoot(parent),
            throwsA(
              isA<StorageLocationUnavailable>()
                  .having(
                    (error) => error.reason,
                    'explanation',
                    contains('zapis'),
                  )
                  .having(
                    (error) => error.path,
                    'failed location',
                    contains(parent),
                  )
                  .having(
                    (error) => error.reason,
                    'original OS failure',
                    contains(failure.toString()),
                  )
                  .having(
                    (error) => error.reason,
                    'platform-specific guidance',
                    Platform.isWindows
                        ? contains('Historia ochrony')
                        : isNot(contains('Windows')),
                  ),
            ),
          );
        },
        createDirectory: (path) {
          requested.add(path);
          return _BlockedDirectory(
            path,
            present: path == parent,
            failure: failure,
          );
        },
      );
      expect(requested, contains(parent));
      expect(
        requested.where((path) => !path.startsWith(parent)),
        isEmpty,
        reason: 'never substitute another location or create an empty database',
      );
    },
  );
}
