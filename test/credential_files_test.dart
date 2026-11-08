import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/storage/credential_files.dart';

final throwsFileSystemException = throwsA(isA<FileSystemException>());

/// The Darwin ACL facade is compiled with the host C compiler. Minimal build
/// containers ship without one; then the contract cannot be exercised and the
/// run must report that instead of a product failure.
/// The probes re-enter the SDK as a separate process. Build containers do not
/// put `dart` on PATH, so resolve it from the running toolchain first.
String? _cachedDart;
String? _dartExecutable() {
  if (_cachedDart != null) return _cachedDart;
  final candidates = <String>[
    if (Platform.environment['DART'] != null) Platform.environment['DART']!,
    if (Platform.environment['FLUTTER_ROOT'] != null)
      '${Platform.environment['FLUTTER_ROOT']}/bin/dart',
  ];
  var directory = File(Platform.resolvedExecutable).parent;
  for (var depth = 0; depth < 8; depth++) {
    candidates.add('${directory.path}/dart');
    candidates.add('${directory.path}/bin/dart');
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  candidates.add('dart');
  for (final candidate in candidates) {
    try {
      if (Process.runSync(candidate, const ['--version']).exitCode == 0) {
        return _cachedDart = candidate;
      }
    } on ProcessException {
      continue;
    }
  }
  return null;
}

Future<bool> _nativeCompilerAvailable() async {
  try {
    final probe = await Process.run('cc', const ['--version']);
    return probe.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

void main() {
  late Directory root;
  late Directory directory;
  setUp(() async {
    final temporary = await Directory.systemTemp.createTemp(
      'silique-credentials-',
    );
    root = Directory(await temporary.resolveSymbolicLinks());
    directory = Directory('${root.path}/credentials');
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'Windows last-error binding is leaf and resolved before native failures',
    () async {
      final dart = _dartExecutable();
      if (dart == null) {
        markTestSkipped('dart executable unavailable for the binding probe');
        return;
      }
      final source = File('lib/storage/credential_files_windows.dart')
          .readAsStringSync();
      // Binding contract only; desktop integration separately exercises actual
      // missing files, credential migration and SQLite reopen on Windows.
      final probe = File('${root.path}/windows_error_binding.dart');
      probe.writeAsStringSync('''
import 'dart:ffi' hide DynamicLibrary;
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win;
class DynamicLibrary {
  static int resolutions = 0, lastError = 0;
  static DynamicLibrary open(String name) => DynamicLibrary();
  F lookupFunction<T extends Function, F extends Function>(String name, {bool isLeaf = false}) {
    if (name == 'SiliqueCredentialOpen') {
      return ((Pointer<Utf16> path, int access, int share, Pointer<win.SECURITY_ATTRIBUTES> sa,
          int creation, int flags, Pointer<Void> template, Pointer<Uint32> captured) {
        captured.value = 2;
        lastError = 0;
        return Pointer<Void>.fromAddress(0xffffffffffffffff);
      }) as F;
    }
    if (name == 'SiliqueCredentialMkdir') {
      return ((Pointer<Utf16> path, Pointer<win.SECURITY_ATTRIBUTES> sa, Pointer<Uint32> captured) {
        captured.value = 183;
        lastError = 0;
        return 0;
      }) as F;
    }
    if (name == 'SiliqueCredentialLock') {
      return ((Pointer<Void> file, int flags, int reserved, int low, int high,
          Pointer<win.OVERLAPPED> overlapped, Pointer<Uint32> captured) {
        captured.value = 33;
        lastError = 0;
        return 0;
      }) as F;
    }
    if (name != 'GetLastError') throw StateError('Unexpected binding: \$name');
    resolutions++;
    // Model symbol resolution clearing TLS, and reject a non-leaf getter that
    // can itself transition through the VM before reading the native error.
    lastError = 0;
    if (!isLeaf) throw StateError('GetLastError must be a leaf binding');
    return (() => lastError) as F;
  }
}
${source.substring(source.indexOf('class _Windows {'))}
class ProbeWindows extends _Windows {
  @override
  String _bridgePath() => 'binding-facade';
  @override
  T _attributes<T>(bool directory, T Function(Pointer<win.SECURITY_ATTRIBUTES>) operation) => operation(nullptr);
}
void main() {
  final windows = ProbeWindows();
  if (DynamicLibrary.resolutions != 1) throw StateError('Resolve before native operations');
  DynamicLibrary.lastError = 2;
  if (windows.error != 2) throw StateError('Missing-file error was clobbered');
  DynamicLibrary.lastError = 33;
  if (windows.error != 33) throw StateError('Lock-conflict error was clobbered');
  final file = windows.tryOpen('synthetic');
  if (!windows.invalid(file) || windows.openError != 2) throw StateError('Use atomic missing-file error');
  windows.createDirectory('synthetic'); // captured 183 is an existing directory
  if (windows.lockFile(nullptr, 3, 0, 1, 0, nullptr) != 0 || windows.lockError != 33) {
    throw StateError('Use atomic lock-conflict error');
  }
}
''');
      final result = await Process.run(dart, [
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        probe.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    skip: !Platform.isLinux,
  );

  test('Darwin ACL contract rejects an extended entry despite mode 0600 (Linux facade)', () async {
    if (!await _nativeCompilerAvailable()) {
      markTestSkipped('cc unavailable: cannot build the Darwin ACL facade');
      return;
    }
    if (_dartExecutable() == null) {
      markTestSkipped('dart executable unavailable for the ACL probe');
      return;
    }
    final result = await _darwinAclProbe(root, scenario: 1);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout.toString().trim(), 'rejected');
  }, skip: !Platform.isLinux);

  test('POSIX mode_t and variadics match platform C declarations (binding contract)', () async {
    final source = File('lib/storage/credential_files_posix.dart')
        .readAsStringSync();
    final original = source.substring(source.indexOf('class _Posix {'));
    for (final (abi, modeType) in [
      ('macosX64', 'Uint16'),
      ('macosArm64', 'Uint16'),
      ('androidArm', 'Uint16'),
      ('androidIA32', 'Uint16'),
      ('androidArm64', 'Uint32'),
      ('androidX64', 'Uint32'),
      ('linuxX64', 'Uint32'),
      ('linuxArm64', 'Uint32'),
    ]) {
      final validator = original
          .replaceAll('Abi.current()', 'Abi.$abi')
          .replaceFirst(
            'bool get _mac => Platform.isMacOS;',
            'bool get _mac => ${abi.startsWith('macos')};',
          );
      final probe = File('${root.path}/mode_binding.dart');
      probe.writeAsStringSync('''
import 'dart:ffi' hide DynamicLibrary;
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
typedef ExpectedModeBinding = Int32 Function(Int32, Pointer<Utf8>, $modeType);
typedef ExpectedOpenBinding = Int32 Function(
    Int32, Pointer<Utf8>, Int32, VarArgs<(${modeType == 'Uint16' ? 'Int32' : 'Uint32'},)>);
typedef ExpectedFcntlBinding = Int32 Function(Int32, Int32, VarArgs<(Int32,)>);
class DynamicLibrary {
  static DynamicLibrary process() => DynamicLibrary();
  F lookupFunction<T extends Function, F extends Function>(String name) {
    if (name == 'mkdirat') {
      if (T != ExpectedModeBinding) {
        throw StateError('$abi mkdirat mode_t binding has wrong width: \$T');
      }
      return ((int parent, Pointer<Utf8> path, int mode) => 0) as F;
    }
    if (name == 'openat') {
      if (T != ExpectedOpenBinding) {
        throw StateError('$abi openat mode_t vararg is not correctly promoted: \$T');
      }
      return ((int parent, Pointer<Utf8> path, int flags, int mode) => 73) as F;
    }
    if (name == 'fcntl') {
      if (T != ExpectedFcntlBinding) {
        throw StateError('$abi fcntl int vararg has wrong ABI: \$T');
      }
      return ((int fd, int command, int argument) => 0) as F;
    }
    throw StateError('Unexpected binding: \$name');
  }
}
$validator
void main() {
  final posix = _Posix();
  posix.mkdirAt(73, 'synthetic');
  posix.tryOpenAt(73, 'synthetic', 0);
  posix._fcntl(73, 51, 0);
}
''');
      final dart = _dartExecutable();
      if (dart == null) {
        markTestSkipped('dart executable unavailable for the binding probe');
        return;
      }
      final result = await Process.run(dart, [
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        probe.path,
      ]);
      expect(
        result.exitCode,
        0,
        reason: '$abi: ${result.stdout}\n${result.stderr}',
      );
    }
  }, skip: !Platform.isLinux);

  for (final (label, scenario, isDirectory) in [
    ('accepts an empty ACL', 0, false),
    ('accepts an absent ACL reported as NULL and ENOENT', 4, false),
    ('rejects directory ACL entries despite mode 0700', 1, true),
    ('fails closed when ACL retrieval fails', 2, false),
    ('fails closed when ACL entry inspection fails', 3, false),
  ]) {
    test('Darwin ACL contract $label (Linux facade)', () async {
      if (!await _nativeCompilerAvailable()) {
        markTestSkipped('cc unavailable: cannot build the Darwin ACL facade');
        return;
      }
      if (_dartExecutable() == null) {
        markTestSkipped('dart executable unavailable for the ACL probe');
        return;
      }
      final result = await _darwinAclProbe(
        root,
        scenario: scenario,
        directory: isDirectory,
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(
        result.stdout.toString().trim(),
        scenario == 0 || scenario == 4 ? 'accepted' : 'rejected',
      );
    }, skip: !Platform.isLinux);
  }

  for (final target in ['directory', 'credentials.json', 'lock', 'pending']) {
    test('macOS rejects extended ACL on $target despite private POSIX mode', () async {
      final files = NativeCredentialFiles(directory);
      await files.write('credentials.json', 'synthetic');
      if (target == 'pending') {
        await files.write('orphan', 'uncommitted-synthetic');
        File('${directory.path}/orphan')
            .renameSync('${directory.path}/.pending-credentials.json');
      }
      final path = target == 'directory'
          ? directory.path
          : '${directory.path}/${target == 'pending' ? '.pending-credentials.json' : target}';
      final result = await Process.run('chmod', [
        '+a',
        'everyone allow read',
        path,
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(
        (await FileStat.stat(path)).mode & 0x1ff,
        target == 'directory' ? 0x1c0 : 0x180,
      );
      await expectLater(
        files.read('credentials.json'),
        throwsFileSystemException,
      );
      await expectLater(
        files.write('credentials.json', 'replacement'),
        throwsFileSystemException,
      );
      await expectLater(
        files.remove('credentials.json'),
        throwsFileSystemException,
      );
      expect(
        File('${directory.path}/credentials.json').readAsStringSync(),
        'synthetic',
      );
    }, skip: !Platform.isMacOS);
  }

  test('read retires a crash-orphan temporary without publishing it', () async {
    final files = NativeCredentialFiles(directory);
    await files.write('credentials.json', 'committed');
    // Seed through the native writer so Windows ACLs and POSIX modes are real.
    await files.write('orphan', 'uncommitted-synthetic-secret');
    final pending = File('${directory.path}/.pending-credentials.json');
    File('${directory.path}/orphan').renameSync(pending.path);

    expect(
      await NativeCredentialFiles(directory).read('credentials.json'),
      'committed',
    );
    expect(pending.existsSync(), isFalse);
    expect(await files.read('credentials.json'), 'committed');
  });

  for (final hardlink in [false, true]) {
    test(
      'POSIX refuses ${hardlink ? 'hardlinked' : 'symlinked'} crash-orphan cleanup',
      () async {
        final files = NativeCredentialFiles(directory);
        await files.write('credentials.json', 'committed');
        await files.write('outside', 'untouched-synthetic');
        final outside = File('${directory.path}/outside')
            .renameSync('${root.path}/outside');
        final pending = '${directory.path}/.pending-credentials.json';
        if (hardlink) {
          final result = await Process.run('ln', [outside.path, pending]);
          expect(result.exitCode, 0, reason: result.stderr.toString());
        } else {
          Link(pending).createSync(outside.path);
        }
        await expectLater(
          files.read('credentials.json'),
          throwsFileSystemException,
        );
        await expectLater(
          files.write('credentials.json', 'replacement'),
          throwsFileSystemException,
        );
        await expectLater(
          files.remove('credentials.json'),
          throwsFileSystemException,
        );
        expect(outside.readAsStringSync(), 'untouched-synthetic');
        expect(
          File('${directory.path}/credentials.json').readAsStringSync(),
          'committed',
        );
        expect(
          FileSystemEntity.typeSync(pending, followLinks: false),
          hardlink ? FileSystemEntityType.file : FileSystemEntityType.link,
        );
      },
      skip: Platform.isWindows,
    );
  }

  test(
    'remove retires a crash-orphan even when the target is missing',
    () async {
      final files = NativeCredentialFiles(directory);
      await files.write('orphan', 'uncommitted-synthetic-secret');
      final pending = File('${directory.path}/.pending-credentials.json');
      File('${directory.path}/orphan').renameSync(pending.path);

      await NativeCredentialFiles(directory).remove('credentials.json');
      expect(pending.existsSync(), isFalse);
      expect(await files.read('credentials.json'), isNull);
      await files.remove('credentials.json');
    },
  );

  test(
    'write retires a crash-orphan before replacing the committed value',
    () async {
      final files = NativeCredentialFiles(directory);
      await files.write('credentials.json', 'committed');
      await files.write('orphan', 'uncommitted-synthetic-secret');
      final pending = File('${directory.path}/.pending-credentials.json');
      File('${directory.path}/orphan').renameSync(pending.path);

      await NativeCredentialFiles(directory)
          .write('credentials.json', 'replacement');
      // Check before a read, since reads also perform orphan recovery.
      expect(pending.existsSync(), isFalse);
      expect(await files.read('credentials.json'), 'replacement');
    },
  );

  test(
    'POSIX retains the pinned directory across parent redirection',
    () async {
      final files = NativeCredentialFiles(directory);
      final moved = Directory('${root.path}/moved');
      final decoy = Directory('${root.path}/decoy')..createSync();
      await files.locked(() async {
        await directory.rename(moved.path);
        Link(directory.path).createSync(decoy.path);
        await files.write('credentials.json', 'pinned');
        expect(await files.read('credentials.json'), 'pinned');
      });
      expect(decoy.listSync(), isEmpty);
      expect(
        await NativeCredentialFiles(moved).read('credentials.json'),
        'pinned',
      );
      await expectLater(
        files.read('credentials.json'),
        throwsFileSystemException,
      );
    },
    skip: Platform.isWindows,
  );

  test(
    'concurrent controllers do not lose read modify write transactions',
    () async {
      await NativeCredentialFiles(directory).write('counter', '0');
      const workers = 4;
      const iterations = 6;
      await Future.wait(
        List.generate(workers, (_) async {
          final files = NativeCredentialFiles(directory);
          for (var iteration = 0; iteration < iterations; iteration++) {
            await files.locked(() async {
              final count = int.parse((await files.read('counter'))!);
              await Future<void>.delayed(const Duration(milliseconds: 2));
              await files.write('counter', '${count + 1}');
            });
          }
        }),
      );
      expect(
        await NativeCredentialFiles(directory).read('counter'),
        '${workers * iterations}',
      );
    },
  );

  test(
    'native fsync failure preserves the previous credential and cleans temporary files',
    () async {
      final files = NativeCredentialFiles(directory);
      await files.write('credentials.json', 'original');
      final marker = File('${directory.path}/.fail-fsync')
        ..writeAsStringSync('');
      try {
        await expectLater(
          files.write('credentials.json', 'replacement'),
          throwsFileSystemException,
        );
      } finally {
        marker.deleteSync();
      }
      expect(await files.read('credentials.json'), 'original');
      expect(
        directory.listSync().where((e) => e.path.contains('.pending-')),
        isEmpty,
      );
      await files.write('credentials.json', 'retry');
      expect(await files.read('credentials.json'), 'retry');
    },
    skip:
        !Platform.isLinux ||
        Platform.environment['SILIQUE_NATIVE_FAULTS'] != '1',
  );

  test(
    'native rename failure preserves the previous credential and releases the lock',
    () async {
      final files = NativeCredentialFiles(directory);
      await files.write('credentials.json', 'original');
      final marker = File('${directory.path}/.fail-rename')
        ..writeAsStringSync('');
      try {
        await expectLater(
          files.write('credentials.json', 'replacement'),
          throwsFileSystemException,
        );
      } finally {
        marker.deleteSync();
      }
      expect(
        await NativeCredentialFiles(directory).read('credentials.json'),
        'original',
      );
      expect(
        directory.listSync().where((e) => e.path.contains('.pending-')),
        isEmpty,
      );
      await files.write('credentials.json', 'retry');
    },
    skip:
        !Platform.isLinux ||
        Platform.environment['SILIQUE_NATIVE_FAULTS'] != '1',
  );

  test(
    'malformed UTF-8 fails closed without leaking file contents in errors',
    () async {
      final files = NativeCredentialFiles(directory);
      await files.write('credentials.json', 'initial');
      final prefix = utf8.encode('synthetic-sensitive-sentinel');
      File('${directory.path}/credentials.json')
          .writeAsBytesSync([...prefix, 0xff]);
      try {
        await files.read('credentials.json');
        fail('Invalid UTF-8 was accepted');
      } catch (error) {
        expect(error, isA<FileSystemException>());
        expect(
          error.toString(),
          isNot(contains('synthetic-sensitive-sentinel')),
        );
      }
    },
  );

  test(
    'creates support credentials separately from notebook locations',
    () async {
      final files = await NativeCredentialFiles.forSupport(root);
      await files.write('credentials.json', 'synthetic');
      expect(files.directory.path, '${root.path}/credentials');
      expect(
        await NativeCredentialFiles(directory).read('credentials.json'),
        'synthetic',
      );
    },
  );

  test('POSIX creates directory 0700 and files 0600', () async {
    final files = NativeCredentialFiles(directory);
    await files.write('credentials.json', 'synthetic');
    expect((await directory.stat()).mode & 0x1ff, 0x1c0);
    for (final entry in directory.listSync()) {
      expect((await entry.stat()).mode & 0x1ff, 0x180);
    }
  }, skip: Platform.isWindows);

  test('POSIX accepts an ancestor that is executable but not readable', () async {
    // Android mounts /data as 0771: apps may traverse it but not list it. The
    // walk must therefore open ancestors without requesting read access, or
    // every credential operation fails with EACCES on real devices.
    final temporary = Directory(
      await (await Directory.systemTemp.createTemp(
        'silique-ancestor-',
      )).resolveSymbolicLinks(),
    );
    final blocked = Directory('${temporary.path}/app')..createSync();
    final credentials = Directory('${blocked.path}/no_backup/credentials')
      ..createSync(recursive: true);
    await Process.run('chmod', [
      '700',
      credentials.path,
      Directory('${blocked.path}/no_backup').path,
    ]);
    addTearDown(() async {
      await Process.run('chmod', ['700', blocked.path]);
      await temporary.delete(recursive: true);
    });
    // Execute-only for the owner reproduces "other" access on Android's /data.
    await Process.run('chmod', ['100', blocked.path]);

    final files = NativeCredentialFiles(credentials);
    await files.write('credentials.json', 'synthetic');
    expect(await files.read('credentials.json'), 'synthetic');
  }, skip: !Platform.isLinux);

  test('rejects unsafe basenames without filesystem mutation', () async {
    final files = NativeCredentialFiles(directory);
    for (final name in [
      '',
      '../escape',
      '/absolute',
      'a/b',
      r'a\b',
      '.pending-x',
      'a..b',
      'x:',
      'a\u0000b',
      'a.',
    ]) {
      await expectLater(
        Future.sync(() => files.write(name, 'synthetic')),
        throwsArgumentError,
      );
      await expectLater(
        Future.sync(() => files.read(name)),
        throwsArgumentError,
      );
      await expectLater(
        Future.sync(() => files.remove(name)),
        throwsArgumentError,
      );
    }
    expect(directory.existsSync(), isFalse);
  });

  test('rejects symlinked credential directory and parent', () async {
    final target = Directory('${root.path}/target')..createSync();
    Link(directory.path).createSync(target.path);
    await expectLater(
      NativeCredentialFiles(directory).write('credentials.json', 'synthetic'),
      throwsFileSystemException,
    );
    expect(target.listSync(), isEmpty);
    await expectLater(
      NativeCredentialFiles(Directory('${directory.path}/child'))
          .read('credentials.json'),
      throwsFileSystemException,
    );
    expect(target.listSync(), isEmpty);
  }, skip: Platform.isWindows); // Windows junction/ACL regression below.

  test(
    'rejects symlinked data and lock without changing their targets',
    () async {
      final files = NativeCredentialFiles(directory);
      await files.write('credentials.json', 'synthetic');
      final outside = File('${root.path}/outside')
        ..writeAsStringSync('untouched');
      final data = File('${directory.path}/credentials.json');
      data.deleteSync();
      Link(data.path).createSync(outside.path);
      await expectLater(
        files.read('credentials.json'),
        throwsFileSystemException,
      );
      await expectLater(
        files.write('credentials.json', 'replacement'),
        throwsFileSystemException,
      );
      await expectLater(
        files.remove('credentials.json'),
        throwsFileSystemException,
      );
      expect(outside.readAsStringSync(), 'untouched');
      File('${directory.path}/lock').deleteSync();
      Link('${directory.path}/lock').createSync(outside.path);
      await expectLater(files.locked(() async {}), throwsFileSystemException);
      expect(outside.readAsStringSync(), 'untouched');
    },
    skip: Platform.isWindows,
  );

  test('POSIX rejects permissive existing directory and file', () async {
    directory.createSync();
    await Process.run('chmod', ['755', directory.path]);
    final files = NativeCredentialFiles(directory);
    await expectLater(
      files.read('credentials.json'),
      throwsFileSystemException,
    );
    await Process.run('chmod', ['700', directory.path]);
    await files.write('credentials.json', 'synthetic');
    await Process.run('chmod', ['644', '${directory.path}/credentials.json']);
    await expectLater(
      files.read('credentials.json'),
      throwsFileSystemException,
    );
    await expectLater(
      files.write('credentials.json', 'replacement'),
      throwsFileSystemException,
    );
    await expectLater(
      files.remove('credentials.json'),
      throwsFileSystemException,
    );
  }, skip: Platform.isWindows);

  test('POSIX rejects hardlinked credential data', () async {
    final files = NativeCredentialFiles(directory);
    await files.write('credentials.json', 'synthetic');
    final result = await Process.run('ln', [
      '${directory.path}/credentials.json',
      '${root.path}/alias',
    ]);
    expect(result.exitCode, 0);
    await expectLater(
      files.read('credentials.json'),
      throwsFileSystemException,
    );
    await expectLater(
      files.write('credentials.json', 'replacement'),
      throwsFileSystemException,
    );
  }, skip: Platform.isWindows);

  test('errors release locks and leave no pending plaintext files', () async {
    final files = NativeCredentialFiles(directory);
    await expectLater(
      files.locked(() async {
        await files.write('credentials.json', 'original');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        throw StateError('synthetic failure');
      }),
      throwsStateError,
    );
    final other = NativeCredentialFiles(directory);
    await other
        .write('credentials.json', 'replacement')
        .timeout(const Duration(seconds: 5));
    expect(await other.read('credentials.json'), 'replacement');
    expect(
      directory.listSync().map(
        (e) => e.path.split(Platform.pathSeparator).last,
      ),
      unorderedEquals(['lock', 'credentials.json']),
    );
  });

  test('repeated atomic replacement never exposes partial plaintext to a native reader', () async {
    final files = NativeCredentialFiles(directory);
    final a = 'A' * 131072;
    final b = 'B' * 131072;
    await files.write('credentials.json', a);
    final messages = ReceivePort();
    final iterator = StreamIterator<dynamic>(messages);
    final worker = await Isolate.spawn(_replaceWorker, (
      directory.path,
      messages.sendPort,
    ));
    try {
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current, 'ready');
      var done = false;
      final completion = iterator.moveNext().then((value) {
        done = true;
        return value;
      });
      var reads = 0;
      while (!done) {
        final content = File('${directory.path}/credentials.json')
            .readAsStringSync();
        // Windows has an explicit live/tombstone byte to make removal durable
        // through the same write-through replacement primitive.
        expect(content, isIn(Platform.isWindows ? ['V$a', 'V$b'] : [a, b]));
        reads++;
        await Future<void>.delayed(Duration.zero);
      }
      expect(await completion, isTrue);
      expect(iterator.current, 'done');
      expect(reads, greaterThan(0));
      expect(
        await NativeCredentialFiles(directory).read('credentials.json'),
        b,
      );
      expect(
        directory.listSync().where((e) => e.path.contains('.pending-')),
        isEmpty,
      );
    } finally {
      worker.kill(priority: Isolate.immediate);
      await iterator.cancel();
      messages.close();
    }
  });

  test('Windows ACLs allow only current owner and SYSTEM', () async {
    final files = NativeCredentialFiles(directory);
    await files.write('credentials.json', 'synthetic');
    final result = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'''
    $ErrorActionPreference = 'Stop'
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $paths = @($env:SILIQUE_TEST_DIRECTORY, (Join-Path $env:SILIQUE_TEST_DIRECTORY 'credentials.json'), (Join-Path $env:SILIQUE_TEST_DIRECTORY 'lock'))
    foreach ($path in $paths) {
    $acl = Get-Acl -LiteralPath $path
    if (-not $acl.AreAccessRulesProtected) { throw 'inherited ACL' }
    if ($acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -ne $user) { throw 'wrong owner' }
    foreach ($rule in $acl.Access) {
      $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
      if (($sid -ne $user) -and ($sid -ne 'S-1-5-18')) { throw 'nonprivate ACL' }
    }
    }
    Write-Output 'private'
    ''',
      ],
      environment: {'SILIQUE_TEST_DIRECTORY': directory.path},
    );
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(result.stdout.toString().trim(), 'private');
  }, skip: !Platform.isWindows);

  test(
    'Windows rejects junctions instead of following redirected parents',
    () async {
      final target = Directory('${root.path}/target')..createSync();
      final result = await Process.run('cmd.exe', [
        '/c',
        'mklink',
        '/J',
        directory.path,
        target.path,
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      try {
        await expectLater(
          NativeCredentialFiles(directory)
              .write('credentials.json', 'synthetic'),
          throwsFileSystemException,
        );
        expect(target.listSync(), isEmpty);
      } finally {
        await Process.run('cmd.exe', ['/c', 'rmdir', directory.path]);
      }
    },
    skip: !Platform.isWindows,
  );

  test('Windows durable removal publishes a non-secret tombstone', () async {
    final files = NativeCredentialFiles(directory);
    await files.write('credentials.json', 'synthetic');
    await files.remove('credentials.json');
    expect(File('${directory.path}/credentials.json').readAsStringSync(), 'D');
    expect(
      await NativeCredentialFiles(directory).read('credentials.json'),
      isNull,
    );
    await files.write('credentials.json', '');
    expect(await files.read('credentials.json'), '');
  }, skip: !Platform.isWindows);

  test(
    'detached callbacks cannot reuse a released native transaction',
    () async {
      final files = NativeCredentialFiles(directory);
      final release = Completer<void>();
      late Future<void> lateWrite;
      await files.locked(() async {
        lateWrite = release.future.then(
          (_) => files.write('credentials.json', 'late'),
        );
      });
      release.complete();
      await expectLater(lateWrite, throwsStateError);
    },
  );

  test('rejects Windows device basenames on every platform', () async {
    final files = NativeCredentialFiles(directory);
    for (final name in ['CON', 'con.json', 'NUL', 'COM1.txt', 'LPT9', 'LOCK']) {
      await expectLater(
        Future.sync(() => files.write(name, 'synthetic')),
        throwsArgumentError,
      );
    }
  });

  test('locks serialize independent controllers while action awaits', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final order = <String>[];
    final first = NativeCredentialFiles(directory).locked(() async {
      order.add('first');
      entered.complete();
      await release.future;
      order.add('released');
    });
    await entered.future;
    final second = NativeCredentialFiles(directory).locked(() async {
      order.add('second');
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(order, ['first']);
    release.complete();
    await Future.wait([first, second]);
    expect(order, ['first', 'released', 'second']);
  });

  test('Linux lock blocks a separate Python process using flock', () async {
    final release = Completer<void>();
    final entered = Completer<void>();
    final holder = NativeCredentialFiles(directory).locked(() async {
      entered.complete();
      await release.future;
    });
    Process? process;
    StreamIterator<String>? lines;
    try {
      await entered.future;
      process = await Process.start('python3', [
        '-u',
        '-c',
        '''
import fcntl,sys
with open(sys.argv[1], 'r+') as file:
    print('attempting', flush=True)
    fcntl.flock(file.fileno(), fcntl.LOCK_EX)
    print('acquired', flush=True)
''',
        '${directory.path}/lock',
      ]);
      lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      expect(await lines.moveNext(), isTrue);
      expect(lines.current, 'attempting');
      var acquired = false;
      final result = lines.moveNext().then((value) {
        acquired = value;
        return value;
      });
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(acquired, isFalse);
      release.complete();
      await holder;
      expect(await result.timeout(const Duration(seconds: 5)), isTrue);
      expect(lines.current, 'acquired');
      expect(await process.exitCode, 0);
    } finally {
      if (!release.isCompleted) release.complete();
      await holder;
      process?.kill();
      await lines?.cancel();
    }
  }, skip: !Platform.isLinux);

  test('native lock blocks another isolate until release', () async {
    final messages = ReceivePort();
    final iterator = StreamIterator<dynamic>(messages);
    Isolate? worker;
    final release = Completer<void>();
    final entered = Completer<void>();
    final holder = NativeCredentialFiles(directory).locked(() async {
      entered.complete();
      await release.future;
    });
    try {
      await entered.future;
      worker = await Isolate.spawn(_lockWorker, (
        directory.path,
        messages.sendPort,
      ));
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current, 'attempting');
      var acquired = false;
      final result = iterator.moveNext().then((value) {
        acquired = value;
        return value;
      });
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(acquired, isFalse);
      release.complete();
      await holder;
      expect(await result.timeout(const Duration(seconds: 5)), isTrue);
      expect(iterator.current, 'acquired');
    } finally {
      if (!release.isCompleted) release.complete();
      await holder;
      worker?.kill(priority: Isolate.immediate);
      await iterator.cancel();
      messages.close();
    }
  });

  test('removal survives reopen and missing removal is idempotent', () async {
    final files = NativeCredentialFiles(directory);
    await files.write('credentials.json', 'synthetic');
    await files.remove('credentials.json');
    expect(
      await NativeCredentialFiles(directory).read('credentials.json'),
      isNull,
    );
    await files.remove('credentials.json');
  });

  test('reopens a durable credential outside notebook storage', () async {
    final files = NativeCredentialFiles(directory);
    expect(await files.read('credentials.json'), isNull);
    await files.write('credentials.json', 'synthetic-secret-ą');
    expect(
      await NativeCredentialFiles(directory).read('credentials.json'),
      'synthetic-secret-ą',
    );
  });
}

// Exercise the production validator's Darwin branch through a Linux C ABI
// facade. Only OS/library selection is translated; validation stays unchanged.
// This catches ACL API return-value/lifetime mistakes, not Darwin's calling
// convention, real filesystem ACLs or platform symbol availability.
Future<ProcessResult> _darwinAclProbe(
  Directory scratch, {
  required int scenario,
  bool directory = false,
}) async {
  final library = '${scratch.path}/darwin_acl_facade.so';
  final build = await Process.run('cc', [
    '-shared',
    '-fPIC',
    '-Wall',
    '-Wextra',
    '-Werror',
    '-o',
    library,
    'test/credential_files_native_harness.c',
    '-ldl',
  ]);
  expect(build.exitCode, 0, reason: build.stderr.toString());
  final original = File('lib/storage/credential_files_posix.dart')
      .readAsStringSync();
  final validator = original
      .substring(original.indexOf('class _Posix {'))
      .replaceFirst(
        'DynamicLibrary.process()',
        'DynamicLibrary.open(${jsonEncode(library)})',
      )
      .replaceFirst(
        'bool get _mac => Platform.isMacOS;',
        'bool get _mac => true;',
      )
      .replaceAll("'__error'", "'silique_darwin_errno'")
      .replaceAll("'fstat'", "'silique_darwin_fstat'");
  final probe = File('${scratch.path}/darwin_acl_probe.dart');
  probe.writeAsStringSync('''
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
$validator
void main() {
  final facade = DynamicLibrary.open(${jsonEncode(library)});
  facade.lookupFunction<Void Function(Int32), void Function(int)>(
      'silique_acl_scenario')($scenario);
  var rejected = false;
  try {
    _Posix().validate(${directory ? 74 : 73}, directory: $directory);
  } on FileSystemException {
    rejected = true;
  }
  final allocations = facade.lookupFunction<Int32 Function(), int Function()>(
      'silique_acl_allocations')();
  if (allocations != 0) throw StateError('ACL allocation leaked');
  if (rejected != ${scenario != 0 && scenario != 4}) {
    throw StateError('Expected ACL ${scenario == 0 || scenario == 4 ? 'acceptance' : 'rejection'}');
  }
  print(rejected ? 'rejected' : 'accepted');
}
''');
  final dart = _dartExecutable();
  if (dart == null) throw StateError('dart executable unavailable');
  return Process.run(dart, [
    '--packages=${File('.dart_tool/package_config.json').absolute.path}',
    probe.path,
  ]);
}

Future<void> _replaceWorker((String, SendPort) arguments) async {
  final (path, messages) = arguments;
  try {
    final files = NativeCredentialFiles(Directory(path));
    messages.send('ready');
    for (var i = 0; i < 40; i++) {
      await files.write('credentials.json', (i.isEven ? 'A' : 'B') * 131072);
    }
    messages.send('done');
  } catch (error) {
    messages.send(error.runtimeType.toString());
  }
}

Future<void> _lockWorker((String, SendPort) arguments) async {
  final (path, messages) = arguments;
  messages.send('attempting');
  try {
    await NativeCredentialFiles(Directory(path)).locked(() async {
      messages.send('acquired');
    });
  } catch (error) {
    messages.send(error.runtimeType.toString());
  }
}
