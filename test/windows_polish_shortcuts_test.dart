import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';

import 'hidden_notes_home_test.dart' as home;

// Platform key/IME contract tests, not an OS keyboard-layout emulator. Characters
// below stand for text supplied by Windows; production must never synthesize it.
final _letters = <LogicalKeyboardKey, (PhysicalKeyboardKey, String)>{
  LogicalKeyboardKey.keyA: (PhysicalKeyboardKey.keyA, 'ą'),
  LogicalKeyboardKey.keyC: (PhysicalKeyboardKey.keyC, 'ć'),
  LogicalKeyboardKey.keyE: (PhysicalKeyboardKey.keyE, 'ę'),
  LogicalKeyboardKey.keyL: (PhysicalKeyboardKey.keyL, 'ł'),
  LogicalKeyboardKey.keyN: (PhysicalKeyboardKey.keyN, 'ń'),
  LogicalKeyboardKey.keyO: (PhysicalKeyboardKey.keyO, 'ó'),
  LogicalKeyboardKey.keyS: (PhysicalKeyboardKey.keyS, 'ś'),
  LogicalKeyboardKey.keyX: (PhysicalKeyboardKey.keyX, 'ź'),
  LogicalKeyboardKey.keyZ: (PhysicalKeyboardKey.keyZ, 'ż'),
};

bool _key(
  LogicalKeyboardKey logical,
  PhysicalKeyboardKey physical,
  bool down, {
  String? character,
}) => HardwareKeyboard.instance.handleKeyEvent(
  down
      ? KeyDownEvent(
          physicalKey: physical,
          logicalKey: logical,
          timeStamp: Duration.zero,
          character: character,
        )
      : KeyUpEvent(
          physicalKey: physical,
          logicalKey: logical,
          timeStamp: Duration.zero,
        ),
);

void main() {
  for (final surface in ['title', 'live', 'source']) {
    for (final modifiers in [
      (LogicalKeyboardKey.altRight, true),
      (LogicalKeyboardKey.altLeft, true),
      (LogicalKeyboardKey.altGraph, true),
      (LogicalKeyboardKey.altLeft, false),
    ]) {
      final (alt, withControl) = modifiers;
      for (final uppercase in [false, true]) {
        testWidgets(
          'Windows Polish typing $surface passes through $alt ctrl=$withControl uppercase=$uppercase',
          (tester) async {
            debugDefaultTargetPlatformOverride = TargetPlatform.windows;
            try {
              final repo = await home.fixture(tester);
              await home.mount(tester, repo, desktop: true);
              if (surface == 'source') {
                await tester.tap(find.byTooltip('Markdown / podgląd na żywo'));
                await tester.pumpAndSettle();
              }
              final editable = surface == 'live'
                  ? find
                        .descendant(
                          of: find.byType(LiveMarkdownEditor),
                          matching: find.byType(EditableText),
                        )
                        .first
                  : find.descendant(
                      of: find.byKey(
                        Key(
                          surface == 'title' ? 'note-title' : 'source-editor',
                        ),
                      ),
                      matching: find.byType(EditableText),
                    );
              await tester.tap(editable);
              await tester.pump();
              final state = tester.state<EditableTextState>(editable);
              final initialCount = repo.notes.values
                  .expand((notes) => notes.values)
                  .length;
              var text = '';
              final altPhysical = alt == LogicalKeyboardKey.altLeft
                  ? PhysicalKeyboardKey.altLeft
                  : PhysicalKeyboardKey.altRight;
              for (final entry in _letters.entries) {
                if (withControl) {
                  _key(
                    LogicalKeyboardKey.controlLeft,
                    PhysicalKeyboardKey.controlLeft,
                    true,
                  );
                }
                _key(alt, altPhysical, true);
                if (uppercase) {
                  _key(
                    LogicalKeyboardKey.shiftLeft,
                    PhysicalKeyboardKey.shiftLeft,
                    true,
                  );
                }
                final character = uppercase
                    ? entry.value.$2.toUpperCase()
                    : entry.value.$2;
                final handled = _key(
                  entry.key,
                  entry.value.$1,
                  true,
                  character: character,
                );
                expect(
                  handled,
                  isFalse,
                  reason: '$character must reach platform text input',
                );
                _key(entry.key, entry.value.$1, false);
                if (uppercase) {
                  _key(
                    LogicalKeyboardKey.shiftLeft,
                    PhysicalKeyboardKey.shiftLeft,
                    false,
                  );
                }
                _key(alt, altPhysical, false);
                if (withControl) {
                  _key(
                    LogicalKeyboardKey.controlLeft,
                    PhysicalKeyboardKey.controlLeft,
                    false,
                  );
                }
                for (var i = 0; i < 4; i++) {
                  await tester.pump();
                  await tester.runAsync(
                    () =>
                        Future<void>.delayed(const Duration(milliseconds: 15)),
                  );
                }
                expect(
                  repo.notes.values.expand((notes) => notes.values).length,
                  initialCount,
                  reason: '$character must not invoke New note',
                );
                expect(tester.state<EditableTextState>(editable), same(state));
                text += character;
                tester.testTextInput.updateEditingValue(
                  TextEditingValue(
                    text: text,
                    selection: TextSelection.collapsed(offset: text.length),
                  ),
                );
                await tester.pump();
                expect(state.widget.controller.text, text);
              }
              expect(text, uppercase ? 'ĄĆĘŁŃÓŚŹŻ' : 'ąćęłńóśźż');
              await tester.pumpWidget(const SizedBox());
            } finally {
              debugDefaultTargetPlatformOverride = null;
            }
          },
        );
      }
    }
  }

  for (final modifier in [
    (
      LogicalKeyboardKey.controlLeft,
      PhysicalKeyboardKey.controlLeft,
      TargetPlatform.windows,
    ),
    (
      LogicalKeyboardKey.metaLeft,
      PhysicalKeyboardKey.metaLeft,
      TargetPlatform.macOS,
    ),
  ]) {
    testWidgets('plain ${modifier.$1} commands still work', (tester) async {
      debugDefaultTargetPlatformOverride = modifier.$3;
      try {
        final repo = await home.fixture(tester);
        await home.mount(tester, repo, desktop: true);
        final title = find.byKey(const Key('note-title'));
        await tester.tap(title);
        await tester.pump();
        final count = repo.notes.values.single.length;
        _key(modifier.$1, modifier.$2, true);
        expect(
          _key(LogicalKeyboardKey.keyF, PhysicalKeyboardKey.keyF, true),
          isTrue,
        );
        _key(LogicalKeyboardKey.keyF, PhysicalKeyboardKey.keyF, false);
        _key(modifier.$1, modifier.$2, false);
        await tester.pump();
        expect(find.byKey(const Key('find-bar')), findsOneWidget);
        _key(modifier.$1, modifier.$2, true);
        expect(
          _key(LogicalKeyboardKey.keyN, PhysicalKeyboardKey.keyN, true),
          isTrue,
        );
        _key(LogicalKeyboardKey.keyN, PhysicalKeyboardKey.keyN, false);
        _key(modifier.$1, modifier.$2, false);
        await home.drainUntil(
          tester,
          () => repo.notes.values.single.length == count + 1,
        );
        expect(repo.notes.values.single.length, count + 1);
        await tester.pumpWidget(const SizedBox());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('macOS Option text is neither intercepted nor synthesized', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final repo = await home.fixture(tester);
      await home.mount(tester, repo, desktop: true);
      await tester.tap(find.byKey(const Key('note-title')));
      await tester.pump();
      _key(LogicalKeyboardKey.altLeft, PhysicalKeyboardKey.altLeft, true);
      final handled = _key(
        LogicalKeyboardKey.keyN,
        PhysicalKeyboardKey.keyN,
        true,
        character: '˜',
      );
      _key(LogicalKeyboardKey.keyN, PhysicalKeyboardKey.keyN, false);
      _key(LogicalKeyboardKey.altLeft, PhysicalKeyboardKey.altLeft, false);
      expect(handled, isFalse);
      expect(repo.notes.values.single.length, 1);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('note-title')))
            .controller!
            .text,
        'Visible secret',
        reason: 'Key handling must not synthesize text',
      );
      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('CallbackShortcuts reject Ctrl+AltGraph for every command', (
    tester,
  ) async {
    final repo = await home.fixture(tester);
    await home.mount(tester, repo, desktop: true);
    final shortcuts = tester.widget<CallbackShortcuts>(
      find.byType(CallbackShortcuts).first,
    );
    for (final modifier in [
      (LogicalKeyboardKey.controlLeft, PhysicalKeyboardKey.controlLeft),
      (LogicalKeyboardKey.metaLeft, PhysicalKeyboardKey.metaLeft),
    ]) {
      for (final key in [
        LogicalKeyboardKey.keyF,
        LogicalKeyboardKey.keyN,
        LogicalKeyboardKey.keyK,
        if (modifier.$1 == LogicalKeyboardKey.controlLeft)
          LogicalKeyboardKey.keyS,
      ]) {
        final keyboard = HardwareKeyboard();
        keyboard.handleKeyEvent(
          KeyDownEvent(
            physicalKey: modifier.$2,
            logicalKey: modifier.$1,
            timeStamp: Duration.zero,
          ),
        );
        final event = KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyN,
          logicalKey: key,
          timeStamp: Duration.zero,
        );
        keyboard.handleKeyEvent(event);
        expect(
          shortcuts.bindings.keys.any(
            (binding) => binding.accepts(event, keyboard),
          ),
          isTrue,
          reason: 'Plain ${modifier.$1}+$key must still activate',
        );
        for (final alt in [
          LogicalKeyboardKey.altGraph,
          LogicalKeyboardKey.altLeft,
          LogicalKeyboardKey.altRight,
        ]) {
          keyboard.handleKeyEvent(
            KeyDownEvent(
              physicalKey: PhysicalKeyboardKey.altRight,
              logicalKey: alt,
              timeStamp: Duration.zero,
            ),
          );
          expect(
            shortcuts.bindings.keys.any(
              (binding) => binding.accepts(event, keyboard),
            ),
            isFalse,
            reason: '${modifier.$1}+$alt+$key must remain layout input',
          );
          keyboard.handleKeyEvent(
            KeyUpEvent(
              physicalKey: PhysicalKeyboardKey.altRight,
              logicalKey: alt,
              timeStamp: Duration.zero,
            ),
          );
        }
      }
    }
    await tester.pumpWidget(const SizedBox());
  });
}
