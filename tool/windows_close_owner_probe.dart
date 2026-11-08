// Disposable Windows runner entry point. No production storage/keyring/network.
// Pair with tool/windows_close_owner_probe.ps1 to measure actual process exit.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livemd_flutter/livemd_flutter.dart';
import 'package:silique/core/contracts.dart';
import 'package:silique/main.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_crypto.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/storage/native_window.dart';
import 'package:window_manager/window_manager.dart';

class _Keys implements KeyStore {
  _Keys(this.values);
  final Map<String, String> values;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

Future<void> main(List<String> arguments) async {
  final path = Platform.environment['SILIQUE_CLOSE_PROBE_ROOT'];
  if (!Platform.isWindows ||
      !const bool.fromEnvironment('SILIQUE_ISOLATED_TEST') ||
      path == null ||
      !File('$path/isolated-probe-marker').existsSync()) {
    throw StateError('Use the disposable Windows close probe harness.');
  }
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Scaffold(body: Text('Isolated close probe'))));
  await WidgetsBinding.instance.endOfFrame;
  await NativeWindow.initialize();
  final verifying = arguments.contains('--verify');
  final keys = _Keys(
    verifying
        ? Map<String, String>.from(
            jsonDecode(File('$path/keys.json').readAsStringSync()) as Map,
          )
        : <String, String>{},
  );
  final storage = NativeStorage('$path/notebook');
  final repo = Notebook(storage: storage, keys: keys, crypto: NativeCrypto());
  await repo.initialize();
  if (verifying) {
    final note = repo.notes.values.single.values.single;
    if (note.title != 'Final edit before native close' ||
        note.body != 'Final body edit before native close') {
      throw StateError('Native close lost the last edit');
    }
    await repo.close();
    await File('$path/verified')
        .writeAsString('last-title-and-body-reopened', flush: true);
    await windowManager.destroy();
    return;
  }
  await repo.createVault('Disposable native close');
  final note = await repo.createNote(repo.vaults.single.id);
  await repo.save(
    note.copyWith(title: 'Initial title', body: 'Synthetic durable body'),
  );
  await File('$path/keys.json')
      .writeAsString(jsonEncode(keys.values), flush: true);
  runApp(
    ProviderScope(
      overrides: [notebookProvider.overrideWithValue(repo)],
      child: const SiliqueApp(),
    ),
  );
  TextField? title;
  LiveMarkdownEditor? editor;
  void visit(Element element) {
    final widget = element.widget;
    if (widget is TextField && widget.key == const Key('note-title')) {
      title = widget;
    }
    if (widget is LiveMarkdownEditor) editor = widget;
    element.visitChildren(visit);
  }

  while (title == null ||
      editor == null ||
      NativeWindow.instance.beforeClose == null) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    WidgetsBinding.instance.rootElement?.visitChildren(visit);
  }
  final homeClose = NativeWindow.instance.beforeClose!;
  final timingOnly =
      Platform.environment['SILIQUE_CLOSE_TIMING_ONLY'] == 'true';
  var attempts = 0;
  NativeWindow.instance.beforeClose = () async {
    attempts++;
    await File('$path/attempts').writeAsString('$attempts', flush: true);
    if (!timingOnly && attempts == 1) {
      storage.db.execute('PRAGMA query_only=ON');
      try {
        title!.controller!.text = 'Unsaved first attempt';
        editor!.controller.text = 'Unsaved first body';
        try {
          await homeClose();
        } catch (_) {
          await File('$path/failed-save')
              .writeAsString('real-sqlite-write-refusal', flush: true);
          rethrow;
        }
        throw StateError(
          'Read-only SQLite unexpectedly accepted the close save',
        );
      } finally {
        storage.db.execute('PRAGMA query_only=OFF');
      }
    }
    await File('$path/save-waiting')
        .writeAsString('waiting-for-test-barrier', flush: true);
    while (!File('$path/release-save').existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    title!.controller!.text = 'Final edit before native close';
    editor!.controller.text = 'Final body edit before native close';
    await homeClose();
    if (!storage
            .documents(note.vaultId)[note.id]!
            .contains('Final edit before native close') ||
        !storage
            .documents(note.vaultId)[note.id]!
            .contains('Final body edit before native close')) {
      throw StateError('Last edit not committed before native destroy');
    }
    await File('$path/save-durable').writeAsString('committed', flush: true);
  };
  await File('$path/ready').writeAsString('$pid', flush: true);
}
