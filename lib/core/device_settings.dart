import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'shortcut_bindings.dart';
import '../l10n/strings.dart' show tr;

/// On-disk schema version for `device-settings.json`.
const int deviceSettingsVersion = 1;

/// A [ChangeNotifier] holding per-device preferences that are independent of
/// any vault, account or credential: the editable shortcut map and (later) the
/// default journal template.
///
/// Persisted as JSON at `<support>/device-settings.json`, written atomically
/// (temporary file + rename) exactly like [AppLanguageController].
class DeviceSettingsController extends ChangeNotifier {
  DeviceSettingsController();

  /// `actionId -> serialized chord`, e.g. `{"newNote": "ctrl+n"}`.
  final Map<String, String> _shortcuts = {};
  String? _journalTemplateId;
  String? _noteTemplateId;
  bool _hideTemplatesFolder = false;
  File? _file;
  bool _initialized = false;

  /// The current journal template id, reserved for the templates window.
  String? get journalTemplateId => _journalTemplateId;

  /// The current default template id for ordinary notes, or `null` when no
  /// template is configured (`null` = "Brak"/"None").
  String? get noteTemplateId => _noteTemplateId;

  /// Whether the built-in `Szablony` folder is hidden from the folder tree.
  /// The folder cannot be deleted, only hidden; default is `false` (visible).
  bool get hideTemplatesFolder => _hideTemplatesFolder;

  /// Sets the default journal template to the id of a template note in the
  /// active vault, or clears it with `null`. Persisted immediately so the
  /// choice survives restarts exactly like a shortcut binding.
  Future<void> setJournalTemplateId(String? id) async {
    if (_journalTemplateId == id) return;
    _journalTemplateId = id;
    notifyListeners();
    await _persist();
  }

  /// Sets the default template for ordinary notes to the id of a template note
  /// in the active vault, or clears it with `null` ("Brak"/"None"). Persisted
  /// immediately exactly like [setJournalTemplateId].
  Future<void> setNoteTemplateId(String? id) async {
    if (_noteTemplateId == id) return;
    _noteTemplateId = id;
    notifyListeners();
    await _persist();
  }

  /// Shows or hides the built-in `Szablony` folder in the folder tree.
  /// Persisted immediately exactly like [setJournalTemplateId].
  Future<void> setHideTemplatesFolder(bool value) async {
    if (_hideTemplatesFolder == value) return;
    _hideTemplatesFolder = value;
    notifyListeners();
    await _persist();
  }

  Map<String, String> get shortcuts => Map.unmodifiable(_shortcuts);

  static bool get _isMac => defaultTargetPlatform == TargetPlatform.macOS;

  /// Loads the file if present; a missing or corrupt file falls back to
  /// defaults and never blocks startup.
  Future<void> initialize(Directory support) async {
    final file = File('${support.path}/device-settings.json');
    _file = file;
    try {
      // A crash between writing the temporary file and renaming it leaves an
      // orphan `.pending` behind; it never holds a newer state than the
      // committed file, so a best-effort removal keeps the directory clean.
      final orphan = File('${file.path}.pending');
      try {
        if (await orphan.exists()) await orphan.delete();
      } on FileSystemException {
        // Keep starting even when the orphan cannot be removed.
      }
      if (await file.exists()) {
        final raw = await file.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic> &&
            decoded['version'] == deviceSettingsVersion) {
          final shortcuts = decoded['shortcuts'];
          if (shortcuts is Map<String, dynamic>) {
            for (final entry in shortcuts.entries) {
              final action = ShortcutAction.byId(entry.key);
              if (action == null || entry.value is! String) continue;
              try {
                final binding = parseShortcut(
                  entry.value as String,
                  isMac: _isMac,
                );
                _shortcuts[action.id] = binding.format();
              } on FormatException {
                // Skip one malformed entry; the rest still load.
              }
            }
          }
          if (decoded['journalTemplateId'] is String) {
            _journalTemplateId = decoded['journalTemplateId'] as String;
          }
          if (decoded['noteTemplateId'] is String) {
            _noteTemplateId = decoded['noteTemplateId'] as String;
          }
          if (decoded['hideTemplatesFolder'] is bool) {
            _hideTemplatesFolder = decoded['hideTemplatesFolder'] as bool;
          }
        }
      }
    } catch (_) {
      // Corrupt JSON or an unreadable file: keep defaults, no crash.
    }
    // Any action missing from the file keeps its platform default.
    for (final action in ShortcutAction.all) {
      _shortcuts.putIfAbsent(
        action.id,
        () => defaultBinding(action, _isMac).format(),
      );
    }
    _initialized = true;
    notifyListeners();
  }

  bool get initialized => _initialized;

  /// The resolved binding for [action], defaulting when none is stored.
  ShortcutBinding bindingOf(ShortcutAction action) {
    final stored = _shortcuts[action.id];
    if (stored != null) {
      try {
        return parseShortcut(stored, isMac: _isMac);
      } on FormatException {
        // Fall through to the default.
      }
    }
    return defaultBinding(action, _isMac);
  }

  /// Serialized chord for [action] (used for conflict checks and display).
  String bindingString(ShortcutAction action) =>
      _shortcuts[action.id] ?? defaultBinding(action, _isMac).format();

  /// The action whose current binding collides with [binding], or null.
  ShortcutAction? conflictFor(ShortcutAction action, ShortcutBinding binding) {
    final conflictId = findConflict(
      action,
      binding,
      _shortcuts,
      isMac: _isMac,
      exclude: action,
    );
    return conflictId == null ? null : ShortcutAction.byId(conflictId);
  }

  /// Validates and stores [binding] for [action].
  ///
  /// Rejects with [FormatException] for an invalid chord and [ArgumentError]
  /// when it conflicts with another action's binding.
  Future<void> setBinding(
    ShortcutAction action,
    ShortcutBinding binding,
  ) async {
    final conflict = findConflict(
      action,
      binding,
      _shortcuts,
      isMac: _isMac,
      exclude: action,
    );
    if (conflict != null) {
      // The message carries the conflicting action id so the settings tab can
      // render a localized "already used by" hint without stringly decoding.
      throw ArgumentError.value(binding.format(), 'binding', conflict);
    }
    _shortcuts[action.id] = binding.format();
    notifyListeners();
    await _persist();
  }

  /// Restores every action to its platform default.
  Future<void> resetToDefaults() {
    _shortcuts.clear();
    for (final action in ShortcutAction.all) {
      _shortcuts[action.id] = defaultBinding(action, _isMac).format();
    }
    notifyListeners();
    return _persist();
  }

  Future<void> _persist() {
    final file = _file;
    if (file == null) return Future<void>.value();
    final payload = <String, dynamic>{
      'version': deviceSettingsVersion,
      'shortcuts': Map<String, String>.from(_shortcuts),
      if (_journalTemplateId != null) 'journalTemplateId': _journalTemplateId,
      if (_noteTemplateId != null) 'noteTemplateId': _noteTemplateId,
      if (_hideTemplatesFolder) 'hideTemplatesFolder': true,
    };
    // Atomic write: temporary file + rename, mirroring AppLanguageController.
    return Future<void>.sync(() async {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.pending');
      await temporary.writeAsString(jsonEncode(payload), flush: true);
      await temporary.rename(file.path);
    });
  }
}

/// The process-wide instance, initialized from `main.dart` next to
/// `appLanguage`.
final deviceSettings = DeviceSettingsController();

/// A [ListenableBuilder] over [deviceSettings] so UI can rebuild when a
/// shortcut changes.
class DeviceSettingsBuilder extends StatelessWidget {
  const DeviceSettingsBuilder({super.key, required this.builder});
  final WidgetBuilder builder;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: deviceSettings,
    builder: (context, _) => builder(context),
  );
}

/// Localized label for [action] (used by the settings list and conflict
/// messages).
String shortcutActionLabel(ShortcutAction action) {
  switch (action) {
    case ShortcutAction.newNote:
      return tr('Nowa notatka', 'New note');
    case ShortcutAction.quickSwitcher:
      return tr('Szybkie przełączanie', 'Quick switcher');
    case ShortcutAction.findInNote:
      return tr('Szukaj w notatce', 'Find in note');
    case ShortcutAction.save:
      return tr('Zapisz', 'Save');
    case ShortcutAction.nextTab:
      return tr('Następna karta', 'Next tab');
    case ShortcutAction.closeTab:
      return tr('Zamknij kartę', 'Close tab');
    case ShortcutAction.reopenClosedTab:
      return tr('Otwórz zamkniętą kartę', 'Reopen closed tab');
    case ShortcutAction.toggleSource:
      return tr('Markdown / podgląd', 'Toggle source');
    case ShortcutAction.toggleFocus:
      return tr('Pełny ekran', 'Focus mode');
  }
}
