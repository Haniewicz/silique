import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/shortcut_bindings.dart';

void main() {
  group('parse / format round-trip', () {
    test('round-trips a modifier+letter chord', () {
      final binding = parseShortcut('ctrl+shift+t', isMac: false);
      expect(binding.format(), 'ctrl+shift+t');
      expect(binding.hasCtrl, isTrue);
      expect(binding.hasShift, isTrue);
      expect(binding.hasMeta, isFalse);
      expect(binding.key, 't');
    });

    test('round-trips meta and bare function key', () {
      expect(parseShortcut('meta+k', isMac: true).format(), 'meta+k');
      expect(parseShortcut('f11', isMac: false).format(), 'f11');
    });

    test('accepts cmd/control aliases', () {
      expect(parseShortcut('cmd+n', isMac: true).format(), 'meta+n');
      expect(parseShortcut('control+n', isMac: false).format(), 'ctrl+n');
    });

    test('is case and whitespace insensitive', () {
      expect(parseShortcut('  CTRL + S ', isMac: false).format(), 'ctrl+s');
    });
  });

  group('defaults per platform', () {
    test('non-mac uses ctrl', () {
      expect(defaultBinding(ShortcutAction.newNote, false).format(), 'ctrl+n');
      expect(
        defaultBinding(ShortcutAction.reopenClosedTab, false).format(),
        'ctrl+shift+t',
      );
      expect(
        defaultBinding(ShortcutAction.nextTab, false).format(),
        'ctrl+tab',
      );
      expect(
        defaultBinding(ShortcutAction.toggleFocus, false).format(),
        'f11',
      );
    });

    test('mac uses meta for the primary modifier', () {
      expect(defaultBinding(ShortcutAction.newNote, true).format(), 'meta+n');
      expect(
        defaultBinding(ShortcutAction.reopenClosedTab, true).format(),
        'meta+shift+t',
      );
      // nextTab and toggleFocus are platform-neutral.
      expect(defaultBinding(ShortcutAction.nextTab, true).format(), 'ctrl+tab');
      expect(
        defaultBinding(ShortcutAction.toggleFocus, true).format(),
        'f11',
      );
    });
  });

  group('validation', () {
    test('rejects a bare letter', () {
      expect(normalize({}, 'n'), isNull);
    });

    test('rejects shift+letter', () {
      expect(normalize({ShortcutModifier.shift}, 'n'), isNull);
    });

    test('accepts ctrl+letter and bare function key', () {
      expect(
        normalize({ShortcutModifier.ctrl}, 'n'),
        isNotNull,
      );
      expect(normalize({}, 'f11'), isNotNull);
      expect(normalize({}, 'escape'), isNotNull);
    });

    test('ShortcutBinding constructor throws on invalid chords', () {
      expect(
        () => ShortcutBinding(modifiers: {}, key: 'n'),
        throwsFormatException,
      );
      expect(
        () => ShortcutBinding(modifiers: {ShortcutModifier.shift}, key: 'n'),
        throwsFormatException,
      );
    });
  });

  group('unknown keys', () {
    test('parse throws FormatException for unknown key', () {
      expect(() => parseShortcut('ctrl+notakey', isMac: false), throwsFormatException);
    });

    test('keyFor returns null for unknown names', () {
      expect(keyFor('notakey'), isNull);
      expect(keyFor('f13'), isNull);
    });
  });

  group('conflicts', () {
    test('finds a chord already assigned to another action', () {
      final conflict = findConflict(
        ShortcutAction.save,
        parseShortcut('ctrl+n', isMac: false),
        {'newNote': 'ctrl+n', 'save': 'ctrl+s'},
        isMac: false,
        exclude: ShortcutAction.save,
      );
      expect(conflict, 'newNote');
    });

    test('ignores the action being edited', () {
      final conflict = findConflict(
        ShortcutAction.save,
        parseShortcut('ctrl+s', isMac: false),
        {'newNote': 'ctrl+n', 'save': 'ctrl+s'},
        isMac: false,
        exclude: ShortcutAction.save,
      );
      expect(conflict, isNull);
    });

    test('returns null when free', () {
      final conflict = findConflict(
        ShortcutAction.save,
        parseShortcut('ctrl+shift+s', isMac: false),
        {'newNote': 'ctrl+n'},
        isMac: false,
        exclude: ShortcutAction.save,
      );
      expect(conflict, isNull);
    });
  });

  group('logical key mapping', () {
    test('maps letters, digits, function and navigation keys', () {
      expect(keyFor('a'), LogicalKeyboardKey.keyA);
      expect(keyFor('7'), LogicalKeyboardKey.digit7);
      expect(keyFor('f12'), LogicalKeyboardKey.f12);
      expect(keyFor('tab'), LogicalKeyboardKey.tab);
      expect(keyFor('enter'), LogicalKeyboardKey.enter);
      expect(keyFor('escape'), LogicalKeyboardKey.escape);
      expect(keyFor('arrowup'), LogicalKeyboardKey.arrowUp);
      expect(keyFor('home'), LogicalKeyboardKey.home);
      expect(keyFor('pageup'), LogicalKeyboardKey.pageUp);
      expect(keyFor('space'), LogicalKeyboardKey.space);
      expect(keyFor('slash'), LogicalKeyboardKey.slash);
    });

    test('keyNameForLogicalKey reverses common keys', () {
      expect(keyNameForLogicalKey(LogicalKeyboardKey.keyN), 'n');
      expect(keyNameForLogicalKey(LogicalKeyboardKey.f11), 'f11');
      expect(keyNameForLogicalKey(LogicalKeyboardKey.tab), 'tab');
      expect(keyNameForLogicalKey(LogicalKeyboardKey.arrowDown), 'arrowdown');
    });
  });
}