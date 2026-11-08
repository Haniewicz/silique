import '../l10n/strings.dart';

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/updates.dart';

/// Runs one native command as an argument list (never a shell string) and
/// returns its result. It is injectable so callers can be tested without a real
/// package manager or an authorization dialog.
typedef UpdateProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// Absolute paths of the fixed system tools the updater is allowed to run.
const pkexecPath = '/usr/bin/pkexec';
const rpmPath = '/usr/bin/rpm';
const dpkgPath = '/usr/bin/dpkg';
const dnfPath = '/usr/bin/dnf';
const aptGetPath = '/usr/bin/apt-get';
const mktempPath = '/usr/bin/mktemp';

/// Name prefix of the updater's download directory inside the cache.
const _updateDirectoryPrefix = 'silique-updates-';

/// Placeholders coreutils replaces with unpredictable characters, so two runs
/// (and two machines) never share a predictable path.
const _mktempPlaceholders = 'XXXXXXXXXXXX';

/// Reports which packaging system owns [executable]: 'linux-rpm' when rpm owns
/// it, 'linux-deb' when dpkg owns it, or null when no package owns it (a
/// portable tar install). Ownership of the *running executable* is what matters
/// — not the mere presence of a package manager on the machine.
Future<String?> linuxPackagePlatform(
  String executable,
  UpdateProcessRunner run,
) async {
  if (!executable.startsWith('/')) return null;
  Future<String?> owner(String tool, List<String> arguments) async {
    try {
      final result = await run(tool, arguments);
      return result.exitCode == 0 ? '${result.stdout}'.trim() : null;
    } catch (_) {
      return null;
    }
  }

  final rpmOwner = await owner(rpmPath, [
    '-qf',
    '--qf',
    '%{NAME}\\n',
    executable,
  ]);
  if (rpmOwner == 'silique') return 'linux-rpm';
  final debOwner = await owner(dpkgPath, ['-S', executable]);
  final debPattern = RegExp(
    '^silique(?::[a-z0-9-]+)?: ${RegExp.escape(executable)}\$',
  );
  if (debOwner != null && debPattern.hasMatch(debOwner)) return 'linux-deb';
  return null;
}

/// Builds the argument vector that installs a verified local package. Kept pure
/// so the exact plan can be asserted without running anything. Returns null for
/// any platform or path the updater must not handle automatically.
List<String>? linuxInstallCommand(String platform, String path) {
  if (!path.startsWith('/')) return null;
  return switch (platform) {
    'linux-rpm' => [pkexecPath, dnfPath, 'upgrade', '-y', path],
    'linux-deb' => [pkexecPath, aptGetPath, 'install', '-y', path],
    _ => null,
  };
}

class NativeUpdateInstaller
    implements UpdateInstaller, LinuxUpdateInstaller, WindowsUpdateInstaller {
  NativeUpdateInstaller({
    UpdateProcessRunner? runner,
    Future<Directory> Function()? temporaryDirectory,
  }) : _run = runner ?? _defaultRun,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;
  static const channel = MethodChannel('silique.notes/updates');
  final UpdateProcessRunner _run;
  final Future<Directory> Function() _temporaryDirectory;
  String? _updateDirectory;

  static Future<ProcessResult> _defaultRun(
    String executable,
    List<String> arguments,
  ) => Process.run(executable, arguments, runInShell: false);

  /// The cache the download directory must live in, with exactly one trailing
  /// separator so a reported path can be compared as its direct child.
  static String _cachePrefix(Directory base) {
    final path = base.absolute.path;
    return path.endsWith('/') ? path : '$path/';
  }

  /// Accepts the output of `mktemp -d` only when it is exactly one absolute
  /// path that is a direct child of [prefix] carrying the expected name prefix.
  static String _reportedDirectory(Object? stdout, String prefix) {
    final lines = '$stdout'.split('\n').where((line) => line.isNotEmpty);
    if (lines.length != 1) throw _updateDirectoryUnavailable();
    final path = lines.single;
    if (!path.startsWith('/')) throw _updateDirectoryUnavailable();
    if (!path.startsWith(prefix)) throw _updateDirectoryUnavailable();
    final name = path.substring(prefix.length);
    if (!name.startsWith(_updateDirectoryPrefix) ||
        name.trim() != name ||
        name.contains('/')) {
      throw _updateDirectoryUnavailable();
    }
    return path;
  }

  /// The one failure a caller ever sees for a download directory: without a
  /// verified private directory the updater must never fail open.
  static FileSystemException _updateDirectoryUnavailable() =>
      FileSystemException(
        tr(
          'Nie można zabezpieczyć katalogu aktualizacji.',
          'Could not secure the update directory.',
        ),
      );

  /// Best-effort removal of the directory this run just created, and only of
  /// it: the path was already validated as a real directory directly inside the
  /// cache. The deletion is not recursive, so a directory that anything else
  /// has written to is left in place instead of being wiped.
  static Future<void> _discardOwnDirectory(Directory directory) async {
    try {
      await directory.delete();
    } catch (_) {
      // Clean-up is best effort and must not hide the original failure.
    }
  }

  @override
  Future<InstalledApp?> info() async {
    // flutter_tester is not an installed application. Native package queries
    // must not start subprocesses/timers in the widget test's FakeAsync zone.
    if (Platform.environment['FLUTTER_TEST'] == 'true') return null;
    if (Platform.isLinux) return _linuxInfo();
    if (Platform.isWindows) return windowsInfo();
    if (!(Platform.isMacOS || Platform.isAndroid)) return null;
    try {
      final value = await channel.invokeMapMethod<String, dynamic>('info');
      if (value == null) return null;
      return InstalledApp(
        value['version'] as String,
        value['build'] as int,
        Platform.isMacOS ? 'macos' : 'android',
      );
    } on MissingPluginException {
      // Unit/widget tests have no native application. Never start network
      // checks against the real release feed in those environments.
      return null;
    }
  }

  Future<InstalledApp?> windowsInfo() async {
    final value = await channel.invokeMapMethod<String, dynamic>('info');
    if (value == null) return null;
    final platform = value['platform'];
    return InstalledApp(
      value['version'] as String,
      value['build'] as int,
      platform == 'windows' ? 'windows' : 'windows-portable',
    );
  }

  /// Reads the build number baked into the binary, then resolves the platform
  /// from the package that actually owns the running executable.
  Future<InstalledApp?> _linuxInfo() async {
    const version = String.fromEnvironment('FLUTTER_BUILD_NAME');
    const build = int.fromEnvironment('FLUTTER_BUILD_NUMBER');
    if (version.isEmpty || build < 1) return null;
    final platform =
        await linuxPackagePlatform(Platform.resolvedExecutable, _run) ??
        'linux';
    return InstalledApp(version, build, platform);
  }

  @override
  Future<String> downloadDirectory() async {
    // Reuse one directory per run: it keeps the verified-file cache working
    // across a retry after permission_required.
    final prepared = _updateDirectory;
    if (prepared != null) return prepared;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      final path = await channel.invokeMethod<String>('downloadDirectory');
      if (path == null || path.isEmpty) throw _updateDirectoryUnavailable();
      return _updateDirectory = path;
    }
    final base = await _temporaryDirectory();
    await base.create(recursive: true);
    if (defaultTargetPlatform != TargetPlatform.linux) {
      // Android (and macOS) share one fixed cache child instead of an
      // unpredictable sibling: SiliqueUpdates.kt canonicalises
      // <cacheDir>/silique-updates as the only root it will install from, and
      // update_paths.xml exposes exactly that path through the FileProvider, so
      // the verified APK must land directly in it. Only the Linux updater hands
      // a path out of this cache to the privileged package manager, so only it
      // needs the unpredictable, mktemp-created directory below.
      final directory = Directory('${base.path}/silique-updates');
      await directory.create(recursive: true);
      return _updateDirectory = directory.path;
    }
    return _updateDirectory = await _createLinuxDirectory(base);
  }

  /// Creates and verifies the per-run download directory on Linux.
  ///
  /// `Directory.createTemp` honours the process umask, so it can return a
  /// group- or world-accessible directory, and repairing that with a later
  /// `chmod` subprocess leaves a window in which the predictable path can be
  /// replaced by a symlink. `/usr/bin/mktemp -d` creates the directory
  /// atomically with mode 0700 instead, and every property of the result is
  /// checked here before a single installer byte is written: a successful exit,
  /// exactly one absolute path that is a direct child of the cache with the
  /// expected name prefix, a real (never symlinked) directory with mode 0700
  /// and no entries at all. Anything else fails closed.
  Future<String> _createLinuxDirectory(Directory base) async {
    final prefix = _cachePrefix(base);
    final ProcessResult result;
    try {
      result = await _run(mktempPath, [
        '-d',
        '--',
        '$prefix$_updateDirectoryPrefix$_mktempPlaceholders',
      ]);
    } catch (_) {
      throw _updateDirectoryUnavailable();
    }
    if (result.exitCode != 0) throw _updateDirectoryUnavailable();
    final path = _reportedDirectory(result.stdout, prefix);
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      // A symlink, a file or an already missing entry is not the directory
      // mktemp just created: never follow it, write through it or delete it.
      throw _updateDirectoryUnavailable();
    }
    try {
      final directory = Directory(path);
      if ((await directory.stat()).mode & 0x1ff != 0x1c0) {
        throw _updateDirectoryUnavailable();
      }
      if (!await directory.list(followLinks: false).isEmpty) {
        // Something wrote here between creation and use: the directory is no
        // longer ours to trust.
        throw _updateDirectoryUnavailable();
      }
      return path;
    } catch (_) {
      await _discardOwnDirectory(Directory(path));
      rethrow;
    }
  }

  @override
  Future<String> installAndroid(String path) async =>
      await channel.invokeMethod<String>('installAndroid', path) ?? 'started';

  @override
  Future<void> installMac() => channel.invokeMethod<void>('installMac');

  @override
  Future<WindowsInstallOutcome> installWindows(
    String path,
    AppRelease release,
    UpdateArtifact artifact,
  ) async {
    final result = await channel.invokeMethod<String>('installWindows', {
      'path': path.replaceAll('/', '\\'),
      'version': release.version,
      'build': release.build,
      'sha256': artifact.sha256,
      'size': artifact.size,
    });
    return switch (result) {
      'launched' => WindowsInstallOutcome.launched,
      'cancelled' => WindowsInstallOutcome.cancelled,
      _ => WindowsInstallOutcome.failed,
    };
  }

  @override
  Future<LinuxInstallOutcome> installLinux(String platform, String path) async {
    final command = linuxInstallCommand(platform, path);
    if (command == null) return LinuxInstallOutcome.failed;
    try {
      final result = await _run(command.first, command.sublist(1));
      return switch (result.exitCode) {
        0 => LinuxInstallOutcome.installed,
        // pkexec reports 126 when the user dismisses the auth dialog.
        126 => LinuxInstallOutcome.cancelled,
        _ => LinuxInstallOutcome.failed,
      };
    } catch (_) {
      // Never surface raw process output: it could leak local paths.
      return LinuxInstallOutcome.failed;
    }
  }
}
