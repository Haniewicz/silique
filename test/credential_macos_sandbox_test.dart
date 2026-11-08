import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// These probes run the production POSIX session in a child Dart process.
// On macOS Seatbelt denies reading one ancestor, but permits its descendants,
// just as an App Sandbox can allow its container without directory listing
// rights over the user's Library. No owner files or keychain are involved.
void main() {
  test('Darwin pins the whole no-symlink path without reading ancestors (binding contract)', () async {
    if (!Platform.isLinux) return;
    final root = Directory.systemTemp.createTempSync('silique-mac-binding-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = File('lib/storage/credential_files_posix.dart')
        .readAsStringSync()
        .replaceFirst("part of 'credential_files.dart';", '')
        .replaceFirst(
          'bool get _mac => Platform.isMacOS;',
          'bool get _mac => true;',
        )
        .replaceFirst('if (Platform.isMacOS)', 'if (true)');
    final probe = File('${root.path}/binding.dart')
      ..writeAsStringSync('''
import 'dart:ffi' hide DynamicLibrary;
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:ffi/ffi.dart';
abstract class _CredentialSession {
  bool active = true;
  Future<void> acquire();
  String? read(String name);
  void write(String name, String value);
  void remove(String name);
  void close();
}
String _decodeCredentialBytes(List<int> bytes) => utf8.decode(bytes);
final opened = <String>[];
class DynamicLibrary {
  static DynamicLibrary process() => DynamicLibrary();
  F lookupFunction<T extends Function, F extends Function>(String name) {
    if (name == 'openat') {
      return ((int parent, Pointer<Utf8> path, int flags, int mode) {
        final value = path.toDartString();
        opened.add(value);
        if (value != '/sandbox-denied/allowed/credentials') {
          throw StateError('Must not read an ancestor: \$value');
        }
        if (parent != -2 || flags & 0x20000000 == 0 || flags & 0x100000 == 0) {
          throw StateError('Must pin the complete directory with O_NOFOLLOW_ANY');
        }
        if (flags & 0x100 != 0) {
          throw StateError('Darwin rejects O_NOFOLLOW_ANY combined with O_NOFOLLOW');
        }
        // Stop after observing the real open, before the stat/ACL contract.
        throw const _Observed();
      }) as F;
    }
    if (name == 'close') return ((int fd) => 0) as F;
    throw StateError('Unexpected binding: \$name');
  }
}
class _Observed implements Exception { const _Observed(); }
$source
void main() {
  try {
    _PosixCredentialSession(Directory('/sandbox-denied/allowed/credentials'));
    throw StateError('Session failed to open the directory');
  } on _Observed {
    if (opened.length != 1) throw StateError('Unexpected ancestor reads');
  }
}
''');
    final result = await _runDart(probe);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });

  test('macOS Seatbelt permits credentials beneath an unreadable ancestor', () async {
    if (!Platform.isMacOS) {
      markTestSkipped('Requires real macOS Seatbelt');
      return;
    }
    final temporary = Directory.systemTemp.createTempSync('silique-seatbelt-');
    final root = Directory(temporary.resolveSymbolicLinksSync());
    addTearDown(() => root.deleteSync(recursive: true));
    final ancestor = Directory('${root.path}/unreadable')..createSync();
    final support = Directory('${ancestor.path}/allowed-support')..createSync();
    final directory = '${support.path}/credentials';
    final profile = File('${root.path}/probe.sb')
      ..writeAsStringSync('''
(version 1)
(allow default)
(deny file-read-data (literal ${jsonEncode(ancestor.path)}))
''');
    final source = File('lib/storage/credential_files_posix.dart')
        .readAsStringSync()
        .replaceFirst("part of 'credential_files.dart';", '');
    final probe = File('${root.path}/probe.dart')
      ..writeAsStringSync('''
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:ffi/ffi.dart';
abstract class _CredentialSession {
  bool active = true;
  Future<void> acquire();
  String? read(String name);
  void write(String name, String value);
  void remove(String name);
  void close();
}
String _decodeCredentialBytes(List<int> bytes) => utf8.decode(bytes);
$source
Future<void> main() async {
  final p = _Posix();
  // Reproduce the old walk's OS failure, not an injected Dart exception.
  var denied = false;
  final fd = p.tryOpenAt(p.atCwd, ${jsonEncode(ancestor.path)}, p.directoryFlags);
  if (fd >= 0) { p.close(fd); } else { denied = p.errno == 1; }
  if (!denied) throw StateError('Seatbelt did not reproduce EPERM');
  for (var attempt = 0; attempt < 2; attempt++) {
    final session = _PosixCredentialSession(Directory(${jsonEncode(directory)}));
    try {
      await session.acquire();
      if (attempt == 0) {
        session.write('credentials.json', 'synthetic-original-key');
      }
      if (session.read('credentials.json') != 'synthetic-original-key') {
        throw StateError('Original credential did not survive reopen');
      }
      session.write('state.json', 'synthetic-metadata');
      session.remove('state.json');
    } finally { session.close(); }
  }
  // A direct path must retain the old walk's all-components symlink rejection.
  final child = _PosixCredentialSession(Directory(${jsonEncode('$directory/child')}));
  child.close(); // Existing 0700 target: ENOENT must not mask a followed symlink.
  final alias = Link(${jsonEncode('${support.path}/alias')});
  alias.createSync(${jsonEncode(directory)});
  var rejected = false;
  try {
    _PosixCredentialSession(Directory('\${alias.path}/child')).close();
  } on FileSystemException { rejected = true; }
  if (!rejected) throw StateError('Symlinked ancestor accepted');
  print('EPERM reproduced; create/reopen/write/remove passed; symlink rejected');
}
''');
    final result = await _runDart(probe, sandboxProfile: profile.path);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(
      result.stdout,
      contains(
        'EPERM reproduced; create/reopen/write/remove passed; symlink rejected',
      ),
    );
  });
}

Future<ProcessResult> _runDart(File probe, {String? sandboxProfile}) async {
  final candidates = <String>[
    if (Platform.environment['DART'] case final String dart) dart,
    if (Platform.environment['FLUTTER_ROOT'] case final String flutter)
      '$flutter/bin/dart',
  ];
  var directory = File(Platform.resolvedExecutable).parent;
  for (var depth = 0; depth < 8; depth++) {
    candidates.addAll(['${directory.path}/dart', '${directory.path}/bin/dart']);
    directory = directory.parent;
  }
  candidates.add('dart');
  for (final dart in candidates) {
    try {
      if ((await Process.run(dart, ['--version'])).exitCode != 0) continue;
      final arguments = [
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        probe.path,
      ];
      return await (sandboxProfile == null
          ? Process.run(dart, arguments)
          : Process.run('/usr/bin/sandbox-exec', [
              '-f',
              sandboxProfile,
              dart,
              ...arguments,
            ]));
    } on ProcessException {
      continue;
    }
  }
  throw StateError('Dart executable unavailable for native sandbox probe');
}
