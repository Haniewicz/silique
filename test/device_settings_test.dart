import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/device_settings.dart';
import 'package:silique/core/shortcut_bindings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('silique-device-settings-');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  Future<DeviceSettingsController> fresh() async {
    final controller = DeviceSettingsController();
    await controller.initialize(dir);
    return controller;
  }

  test('defaults are populated with platform primary modifier', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final c = await fresh();
      expect(c.bindingOf(ShortcutAction.newNote).format(), 'ctrl+n');
      expect(c.bindingOf(ShortcutAction.toggleFocus).format(), 'f11');
      expect(c.bindingOf(ShortcutAction.nextTab).format(), 'ctrl+tab');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('writes and reads a shortcut back from disk', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      var c = await fresh();
      await c.setBinding(
        ShortcutAction.save,
        ShortcutBinding(
          modifiers: {ShortcutModifier.ctrl, ShortcutModifier.shift},
          key: 's',
        ),
      );
      final file = File('${dir.path}/device-settings.json');
      expect(file.existsSync(), isTrue);
      final decoded =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(decoded['version'], 1);
      expect(
        (decoded['shortcuts'] as Map<String, dynamic>)['save'],
        'ctrl+shift+s',
      );

      // A fresh controller over the same directory reads it back.
      final c2 = await fresh();
      expect(c2.bindingOf(ShortcutAction.save).format(), 'ctrl+shift+s');
      // Untouched actions retain defaults.
      expect(c2.bindingOf(ShortcutAction.newNote).format(), 'ctrl+n');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('reset restores every default', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final c = await fresh();
      await c.setBinding(
        ShortcutAction.save,
        ShortcutBinding(
          modifiers: {ShortcutModifier.ctrl, ShortcutModifier.shift},
          key: 's',
        ),
      );
      await c.resetToDefaults();
      expect(c.bindingOf(ShortcutAction.save).format(), 'ctrl+s');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('corrupt JSON falls back to defaults without throwing', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final file = File('${dir.path}/device-settings.json');
      file.writeAsStringSync('{ not valid json');
      final c = await fresh();
      expect(c.bindingOf(ShortcutAction.newNote).format(), 'ctrl+n');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('a malformed entry is skipped while others load', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final file = File('${dir.path}/device-settings.json');
      file.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'shortcuts': {
            'save': 'ctrl+notakey', // invalid -> skipped
            'newNote': 'ctrl+shift+n',
          },
        }),
      );
      final c = await fresh();
      expect(c.bindingOf(ShortcutAction.newNote).format(), 'ctrl+shift+n');
      expect(c.bindingOf(ShortcutAction.save).format(), 'ctrl+s');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('a conflicting binding is rejected with ArgumentError', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final c = await fresh();
      // newNote is already ctrl+n.
      await expectLater(
        c.setBinding(
          ShortcutAction.save,
          ShortcutBinding(modifiers: {ShortcutModifier.ctrl}, key: 'n'),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('newNote'),
          ),
        ),
      );
      // The store is unchanged.
      expect(c.bindingOf(ShortcutAction.save).format(), 'ctrl+s');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('journalTemplateId is read back from the file', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final file = File('${dir.path}/device-settings.json');
      file.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'shortcuts': <String, String>{},
          'journalTemplateId': 'tpl-42',
        }),
      );
      final c = await fresh();
      expect(c.journalTemplateId, 'tpl-42');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test(
    'noteTemplateId defaults to null and persists through the setter',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        var c = await fresh();
        expect(c.noteTemplateId, isNull);

        await c.setNoteTemplateId('tpl-note-1');
        final file = File('${dir.path}/device-settings.json');
        final decoded =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        expect(decoded['noteTemplateId'], 'tpl-note-1');

        // A fresh controller over the same directory reads it back.
        c = await fresh();
        expect(c.noteTemplateId, 'tpl-note-1');

        await c.setNoteTemplateId(null);
        final cleared =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        expect(cleared.containsKey('noteTemplateId'), isFalse);
        final c2 = await fresh();
        expect(c2.noteTemplateId, isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  test('noteTemplateId is read back from the file', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final file = File('${dir.path}/device-settings.json');
      file.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'shortcuts': <String, String>{},
          'noteTemplateId': 'tpl-note-7',
        }),
      );
      final c = await fresh();
      expect(c.noteTemplateId, 'tpl-note-7');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('hideTemplatesFolder defaults to false and persists', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      var c = await fresh();
      expect(c.hideTemplatesFolder, isFalse);

      await c.setHideTemplatesFolder(true);
      final file = File('${dir.path}/device-settings.json');
      final decoded =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(decoded['hideTemplatesFolder'], true);

      c = await fresh();
      expect(c.hideTemplatesFolder, isTrue);

      await c.setHideTemplatesFolder(false);
      final cleared =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(cleared.containsKey('hideTemplatesFolder'), isFalse);
      final c2 = await fresh();
      expect(c2.hideTemplatesFolder, isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('missing new keys fall back to defaults without throwing', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final file = File('${dir.path}/device-settings.json');
      file.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'shortcuts': <String, String>{},
          'journalTemplateId': 'tpl-42',
        }),
      );
      final c = await fresh();
      expect(c.journalTemplateId, 'tpl-42');
      expect(c.noteTemplateId, isNull);
      expect(c.hideTemplatesFolder, isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
