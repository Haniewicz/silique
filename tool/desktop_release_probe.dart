// Standalone AOT probe: needs no VM service and never opens real user storage.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livemd_flutter/livemd_flutter.dart';
import 'package:silique/core/contracts.dart';
import 'package:silique/main.dart';
import 'package:silique/services/app_updates.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_crypto.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/storage/vault_import.dart';
import 'package:silique/storage/native_window.dart';
import 'package:silique/storage/secure_keys.dart';
import 'package:window_manager/window_manager.dart';

class _ProbeKeys implements KeyStore {
  final prefix = 'silique-probe-${DateTime.now().microsecondsSinceEpoch}';
  final store = const SecureKeys();
  final written = <String>{};
  @override
  Future<String?> read(String key) => store.read('$prefix.$key');
  @override
  Future<void> write(String key, String value) async {
    written.add(key);
    await store.write('$prefix.$key', value);
  }

  @override
  Future<void> delete(String key) => store.delete('$prefix.$key');
  Future<void> clear() async {
    for (final key in written) {
      await delete(key);
    }
  }
}

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> waitFor(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Probe timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

TextField? titleField() {
  TextField? result;
  void visit(Element element) {
    if (element.widget case final TextField field
        when field.key == const Key('note-title')) {
      result = field;
    }
    element.visitChildren(visit);
  }

  final root = WidgetsBinding.instance.rootElement;
  if (root != null) visit(root);
  return result;
}

Future<void> main() async {
  const output = String.fromEnvironment('SILIQUE_PROBE_RESULT');
  if (!const bool.fromEnvironment('SILIQUE_ISOLATED_TEST') ||
      output.isEmpty ||
      !(Platform.isWindows || Platform.isLinux)) {
    stderr.writeln(
      'This probe requires an isolated desktop and a result path.',
    );
    exit(2);
  }
  WidgetsFlutterBinding.ensureInitialized();
  final errors = <String>[];
  FlutterError.onError = (details) => errors.add(details.toString());
  runApp(
    const MaterialApp(home: Scaffold(body: Text('Silique desktop probe'))),
  );
  final keys = _ProbeKeys();
  final root = await Directory.systemTemp.createTemp('silique-release-probe-');
  Notebook? repo;
  var closed = false;
  Notebook? reopened;
  final checks = <String>[];
  try {
    await WidgetsBinding.instance.endOfFrame;
    await NativeWindow.initialize();
    check(await windowManager.isVisible(), 'Window did not become visible');
    checks.add('native-window');
    if (Platform.isLinux) {
      await windowManager.setSize(const Size(1180, 800));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (Platform.isLinux) {
      check(
        await windowManager.getTitleBarHeight() > 0,
        'Missing native GTK titlebar',
      );
      checks.add('native-window-controls');
    }
    final updater = AppUpdater();
    await updater.initialize();
    check(
      updater.installed?.version ==
          const String.fromEnvironment('FLUTTER_BUILD_NAME'),
      'Missing desktop version',
    );
    check(
      updater.installed?.build ==
          const int.fromEnvironment('FLUTTER_BUILD_NUMBER'),
      'Missing desktop build',
    );
    updater.dispose();
    checks.add('installed-version');
    repo = Notebook(
      storage: NativeStorage(root.path),
      keys: keys,
      crypto: NativeCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Desktop probe');
    final vault = repo.vaults.single;
    await repo.createFolder(vault, 'Parent/Child');
    final note = await repo.createNote(vault.id, folder: 'Parent/Child');
    await repo.save(
      note.copyWith(title: 'Desktop test note', body: 'Persisted desktop body'),
    );
    runApp(
      ProviderScope(
        overrides: [notebookProvider.overrideWithValue(repo)],
        child: const SiliqueApp(),
      ),
    );
    await waitFor(
      () => titleField() != null && NativeWindow.instance.beforeClose != null,
    );
    final field = titleField()!;
    field.controller!.text = 'Desktop edited and saved';
    field.onChanged?.call('Desktop edited and saved');
    await NativeWindow.instance.beforeClose!();
    check(
      repo.storage
          .documents(vault.id)[note.id]!
          .contains('Desktop edited and saved'),
      'Editor did not persist its title',
    );
    check(
      await keys.read('nova.localKey') != null,
      'Native key store read failed',
    );
    checks.addAll(['native-secret-store', 'editor-save']);
    if (const bool.fromEnvironment('SILIQUE_PROBE_GUI')) {
      EditableText? editable;
      void findEditable(Element element) {
        if (element.widget case final EditableText widget
            when widget.controller == field.controller) {
          editable = widget;
        }
        element.visitChildren(findEditable);
      }

      WidgetsBinding.instance.rootElement!.visitChildren(findEditable);
      check(editable != null, 'Missing native input target');
      editable!.focusNode.unfocus();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final titleBox = field.key == const Key('note-title')
          ? (() {
              RenderBox? box;
              void find(Element e) {
                if (e.widget.key == const Key('note-title')) {
                  box = e.findRenderObject() as RenderBox?;
                }
                e.visitChildren(find);
              }

              WidgetsBinding.instance.rootElement!.visitChildren(find);
              return box;
            })()
          : null;
      check(titleBox != null, 'Missing pointer target');
      final titlePoint = titleBox!.localToGlobal(
        titleBox.size.center(Offset.zero),
      );
      await File('$output.phase').writeAsString(
        jsonEncode({
          'phase': 'click-title',
          'x': titlePoint.dx,
          'y': titlePoint.dy + await windowManager.getTitleBarHeight(),
        }),
        flush: true,
      );
      await waitFor(() => editable!.focusNode.hasFocus);
      checks.add('native-pointer-after-resize');
      await File('$output.phase')
          .writeAsString(jsonEncode({'phase': 'keyboard'}), flush: true);
      await waitFor(() => field.controller!.text == 'GTK4 keyboard test');
      await NativeWindow.instance.beforeClose!();
      check(
        repo.storage
            .documents(vault.id)[note.id]!
            .contains('GTK4 keyboard test'),
        'Native keyboard edit did not persist',
      );
      checks.add('native-keyboard');
      await File('$output.phase').writeAsString(
        jsonEncode({'phase': 'choose-folder', 'path': root.path}),
        flush: true,
      );
      final selected = await getDirectoryPath(
        initialDirectory: root.path,
        confirmButtonText: '_Select probe folder',
      );
      check(
        selected == root.path,
        'GTK4 file chooser returned a different directory',
      );
      await File('$output.phase')
          .writeAsString(jsonEncode({'phase': 'cancel-folder'}), flush: true);
      check(
        await getDirectoryPath(initialDirectory: root.path) == null,
        'Cancelled GTK4 chooser returned a directory',
      );
      checks.add('native-folder-chooser');
      Element? editor;
      void findEditor(Element element) {
        if (element.widget is LiveMarkdownEditor) editor = element;
        element.visitChildren(findEditor);
      }

      WidgetsBinding.instance.rootElement!.visitChildren(findEditor);
      check(editor != null, 'Missing drop target editor');
      final render = editor!.findRenderObject()! as RenderBox;
      final point = render.localToGlobal(render.size.center(Offset.zero));
      final png = File('${root.path}/drop-probe.png');
      await png.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
        ),
      );
      await File('$output.phase').writeAsString(
        jsonEncode({
          'phase': 'drop-image',
          'path': png.path,
          'x': point.dx,
          'y':
              point.dy +
              (Platform.isLinux ? await windowManager.getTitleBarHeight() : 0),
          'scale': WidgetsBinding
              .instance
              .platformDispatcher
              .views
              .first
              .devicePixelRatio,
        }),
        flush: true,
      );
      await waitFor(() => repo!.notes[vault.id]![note.id]!.body.contains('!['));
      await NativeWindow.instance.beforeClose!();
      checks.add('native-file-drop');
      field.controller!.text = 'Desktop edited and saved';
      await NativeWindow.instance.beforeClose!();
    }
    final flush = NativeWindow.instance.beforeClose;
    var closeAttempt = false;
    NativeWindow.instance.beforeClose = () async {
      closeAttempt = true;
      throw StateError('Expected probe save failure');
    };
    await windowManager.close();
    await waitFor(() => closeAttempt);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    check(await windowManager.isVisible(), 'Save failure closed the window');
    NativeWindow.instance.beforeClose = flush;
    checks.add('failed-save-keeps-window');
    final importedSource = Directory('${root.path}/foreign-vault');
    await Directory('${importedSource.path}/Child/Empty')
        .create(recursive: true);
    await File('${importedSource.path}/Start.md')
        .writeAsString('[Other](Child/Original.md)');
    await File('${importedSource.path}/Child/Original.md')
        .writeAsString('IMPORTED_BODY');
    final plan = await scanVaultImport(
      DirectoryImportSource(importedSource.path),
    );
    final imported = await repo.importVault(
      vault.id,
      plan,
      destination: 'Imported',
    );
    check(
      imported.notes.length == 2 &&
          repo.allFolders(vault.id).contains('Imported/Child/Empty'),
      'Vault import lost hierarchy',
    );
    checks.add('folder-vault-import');
    await repo.createVault(
      'Protected desktop',
      password: 'isolated-desktop-passphrase-123',
    );
    final protected = repo.vaults.last;
    await repo.rememberVault(protected.id);
    await repo.importVault(protected.id, plan, destination: 'Private import');
    final secret = await repo.createNote(protected.id);
    await repo.save(
      secret.copyWith(title: 'Protected', body: 'ENCRYPTED_DESKTOP_BODY'),
    );
    check(
      !repo.storage
          .documents(protected.id)[secret.id]!
          .contains('ENCRYPTED_DESKTOP_BODY'),
      'Protected body stored as plaintext',
    );
    runApp(const SizedBox());
    await WidgetsBinding.instance.endOfFrame;
    await repo.close();
    closed = true;
    reopened = Notebook(
      storage: NativeStorage(root.path),
      keys: keys,
      crypto: NativeCrypto(),
    );
    await reopened.initialize();
    check(reopened.lastVaultId == protected.id, 'Last vault was not restored');
    checks.add('remembered-vault');
    check(
      reopened.allFolders(vault.id).contains('Imported/Child/Empty'),
      'Imported tree lost after restart',
    );
    check(
      reopened.notes[vault.id]![note.id]!.title == 'Desktop edited and saved',
      'SQLite reopen lost edited title',
    );
    check(
      reopened.notes[vault.id]![note.id]!.folder == 'Parent/Child',
      'SQLite reopen lost folder',
    );
    check(
      !reopened.unlocked.containsKey(protected.id),
      'Protected vault reopened unlocked',
    );
    await reopened.unlock(
      reopened.vaults.firstWhere((v) => v.id == protected.id),
      password: 'isolated-desktop-passphrase-123',
    );
    check(
      reopened.notes[protected.id]![secret.id]!.body ==
          'ENCRYPTED_DESKTOP_BODY',
      'Protected vault failed decryption',
    );
    checks.addAll(['sqlite-reopen', 'protected-vault-reopen']);
  } catch (error, stack) {
    errors.add('$error\n$stack');
  } finally {
    try {
      runApp(const SizedBox());
      await WidgetsBinding.instance.endOfFrame;
      await reopened?.close();
      if (!closed) await repo?.close();
      await keys.clear();
      await root.delete(recursive: true);
    } catch (error) {
      errors.add('Cleanup failed: $error');
    }
    final result = File('$output.tmp');
    await result.writeAsString(
      jsonEncode({
        'passed': errors.isEmpty,
        'checks': checks,
        'errors': errors,
      }),
      flush: true,
    );
    await result.rename(output);
    exit(errors.isEmpty ? 0 : 1);
  }
}
