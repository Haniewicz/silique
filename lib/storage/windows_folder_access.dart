import '../l10n/strings.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Only the native helper can establish CFA evidence. SQLite/write errors cannot.
enum FolderAccessStatus { confirmed, unconfirmed, allowed, cancelled, failed }

class FolderAccessResult {
  const FolderAccessResult._(
    this.status,
    this.root,
    this.executable,
    this.message, {
    this.canRequest = false,
  });

  final FolderAccessStatus status;
  final String root;
  final String executable;
  final String message;

  /// Native install/ACL validation, not inferred from a directory name in Dart.
  /// Missing/invalid fields in older helpers fail closed.
  final bool canRequest;
}

typedef FolderAccessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

class WindowsFolderAccess {
  WindowsFolderAccess({
    bool? isWindows,
    String? resolvedExecutable,
    FolderAccessRunner? runProcess,
    this.inspectionTimeout = const Duration(seconds: 10),
    this.requestTimeout = const Duration(minutes: 5),
  }) : isWindows = isWindows ?? Platform.isWindows,
       executable = resolvedExecutable ?? Platform.resolvedExecutable,
       _runProcess = runProcess ?? _run;

  final bool isWindows;
  final String executable;
  final FolderAccessRunner _runProcess;
  final Duration inspectionTimeout;
  final Duration requestTimeout;
  FolderAccessResult? _confirmation;
  bool _requestAttempted = false;
  int _inspectionGeneration = 0;

  static Future<ProcessResult> _run(
    String executable,
    List<String> arguments,
  ) => runTransport(executable, arguments);

  /// The helper emits UTF-8 JSON, but `Process.run` otherwise decodes stdout
  /// with the active Windows code page. A path outside ASCII (an install folder
  /// like `C:\Program Files\Żółć`) would then never equal the executable path
  /// the app recorded, and a correct reply would be treated as unverified.
  @visibleForTesting
  static Future<ProcessResult> runTransport(
    String executable,
    List<String> arguments,
  ) => Process.run(
    executable,
    arguments,
    runInShell: false,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );

  String get _helper {
    final slash = executable.lastIndexOf(RegExp(r'[/\\]'));
    return '${executable.substring(0, slash)}\\silique_folder_access.exe';
  }

  FolderAccessResult _result(
    FolderAccessStatus status,
    String root,
    String message,
  ) => FolderAccessResult._(status, root, executable, message);

  FolderAccessResult _decode(
    ProcessResult process,
    String root, {
    bool request = false,
  }) {
    final json = jsonDecode(process.stdout as String);
    if (json is! Map<String, dynamic> ||
        (process.exitCode != 0 &&
            !(process.exitCode == 1 && json['status'] == 'failed')) ||
        json['executable'] != executable ||
        json['message'] is! String ||
        !(request
                ? ['allowed', 'cancelled', 'unconfirmed', 'failed']
                : ['confirmed', 'unconfirmed', 'failed'])
            .contains(json['status'])) {
      throw const FormatException('Invalid helper response');
    }
    return FolderAccessResult._(
      FolderAccessStatus.values.byName(json['status'] as String),
      root,
      executable,
      json['message'] as String,
      canRequest: !request && !_requestAttempted && json['canRequest'] == true,
    );
  }

  Future<FolderAccessResult> inspect(String root) async {
    final generation = ++_inspectionGeneration;
    _confirmation = null;
    if (!isWindows ||
        !_absolute(root) ||
        !_absolute(executable) ||
        executable.split(RegExp(r'[/\\]')).last.toLowerCase() !=
            'silique.exe') {
      return _result(
        FolderAccessStatus.failed,
        root,
        tr(
          'Inspekcja Windows jest niedostępna dla tej instalacji lub lokalizacji.',
          'Windows inspection is unavailable for this installation or location.',
        ),
      );
    }
    try {
      final process = await _runProcess(_helper, [
        '--inspect',
        root,
      ]).timeout(inspectionTimeout);
      if (generation != _inspectionGeneration) {
        return _result(
          FolderAccessStatus.unconfirmed,
          root,
          tr(
            'Wynik inspekcji jest nieaktualny.',
            'The inspection result is out of date.',
          ),
        );
      }
      final result = _decode(process, root);
      if (result.status == FolderAccessStatus.confirmed && result.canRequest) {
        _confirmation = result;
      }
      return result;
    } catch (_) {
      // Never display raw stdout/stderr or exception text: it can contain secrets.
      return _result(
        FolderAccessStatus.failed,
        root,
        tr(
          'Nie można zweryfikować ochrony Windows. Pomocnik jest niedostępny lub zwrócił nieprawidłową odpowiedź.',
          'Could not verify Windows protection. The helper is unavailable or returned an invalid response.',
        ),
      );
    }
  }

  static bool _absolute(String path) =>
      !path.contains('\u0000') &&
      RegExp(r'^(?:[a-zA-Z]:[/\\]|[/\\]{2}[^/\\]+[/\\][^/\\]+(?:[/\\]|$))')
          .hasMatch(path);

  /// A one-shot capability from inspect, bound to the exact root and service.
  /// The helper independently rechecks evidence before requesting elevation.
  Future<FolderAccessResult> requestAllow(
    FolderAccessResult inspection,
    String root,
  ) async {
    if (_requestAttempted ||
        !identical(_confirmation, inspection) ||
        inspection.status != FolderAccessStatus.confirmed ||
        !inspection.canRequest ||
        inspection.root != root) {
      return _result(
        FolderAccessStatus.failed,
        root,
        tr(
          'Brak potwierdzenia dla tego folderu. Nie wywołano UAC.',
          'There is no confirmation for this folder. UAC was not invoked.',
        ),
      );
    }
    _requestAttempted = true;
    _confirmation = null;
    try {
      // Future.timeout does not kill the process. An elevated operation may
      // still finish; consume the capability first and never repeat it.
      return _decode(
        await _runProcess(_helper, ['--request', root]).timeout(requestTimeout),
        root,
        request: true,
      );
    } on TimeoutException {
      return _result(
        FolderAccessStatus.unconfirmed,
        root,
        tr(
          'Nie potwierdzono wyniku. Operacja Windows może nadal trwać. Nie ponawiaj żądania; sprawdź zgodę ręcznie i uruchom Silique ponownie.',
          'The result was not confirmed. The Windows operation may still be running. Do not repeat the request; check permission manually and restart Silique.',
        ),
      );
    } catch (_) {
      return _result(
        FolderAccessStatus.unconfirmed,
        root,
        tr(
          'Nie udało się potwierdzić wyniku zgody Windows. Nie ponawiaj żądania; sprawdź ustawienia ręcznie.',
          'Could not confirm the Windows permission result. Do not repeat the request; check the settings manually.',
        ),
      );
    }
  }
}
