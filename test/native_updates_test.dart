import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/updates.dart';
import 'package:silique/storage/native_updates.dart';

/// Every native command is planned and dispatched through an injected runner,
/// so these tests never touch a real package manager or authorization dialog.
Future<ProcessResult> owned(String output) async =>
    ProcessResult(0, 0, output, '');
Future<ProcessResult> missing(
  String executable, [
  List<String> arguments = const [],
]) async => throw ProcessException(executable, arguments, 'missing', 2);

/// The exact template the Linux updater must hand to `/usr/bin/mktemp -d`:
/// coreutils replaces the twelve `X`s with unpredictable characters and creates
/// the directory atomically with mode 0700, whatever the process umask is.
const mktempTemplate = 'silique-updates-XXXXXXXXXXXX';

/// The name the fixed updater must produce: prefix plus exactly twelve
/// unpredictable alphanumeric characters.
final createdName = RegExp(r'^silique-updates-[A-Za-z0-9]{12}$');

/// Owner-only permissions (0700): no group and no other access at all.
const privateMode = 0x1c0;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const executable = '/opt/silique/silique';

  test('Windows download directory uses the native protected root without host-platform leakage', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeUpdateInstaller.channel, (call) async {
          calls.add(call);
          return r'C:\Users\synthetic\AppData\Local\silique-updates-native';
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeUpdateInstaller.channel, null),
    );
    final installer = NativeUpdateInstaller(
      temporaryDirectory: () async =>
          throw StateError('Windows must use native root'),
      runner: (exe, args) async =>
          throw StateError('No helper command expected'),
    );
    expect(
      await installer.downloadDirectory(),
      r'C:\Users\synthetic\AppData\Local\silique-updates-native',
    );
    expect(
      await installer.downloadDirectory(),
      r'C:\Users\synthetic\AppData\Local\silique-updates-native',
    );
    expect(calls.map((call) => call.method), ['downloadDirectory']);
  });

  /// A fresh, unrelated root plus the updater cache inside it. Removed after
  /// the test so nothing leaks into the tmpfs the tests run from.
  ({Directory root, Directory cache}) tree() {
    final root = Directory.systemTemp.createTempSync('silique-updater-cache-');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    return (root: root, cache: Directory('${root.path}/cache')..createSync());
  }

  test(
    'the running executable is matched to the package that owns it',
    () async {
      Future<ProcessResult> rpmOnly(String exe, List<String> args) async =>
          exe == '/usr/bin/rpm'
          ? await owned('silique\n')
          : ProcessResult(0, 1, '', 'not owned');
      expect(await linuxPackagePlatform(executable, rpmOnly), 'linux-rpm');

      Future<ProcessResult> debOnly(String exe, List<String> args) async =>
          exe == '/usr/bin/dpkg'
          ? await owned('silique: $executable\n')
          : ProcessResult(0, 1, '', 'not owned');
      expect(await linuxPackagePlatform(executable, debOnly), 'linux-deb');

      Future<ProcessResult> unowned(String exe, List<String> args) async =>
          ProcessResult(0, 1, '', 'not owned');
      // A portable tar install is not owned by any package: it stays manual.
      expect(await linuxPackagePlatform(executable, unowned), isNull);
      expect(
        await linuxPackagePlatform('/home/u/Silique/silique', unowned),
        isNull,
      );

      // A missing rpm/dpkg binary must not crash detection.
      expect(await linuxPackagePlatform(executable, missing), isNull);
      // Only an absolute path can be owned by a package manager.
      expect(await linuxPackagePlatform('relative/silique', unowned), isNull);
    },
  );

  test('unrelated package ownership cannot enable Silique updates', () async {
    Future<ProcessResult> unrelated(String exe, List<String> args) async =>
        ProcessResult(
          0,
          0,
          exe == rpmPath ? 'another-app\n' : 'another-app: $executable\n',
          '',
        );
    expect(await linuxPackagePlatform(executable, unrelated), isNull);
  });

  test('the install plan is an argument list, never a shell command', () {
    expect(
      linuxInstallCommand('linux-rpm', '/var/lib/silique/Silique-11.rpm'),
      [
        '/usr/bin/pkexec',
        '/usr/bin/dnf',
        'upgrade',
        '-y',
        '/var/lib/silique/Silique-11.rpm',
      ],
    );
    expect(
      linuxInstallCommand('linux-deb', '/var/lib/silique/Silique-11.deb'),
      [
        '/usr/bin/pkexec',
        '/usr/bin/apt-get',
        'install',
        '-y',
        '/var/lib/silique/Silique-11.deb',
      ],
    );
    // The portable tar and unknown platforms have no automatic plan.
    expect(
      linuxInstallCommand('linux', '/var/lib/silique/Silique.tar.gz'),
      isNull,
    );
    expect(linuxInstallCommand('windows', r'C:\Silique.exe'), isNull);
    // A relative path is never handed to the privileged installer.
    expect(linuxInstallCommand('linux-deb', 'Silique.deb'), isNull);
    // Security defaults are never weakened.
    expect(
      linuxInstallCommand('linux-rpm', '/pkg.rpm'),
      isNot(contains('--nogpgcheck')),
    );
    expect(
      linuxInstallCommand('linux-deb', '/pkg.deb'),
      isNot(contains('--allow-unauthenticated')),
    );
  });

  test(
    'a verified package is installed only through the validated pkexec plan',
    () async {
      final commands = <List<String>>[];
      final installer = NativeUpdateInstaller(
        runner: (exe, args) async {
          commands.add([exe, ...args]);
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(
        await installer.installLinux(
          'linux-rpm',
          '/var/lib/silique/Silique-11.rpm',
        ),
        LinuxInstallOutcome.installed,
      );
      expect(
        commands.single,
        linuxInstallCommand('linux-rpm', '/var/lib/silique/Silique-11.rpm'),
      );
    },
  );

  test(
    'a dismissed authorization is cancelled and other failures are reported',
    () async {
      Future<LinuxInstallOutcome> withCode(int code) => NativeUpdateInstaller(
        runner: (exe, args) async => ProcessResult(0, code, '', ''),
      ).installLinux('linux-deb', '/var/lib/silique/Silique-11.deb');

      // pkexec returns 126 when the user dismisses the authentication dialog.
      expect(await withCode(126), LinuxInstallOutcome.cancelled);
      expect(await withCode(127), LinuxInstallOutcome.failed);
      expect(await withCode(1), LinuxInstallOutcome.failed);
      expect(await withCode(0), LinuxInstallOutcome.installed);

      final throwing = NativeUpdateInstaller(
        runner: (exe, args) async =>
            throw ProcessException('pkexec', const [], 'no', 1),
      );
      expect(
        await throwing.installLinux(
          'linux-deb',
          '/var/lib/silique/Silique-11.deb',
        ),
        LinuxInstallOutcome.failed,
      );

      var ran = false;
      final unknown = NativeUpdateInstaller(
        runner: (exe, args) async {
          ran = true;
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(
        await unknown.installLinux('linux', '/var/lib/silique/Silique.tar.gz'),
        LinuxInstallOutcome.failed,
      );
      expect(ran, false);
    },
  );

  group('Linux private download directories', () {
    // These tests assert the Linux updater path, so they must report a Linux
    // target platform: flutter_test otherwise forces defaultTargetPlatform to
    // TargetPlatform.android, and downloadDirectory would take the shared
    // fixed-path branch meant for Android/macOS instead of mktemp -d.
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.linux);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('the download directory is created by mktemp -d and is private the moment '
        'it exists, so no chmod window can be hijacked', () async {
      final paths = tree();
      final commands = <List<String>>[];
      // The mode every directory had at the first instant a subprocess could
      // observe it: exactly the window in which a predictable directory could
      // be swapped for a symlink before the updater wrote installer bytes.
      final observedModes = <int>[];

      Future<ProcessResult> runner(
        String executable,
        List<String> arguments,
      ) async {
        commands.add([executable, ...arguments]);
        if (executable == mktempPath) {
          // A controlled subprocess forces umask 000 - the worst case for a
          // directory created by a plain mkdir (Dart's Directory.createTemp
          // hands back 0777 there). mktemp -d must still deliver 0700, so the
          // directory is never briefly world-writable.
          final result = await Process.run('/bin/sh', [
            '-c',
            r'umask 000; exec "$0" "$@"',
            executable,
            ...arguments,
          ], runInShell: false);
          final created = '${result.stdout}'.trim();
          if (result.exitCode == 0 && created.isNotEmpty) {
            observedModes.add(FileStat.statSync(created).mode & 0x1ff);
          }
          return result;
        }
        // Any other command the updater runs before handing the directory out
        // (a legacy `chmod`) is recorded with the mode of its target.
        final target = arguments.isEmpty ? null : arguments.last;
        if (target != null && Directory(target).existsSync()) {
          observedModes.add(FileStat.statSync(target).mode & 0x1ff);
        }
        return Process.run(executable, arguments, runInShell: false);
      }

      final installer = NativeUpdateInstaller(
        temporaryDirectory: () async => paths.cache,
        runner: runner,
      );
      final directory = await installer.downloadDirectory();

      expect(observedModes, [privateMode]);
      expect(commands, [
        [mktempPath, '-d', '--', '${paths.cache.path}/$mktempTemplate'],
      ]);
      expect(directory, startsWith('${paths.cache.path}/'));
      expect(createdName.hasMatch(directory.split('/').last), isTrue);
      expect(
        FileSystemEntity.typeSync(directory, followLinks: false),
        FileSystemEntityType.directory,
      );
      expect(FileStat.statSync(directory).mode & 0x1ff, privateMode);
      expect(Directory(directory).listSync(followLinks: false), isEmpty);
      // The privileged installer is never involved in preparing the cache.
      expect(
        commands.expand((command) => command),
        isNot(contains(pkexecPath)),
      );
    });

    test(
      'download directories are unpredictable, private and reused per run',
      () async {
        final paths = tree();
        final other = Directory('${paths.root.path}/other')..createSync();
        // A predictable name is no longer what the updater uses; a symlink
        // planted there must stay untouched and never receive installer bytes.
        final planted = Link('${paths.cache.path}/silique-updates');
        await planted.create(other.path);

        final calls = <String>[];
        final created = <String>[];
        NativeUpdateInstaller installer() => NativeUpdateInstaller(
          temporaryDirectory: () async => paths.cache,
          runner: (exe, args) async {
            calls.add(exe);
            final result = await Process.run(exe, args, runInShell: false);
            if (exe == mktempPath && result.exitCode == 0) {
              created.add('${result.stdout}'.trim());
            }
            return result;
          },
        );

        final firstInstaller = installer();
        final first = await firstInstaller.downloadDirectory();
        final second = await installer().downloadDirectory();

        expect(calls, [mktempPath, mktempPath]);
        expect(created, [first, second]);
        expect(first, isNot(second));
        for (final path in [first, second]) {
          expect(path, startsWith('${paths.cache.path}/'));
          expect(Directory(path).parent.path, paths.cache.path);
          expect(createdName.hasMatch(path.split('/').last), isTrue);
          expect(
            FileSystemEntity.typeSync(path, followLinks: false),
            FileSystemEntityType.directory,
          );
          expect(FileStat.statSync(path).mode & 0x1ff, privateMode);
          expect(Directory(path).listSync(followLinks: false), isEmpty);
        }
        // The verified-file cache still survives a retry after permission_required.
        expect(await firstInstaller.downloadDirectory(), first);
        expect(created, hasLength(2));
        expect(calls, hasLength(2));
        expect(await planted.target(), other.path);
        expect(other.listSync(followLinks: false), isEmpty);
      },
    );

    test(
      'a failing or lying mktemp fails closed and hands out nothing',
      () async {
        final paths = tree();
        final cache = paths.cache.path;
        Future<ProcessResult> answer(String stdout, [int code = 0]) async =>
            ProcessResult(0, code, stdout, '');
        NativeUpdateInstaller installer(
          Future<ProcessResult> Function(String, List<String>) runner,
        ) => NativeUpdateInstaller(
          temporaryDirectory: () async => paths.cache,
          runner: runner,
        );
        Future<void> rejected(
          Future<ProcessResult> Function(String, List<String>) runner,
        ) => expectLater(
          installer(runner).downloadDirectory(),
          throwsA(isA<FileSystemException>()),
        );

        // The tool is missing, or reported a failure.
        await rejected(missing);
        await rejected((exe, args) => answer('', 1));
        await rejected((exe, args) => answer('mktemp: failed to create', 2));
        // A success without exactly one absolute path is not usable.
        await rejected((exe, args) => answer(''));
        await rejected((exe, args) => answer('   \n\n'));
        await rejected((exe, args) => answer('silique-updates-AAAAAAAAAAAA'));
        await rejected(
          (exe, args) =>
              answer('$cache/$mktempTemplate\n$cache/$mktempTemplate'),
        );
        expect(paths.cache.listSync(followLinks: false), isEmpty);

        // A valid-looking directory outside the cache is refused and never removed.
        final outside = Directory(
          '${paths.root.path}/outside/silique-updates-AAAAAAAAAAAA',
        )..createSync(recursive: true);
        await rejected((exe, args) => answer(outside.path));
        expect(outside.existsSync(), isTrue);

        // Only a direct child of the cache, and only with the expected name.
        final nested = Directory('$cache/nested/silique-updates-BBBBBBBBBBBB')
          ..createSync(recursive: true);
        await rejected((exe, args) => answer(nested.path));
        expect(nested.existsSync(), isTrue);

        final wrongName = Directory('$cache/silique-updater-CCCCCCCCCCCC')
          ..createSync();
        await rejected((exe, args) => answer(wrongName.path));
        expect(wrongName.existsSync(), isTrue);

        // A file that merely carries the name is not a directory.
        final plantedFile = File('$cache/silique-updates-DDDDDDDDDDDD')
          ..writeAsStringSync('x');
        await rejected((exe, args) => answer(plantedFile.path));
        expect(plantedFile.readAsStringSync(), 'x');
      },
    );

    test(
      'a symlinked or polluted candidate is never used and never deleted',
      () async {
        final paths = tree();
        final cache = paths.cache.path;
        final target = Directory('${paths.root.path}/target')..createSync();
        File('${target.path}/keep').writeAsStringSync('keep');
        final link = Link('$cache/silique-updates-AAAAAAAAAAAA');
        await link.create(target.path);
        final polluted = Directory('$cache/silique-updates-BBBBBBBBBBBB')
          ..createSync();
        File('${polluted.path}/planted').writeAsStringSync('planted');

        NativeUpdateInstaller installer(String reported) =>
            NativeUpdateInstaller(
              temporaryDirectory: () async => paths.cache,
              runner: (exe, args) async =>
                  ProcessResult(0, 0, '$reported\n', ''),
            );
        Future<void> rejected(String reported) => expectLater(
          installer(reported).downloadDirectory(),
          throwsA(isA<FileSystemException>()),
        );

        // A symlink is not the directory mktemp created: never followed, never
        // written to, and never removed as if it were this run's own directory.
        await rejected(link.path);
        expect(
          FileSystemEntity.typeSync(link.path, followLinks: false),
          FileSystemEntityType.link,
        );
        expect(await link.target(), target.path);
        expect(File('${target.path}/keep').readAsStringSync(), 'keep');

        // A directory whose contents this run did not write is refused and left
        // alone instead of being wiped recursively.
        await rejected(polluted.path);
        expect(File('${polluted.path}/planted').readAsStringSync(), 'planted');
      },
    );

    test('an insecure directory is refused and only this run\'s own empty '
        'directory is cleaned up', () async {
      final paths = tree();
      final insecure = Directory(
        '${paths.cache.path}/silique-updates-EEEEEEEEEEEE',
      )..createSync();
      // Group/other readable even under an unusual umask.
      await Process.run('/usr/bin/chmod', ['755', insecure.path]);
      expect(FileStat.statSync(insecure.path).mode & 0x1ff, isNot(privateMode));

      final installer = NativeUpdateInstaller(
        temporaryDirectory: () async => paths.cache,
        runner: (exe, args) async =>
            ProcessResult(0, 0, '${insecure.path}\n', ''),
      );
      await expectLater(
        installer.downloadDirectory(),
        throwsA(isA<FileSystemException>()),
      );
      // Empty and provably not a symlink, so the failed attempt removes it.
      expect(insecure.existsSync(), isFalse);
      expect(paths.cache.listSync(followLinks: false), isEmpty);
    });
  }, skip: !Platform.isLinux);

  group('the non-Linux download directory keeps the native installer contract', () {
    // On Android and macOS the download directory is not an implementation
    // detail: SiliqueUpdates.kt canonicalises <cacheDir>/silique-updates as the
    // only root it will open an APK from, and update_paths.xml exposes exactly
    // that path through the FileProvider. A random sibling such as
    // silique-updates-XXXXXXXXXXXX makes the native installer reject the file.
    const fixedName = 'silique-updates';
    final apkName = RegExp(r'^Silique-[0-9]+\.apk$');

    for (final platform in const [
      TargetPlatform.android,
      TargetPlatform.macOS,
    ]) {
      test(
        'on $platform the real downloadDirectory is the fixed native root and '
        'never starts a privileged helper',
        () async {
          debugDefaultTargetPlatformOverride = platform;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);

          final paths = tree();
          final commands = <List<String>>[];
          // Every subprocess the updater would start is recorded and executed,
          // so a leaked Linux mktemp/chmod is observable here.
          final installer = NativeUpdateInstaller(
            temporaryDirectory: () async => paths.cache,
            runner: (exe, args) async {
              commands.add([exe, ...args]);
              return Process.run(exe, args, runInShell: false);
            },
          );

          final directory = await installer.downloadDirectory();

          // The one path SiliqueUpdates.kt and update_paths.xml agree on.
          expect(directory, '${paths.cache.path}/$fixedName');
          expect(Directory(directory).parent.path, paths.cache.path);
          // The verified APK lands directly in that root: this is exactly the
          // apk.parentFile == root check the native installer performs.
          final apk = File('$directory/Silique-12.apk')
            ..writeAsStringSync('apk');
          expect(apk.parent.path, directory);
          expect(apkName.hasMatch(apk.uri.pathSegments.last), isTrue);
          // No unpredictable directory is left beside the fixed one.
          expect(
            paths.cache
                .listSync(followLinks: false)
                .whereType<Directory>()
                .map((entry) => entry.uri),
            [Directory(directory).uri],
          );
          // Preparing the cache on Android/macOS must not run mktemp, chmod or
          // the privileged package installer at all.
          expect(commands, isEmpty);
          // The verified-file cache still survives a retry after
          // permission_required, on the same fixed path.
          expect(await installer.downloadDirectory(), directory);
          expect(commands, isEmpty);
        },
      );
    }
  });
}
