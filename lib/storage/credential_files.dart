import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart' as win;

import '../core/credential_mode.dart';

part 'credential_files_posix.dart';
part 'credential_files_windows.dart';

/// Private plaintext credential persistence, outside the notebook tree.
///
/// Filesystem/permission/durability errors are fatal; callers must retain their
/// previous authoritative credential source on any failure. This is access
/// control, not encryption or protection against another process of this user.
class NativeCredentialFiles implements CredentialFiles {
  NativeCredentialFiles(this.directory);

  final Directory directory;
  final Object _zoneKey = Object();

  static Future<NativeCredentialFiles> forSupport(Directory support) async {
    if (Platform.isAndroid) {
      // path_provider's support directory may be included in Android backups.
      // Resolve the actual Context.noBackupFilesDir, never infer it from a path.
      final root = await const MethodChannel(
        'silique.notes/credential-directory',
      ).invokeMethod<String>('noBackupDirectory');
      if (root == null || !root.startsWith('/') || root.contains('\u0000')) {
        throw FileSystemException(
          'Android private no-backup directory unavailable',
        );
      }
      return NativeCredentialFiles(Directory('$root/credentials'));
    }
    return NativeCredentialFiles(Directory('${support.path}/credentials'));
  }

  _CredentialSession _open() {
    if (Platform.isWindows) return _WindowsCredentialSession(directory);
    if (Platform.isLinux || Platform.isMacOS || Platform.isAndroid) {
      return _PosixCredentialSession(directory);
    }
    throw UnsupportedError('Private native credential files unavailable');
  }

  @override
  Future<T> locked<T>(Future<T> Function() operation) async {
    final active = Zone.current[_zoneKey] as _CredentialSession?;
    if (active != null) {
      if (!active.active) throw StateError('Credential transaction has ended');
      return operation();
    }
    final session = _open();
    try {
      await session.acquire();
      return await runZoned(operation, zoneValues: {_zoneKey: session});
    } finally {
      session.active = false;
      session.close();
    }
  }

  void _validate(String name) {
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,95}$').hasMatch(name) ||
        name.endsWith('.') ||
        name.toLowerCase() == 'lock' ||
        name.contains('..') ||
        RegExp(
          r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
          caseSensitive: false,
        ).hasMatch(name)) {
      throw ArgumentError('Unsafe credential basename');
    }
  }

  @override
  Future<String?> read(String name) {
    _validate(name);
    return locked(
      () async => (Zone.current[_zoneKey] as _CredentialSession).read(name),
    );
  }

  @override
  Future<void> write(String name, String value) {
    _validate(name);
    return locked(
      () async =>
          (Zone.current[_zoneKey] as _CredentialSession).write(name, value),
    );
  }

  @override
  Future<void> remove(String name) {
    _validate(name);
    return locked(
      () async => (Zone.current[_zoneKey] as _CredentialSession).remove(name),
    );
  }
}

String _decodeCredentialBytes(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    // Do not let decoding errors carry source data into caller diagnostics.
    throw FileSystemException('Invalid credential file encoding');
  }
}

abstract class _CredentialSession {
  bool active = true;
  Future<void> acquire();
  String? read(String name);
  void write(String name, String value);
  void remove(String name);
  void close();
}
