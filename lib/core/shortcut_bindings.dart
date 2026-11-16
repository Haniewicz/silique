import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Device-local shortcut actions, keyed by a stable id that survives
/// serialization. Add new actions here; the settings tab renders them in this
/// order and [ShortcutAction.all] is the canonical, exhaustive list.
enum ShortcutAction {
  newNote('newNote'),
  quickSwitcher('quickSwitcher'),
  findInNote('findInNote'),
  save('save'),
  nextTab('nextTab'),
  closeTab('closeTab'),
  reopenClosedTab('reopenClosedTab'),
  toggleSource('toggleSource'),
  toggleFocus('toggleFocus');

  const ShortcutAction(this.id);

  /// Stable id used in the JSON payload; never reorder or rename these.
  final String id;

  static const List<ShortcutAction> all = [
    newNote,
    quickSwitcher,
    findInNote,
    save,
    nextTab,
    closeTab,
    reopenClosedTab,
    toggleSource,
    toggleFocus,
  ];

  static ShortcutAction? byId(String id) {
    for (final action in all) {
      if (action.id == id) return action;
    }
    return null;
  }
}

/// A modifier mask. `meta` is Cmd on macOS and the Super/Windows key elsewhere;
/// see [ShortcutBinding.primaryModifier].
enum ShortcutModifier { ctrl, meta, alt, shift }

/// One key chord: a set of modifiers plus a single, platform-neutral key name.
@immutable
class ShortcutBinding {
  /// Builds and validates a chord in one step. Throws [FormatException] when
  /// the key name is unknown or the modifier/key combination is not a valid
  /// shortcut (see [normalize]).
  factory ShortcutBinding({
    required Set<ShortcutModifier> modifiers,
    required String key,
  }) {
    final binding = normalize(modifiers, key);
    if (binding == null) {
      final details = key.trim().toLowerCase();
      if (keyFor(details) == null) {
        throw FormatException('Nieznany klawisz "$key"', key);
      }
      throw FormatException(
        'Skrót "$key" wymaga modyfikatora innego niż sam Shift',
        key,
      );
    }
    return binding;
  }

  const ShortcutBinding._({required this.modifiers, required this.key});

  final Set<ShortcutModifier> modifiers;
  final String key;

  /// The platform-primary modifier: Cmd on macOS, Ctrl everywhere else.
  static ShortcutModifier primaryModifier(bool isMac) =>
      isMac ? ShortcutModifier.meta : ShortcutModifier.ctrl;

  bool get hasCtrl => modifiers.contains(ShortcutModifier.ctrl);
  bool get hasMeta => modifiers.contains(ShortcutModifier.meta);
  bool get hasAlt => modifiers.contains(ShortcutModifier.alt);
  bool get hasShift => modifiers.contains(ShortcutModifier.shift);

  bool get isEmpty => modifiers.isEmpty && key.isEmpty;

  /// Serializes to `"ctrl+shift+t"`, `"meta+k"`, `"f11"`. Modifiers come first,
  /// in a canonical order (ctrl, meta, alt, shift), lowercase.
  String format() {
    final parts = <String>[
      if (hasCtrl) 'ctrl',
      if (hasMeta) 'meta',
      if (hasAlt) 'alt',
      if (hasShift) 'shift',
      key,
    ];
    return parts.join('+');
  }

  /// The same chord expressed as a text label, e.g. "Ctrl+Shift+T".
  String label() {
    final parts = <String>[
      if (hasCtrl) 'Ctrl',
      if (hasMeta) 'Cmd',
      if (hasAlt) 'Alt',
      if (hasShift) 'Shift',
      _displayKey(),
    ];
    return parts.join('+');
  }

  String _displayKey() {
    if (key.length == 1) return key.toUpperCase();
    if (key == 'escape') return 'Esc';
    // "f1".."f12", "tab", "enter", "home"… -> "F1", "Tab", "Enter"…
    if (key.startsWith('f') && key.length <= 3) return key.toUpperCase();
    return key.substring(0, 1).toUpperCase() + key.substring(1);
  }

  bool _sameModifiers(ShortcutBinding other) =>
      hasCtrl == other.hasCtrl &&
      hasMeta == other.hasMeta &&
      hasAlt == other.hasAlt &&
      hasShift == other.hasShift;

  @override
  bool operator ==(Object other) =>
      other is ShortcutBinding && other.key == key && _sameModifiers(other);

  @override
  int get hashCode => Object.hash(hasCtrl, hasMeta, hasAlt, hasShift, key);

  @override
  String toString() => format();
}

/// Parses a serialized chord like `"ctrl+shift+t"`, `"meta+k"` or `"f11"` into
/// a [ShortcutBinding], either with the default per-platform [primaryModifier]
/// (when [isMac] is omitted it defaults to the real platform via
/// `kIsWeb`-safe `defaultTargetPlatform`) or with the platform spelled out.
///
/// Throws [FormatException] on an unknown modifier, key name or an empty chord.
ShortcutBinding parseShortcut(String source, {bool? isMac}) {
  final mac = isMac ?? defaultTargetPlatform == TargetPlatform.macOS;
  final normalized = source.trim().toLowerCase();
  if (normalized.isEmpty) {
    throw const FormatException('Empty shortcut binding');
  }
  final parts = normalized.split('+').map((p) => p.trim()).toList();
  final modifiers = <ShortcutModifier>{};
  var keyName = '';
  for (final part in parts) {
    switch (part) {
      case 'ctrl':
      case 'control':
        modifiers.add(ShortcutModifier.ctrl);
      case 'cmd':
      case 'meta':
      case 'super':
      case 'command':
        modifiers.add(ShortcutModifier.meta);
      case 'alt':
      case 'option':
        modifiers.add(ShortcutModifier.alt);
      case 'shift':
        modifiers.add(ShortcutModifier.shift);
      default:
        if (keyName.isNotEmpty) {
          throw FormatException('Multiple keys in "$source"');
        }
        keyName = part;
    }
  }
  if (keyName.isEmpty) {
    throw FormatException('No key in "$source"');
  }
  // Normalize the primary modifier: "ctrl" means the platform primary key on
  // macOS, so an older payload stored as "ctrl" is read back as meta there.
  if (mac) {
    if (modifiers.contains(ShortcutModifier.ctrl) &&
        !modifiers.contains(ShortcutModifier.meta)) {
      modifiers
        ..remove(ShortcutModifier.ctrl)
        ..add(ShortcutModifier.meta);
    }
  }
  final binding = normalize(modifiers, keyName);
  if (binding == null) {
    throw FormatException('Unknown key name "$keyName" in "$source"');
  }
  return binding;
}

/// Maps a key name to its [LogicalKeyboardKey]. Unknown names yield null so
/// callers can surface a parse error rather than crash.
LogicalKeyboardKey? keyFor(String name) {
  switch (name) {
    // Letters
    case 'a':
      return LogicalKeyboardKey.keyA;
    case 'b':
      return LogicalKeyboardKey.keyB;
    case 'c':
      return LogicalKeyboardKey.keyC;
    case 'd':
      return LogicalKeyboardKey.keyD;
    case 'e':
      return LogicalKeyboardKey.keyE;
    case 'f':
      return LogicalKeyboardKey.keyF;
    case 'g':
      return LogicalKeyboardKey.keyG;
    case 'h':
      return LogicalKeyboardKey.keyH;
    case 'i':
      return LogicalKeyboardKey.keyI;
    case 'j':
      return LogicalKeyboardKey.keyJ;
    case 'k':
      return LogicalKeyboardKey.keyK;
    case 'l':
      return LogicalKeyboardKey.keyL;
    case 'm':
      return LogicalKeyboardKey.keyM;
    case 'n':
      return LogicalKeyboardKey.keyN;
    case 'o':
      return LogicalKeyboardKey.keyO;
    case 'p':
      return LogicalKeyboardKey.keyP;
    case 'q':
      return LogicalKeyboardKey.keyQ;
    case 'r':
      return LogicalKeyboardKey.keyR;
    case 's':
      return LogicalKeyboardKey.keyS;
    case 't':
      return LogicalKeyboardKey.keyT;
    case 'u':
      return LogicalKeyboardKey.keyU;
    case 'v':
      return LogicalKeyboardKey.keyV;
    case 'w':
      return LogicalKeyboardKey.keyW;
    case 'x':
      return LogicalKeyboardKey.keyX;
    case 'y':
      return LogicalKeyboardKey.keyY;
    case 'z':
      return LogicalKeyboardKey.keyZ;
    // Digits (top row)
    case '0':
      return LogicalKeyboardKey.digit0;
    case '1':
      return LogicalKeyboardKey.digit1;
    case '2':
      return LogicalKeyboardKey.digit2;
    case '3':
      return LogicalKeyboardKey.digit3;
    case '4':
      return LogicalKeyboardKey.digit4;
    case '5':
      return LogicalKeyboardKey.digit5;
    case '6':
      return LogicalKeyboardKey.digit6;
    case '7':
      return LogicalKeyboardKey.digit7;
    case '8':
      return LogicalKeyboardKey.digit8;
    case '9':
      return LogicalKeyboardKey.digit9;
    // Function keys
    case 'f1':
      return LogicalKeyboardKey.f1;
    case 'f2':
      return LogicalKeyboardKey.f2;
    case 'f3':
      return LogicalKeyboardKey.f3;
    case 'f4':
      return LogicalKeyboardKey.f4;
    case 'f5':
      return LogicalKeyboardKey.f5;
    case 'f6':
      return LogicalKeyboardKey.f6;
    case 'f7':
      return LogicalKeyboardKey.f7;
    case 'f8':
      return LogicalKeyboardKey.f8;
    case 'f9':
      return LogicalKeyboardKey.f9;
    case 'f10':
      return LogicalKeyboardKey.f10;
    case 'f11':
      return LogicalKeyboardKey.f11;
    case 'f12':
      return LogicalKeyboardKey.f12;
    // Navigation and editing keys
    case 'tab':
      return LogicalKeyboardKey.tab;
    case 'enter':
    case 'return':
      return LogicalKeyboardKey.enter;
    case 'escape':
    case 'esc':
      return LogicalKeyboardKey.escape;
    case 'arrowup':
    case 'up':
      return LogicalKeyboardKey.arrowUp;
    case 'arrowdown':
    case 'down':
      return LogicalKeyboardKey.arrowDown;
    case 'arrowleft':
    case 'left':
      return LogicalKeyboardKey.arrowLeft;
    case 'arrowright':
    case 'right':
      return LogicalKeyboardKey.arrowRight;
    case 'home':
      return LogicalKeyboardKey.home;
    case 'end':
      return LogicalKeyboardKey.end;
    case 'pageup':
      return LogicalKeyboardKey.pageUp;
    case 'pagedown':
      return LogicalKeyboardKey.pageDown;
    case 'space':
    case 'spacebar':
      return LogicalKeyboardKey.space;
    // Punctuation
    case 'comma':
      return LogicalKeyboardKey.comma;
    case 'period':
    case 'dot':
      return LogicalKeyboardKey.period;
    case 'slash':
      return LogicalKeyboardKey.slash;
    case 'backslash':
      return LogicalKeyboardKey.backslash;
    case 'semicolon':
      return LogicalKeyboardKey.semicolon;
    case 'quote':
    case 'apostrophe':
      return LogicalKeyboardKey.quote;
    case 'bracketleft':
      return LogicalKeyboardKey.bracketLeft;
    case 'bracketright':
      return LogicalKeyboardKey.bracketRight;
    case 'minus':
      return LogicalKeyboardKey.minus;
    case 'equal':
      return LogicalKeyboardKey.equal;
    case 'backspace':
      return LogicalKeyboardKey.backspace;
    case 'delete':
    case 'del':
      return LogicalKeyboardKey.delete;
  }
  return null;
}

/// Normalizes and validates a modifier set + key name, returning null when the
/// combination is not a legal shortcut.
///
/// - Requires the key name to resolve to a [LogicalKeyboardKey] (unknown name
///   is a parse error, not a crash).
/// - Requires at least one modifier for printable keys: a bare letter, digit or
///   punctuation mark would steal ordinary typing.
/// - Rejects `Shift`+printable too (e.g. `Shift+X` still types `X`), and
///   `Shift` alone produces no meaningful command.
/// - Bare non-printable keys (F1–F12, arrows, Tab, Enter, Escape, Home/End,
///   PageUp/Down) are allowed without a modifier.
ShortcutBinding? normalize(Set<ShortcutModifier> modifiers, String keyName) {
  final key = keyName.trim().toLowerCase();
  if (key.isEmpty) return null;
  final keyObj = keyFor(key);
  if (keyObj == null) return null;
  final printable = _isPrintable(keyObj, key);
  if (!modifiers.any((m) => m != ShortcutModifier.shift) && printable) {
    // No non-Shift modifier (empty set, or Shift only) over a printable key.
    return null;
  }
  final onlyShift =
      modifiers.isNotEmpty &&
      modifiers.every((m) => m == ShortcutModifier.shift);
  if (onlyShift && printable) return null;
  return ShortcutBinding._(modifiers: Set.unmodifiable(modifiers), key: key);
}

bool _isPrintable(LogicalKeyboardKey key, String name) {
  // Only single-character keys are printable and thus steal typing; multi-char
  // names (f1..f12, tab, enter, arrowup, home…) are commands. Letters, digits
  // and punctuation are printable.
  if (name.length != 1) return false;
  final code = name.codeUnitAt(0);
  if ((code >= 0x61 && code <= 0x7a) || (code >= 0x30 && code <= 0x39)) {
    return true;
  }
  switch (key) {
    case LogicalKeyboardKey.comma:
    case LogicalKeyboardKey.period:
    case LogicalKeyboardKey.slash:
    case LogicalKeyboardKey.backslash:
    case LogicalKeyboardKey.semicolon:
    case LogicalKeyboardKey.quote:
    case LogicalKeyboardKey.bracketLeft:
    case LogicalKeyboardKey.bracketRight:
    case LogicalKeyboardKey.minus:
    case LogicalKeyboardKey.equal:
      return true;
    default:
      return false;
  }
}

/// The default chord for [action] on the given platform. The primary modifier
/// is meta on macOS and ctrl elsewhere; `Ctrl+Tab` is plain (no primary).
ShortcutBinding defaultBinding(ShortcutAction action, bool isMac) {
  final primary = ShortcutBinding.primaryModifier(isMac);
  switch (action) {
    case ShortcutAction.newNote:
    case ShortcutAction.quickSwitcher:
    case ShortcutAction.findInNote:
    case ShortcutAction.save:
    case ShortcutAction.closeTab:
    case ShortcutAction.toggleSource:
      return ShortcutBinding._(modifiers: {primary}, key: _defaultKey(action));
    case ShortcutAction.reopenClosedTab:
      return ShortcutBinding._(
        modifiers: {primary, ShortcutModifier.shift},
        key: 't',
      );
    case ShortcutAction.toggleFocus:
      return const ShortcutBinding._(modifiers: {}, key: 'f11');
    case ShortcutAction.nextTab:
      return ShortcutBinding._(modifiers: {ShortcutModifier.ctrl}, key: 'tab');
  }
}

String _defaultKey(ShortcutAction action) => switch (action) {
  ShortcutAction.newNote => 'n',
  ShortcutAction.quickSwitcher => 'k',
  ShortcutAction.findInNote => 'f',
  ShortcutAction.save => 's',
  ShortcutAction.closeTab => 'w',
  ShortcutAction.toggleSource => 'e',
  _ => '',
};

/// Reverse of [keyFor]: the canonical, bindable name for a
/// [LogicalKeyboardKey], or null when the key has no name (used by the shortcut
/// capture dialog). Letters and digits use their own label; function keys are
/// normalized to lowercase `f1`..`f12`.
String? keyNameForLogicalKey(LogicalKeyboardKey key) {
  final label = key.keyLabel.toLowerCase();
  if (label.length == 1 && _isAlphaOrDigit(label.codeUnitAt(0))) {
    return label;
  }
  if (label.length >= 2 &&
      label.length <= 3 &&
      label[0] == 'f' &&
      _isDigitsOnly(label.substring(1))) {
    return label;
  }
  switch (key) {
    case LogicalKeyboardKey.tab:
      return 'tab';
    case LogicalKeyboardKey.enter:
    case LogicalKeyboardKey.numpadEnter:
      return 'enter';
    case LogicalKeyboardKey.escape:
      return 'escape';
    case LogicalKeyboardKey.arrowUp:
      return 'arrowup';
    case LogicalKeyboardKey.arrowDown:
      return 'arrowdown';
    case LogicalKeyboardKey.arrowLeft:
      return 'arrowleft';
    case LogicalKeyboardKey.arrowRight:
      return 'arrowright';
    case LogicalKeyboardKey.home:
      return 'home';
    case LogicalKeyboardKey.end:
      return 'end';
    case LogicalKeyboardKey.pageUp:
      return 'pageup';
    case LogicalKeyboardKey.pageDown:
      return 'pagedown';
    case LogicalKeyboardKey.space:
      return 'space';
    case LogicalKeyboardKey.comma:
      return 'comma';
    case LogicalKeyboardKey.period:
      return 'period';
    case LogicalKeyboardKey.slash:
      return 'slash';
    case LogicalKeyboardKey.backslash:
      return 'backslash';
    case LogicalKeyboardKey.semicolon:
      return 'semicolon';
    case LogicalKeyboardKey.quote:
      return 'quote';
    case LogicalKeyboardKey.bracketLeft:
      return 'bracketleft';
    case LogicalKeyboardKey.bracketRight:
      return 'bracketright';
    case LogicalKeyboardKey.minus:
      return 'minus';
    case LogicalKeyboardKey.equal:
      return 'equal';
    default:
      return null;
  }
}

bool _isAlphaOrDigit(int code) =>
    (code >= 0x61 && code <= 0x7a) || (code >= 0x30 && code <= 0x39);

bool _isDigitsOnly(String s) {
  for (final code in s.codeUnits) {
    if (code < 0x30 || code > 0x39) return false;
  }
  return true;
}

/// Returns the id of the action whose binding in [all] equals [binding], or
/// null when the chord is free. [exclude] skips the action being edited so a
/// chord identical to its own current value is not reported as a conflict.
///
/// The map is `actionId -> serialized chord` (e.g. `{"newNote": "ctrl+n"}`),
/// read back with [parseShortcut], so conflicts are judged on normalized
/// chords rather than raw strings.
String? findConflict(
  ShortcutAction action,
  ShortcutBinding binding,
  Map<String, String> all, {
  required bool isMac,
  ShortcutAction? exclude,
}) {
  for (final entry in all.entries) {
    final other = ShortcutAction.byId(entry.key);
    if (other == null || other == exclude) continue;
    final ShortcutBinding otherBinding;
    try {
      otherBinding = parseShortcut(entry.value, isMac: isMac);
    } on FormatException {
      continue;
    }
    if (otherBinding == binding) return other.id;
  }
  return null;
}
