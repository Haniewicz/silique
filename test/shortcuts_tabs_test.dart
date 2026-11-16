import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/device_settings.dart';
import 'package:silique/core/shortcut_bindings.dart';

import 'hidden_notes_home_test.dart' as home;

bool _press(
  LogicalKeyboardKey logical,
  PhysicalKeyboardKey physical, {
  LogicalKeyboardKey? modifier,
  PhysicalKeyboardKey? modifierPhysical,
  PhysicalKeyboardKey? physicalOverride,
  LogicalKeyboardKey? shift,
}) {
  void key(LogicalKeyboardKey l, PhysicalKeyboardKey p, bool down) {
    HardwareKeyboard.instance.handleKeyEvent(
      down
          ? KeyDownEvent(
              physicalKey: p,
              logicalKey: l,
              timeStamp: Duration.zero,
            )
          : KeyUpEvent(
              physicalKey: p,
              logicalKey: l,
              timeStamp: Duration.zero,
            ),
    );
  }

  if (modifier != null) {
    key(modifier, modifierPhysical ?? PhysicalKeyboardKey.controlLeft, true);
  }
  if (shift != null) {
    key(shift, PhysicalKeyboardKey.shiftLeft, true);
  }
  final handled = HardwareKeyboard.instance.handleKeyEvent(
    KeyDownEvent(
      physicalKey: physicalOverride ?? physical,
      logicalKey: logical,
      timeStamp: Duration.zero,
    ),
  );
  key(logical, physicalOverride ?? physical, false);
  if (shift != null) key(shift, PhysicalKeyboardKey.shiftLeft, false);
  if (modifier != null) {
    key(modifier, modifierPhysical ?? PhysicalKeyboardKey.controlLeft, false);
  }
  return handled;
}

String _activeTitle(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const Key('note-title')))
    .controller!
    .text;

void main() {
  testWidgets('Ctrl+W closes the active tab; Ctrl+Shift+T reopens it', (
    tester,
  ) async {
    final repo = await home.fixture(tester);
    // Add a second note before mounting so the list holds two entries. The new
    // note is the most recent, so it is auto-selected on startup.
    await tester.runAsync(() async {
      final vault = repo.vaults.single.id;
      final second = await repo.createNote(vault);
      await repo.save(second.copyWith(title: 'Second note'));
    });
    await home.mount(tester, repo, desktop: true);
    expect(_activeTitle(tester), 'Second note');

    // Open the older note as a second tab (its title appears once: the list).
    await tester.tap(find.text('Visible secret'));
    await tester.pumpAndSettle();
    expect(_activeTitle(tester), 'Visible secret');

    // Ctrl+W closes the active tab and falls back to the remaining one.
    _press(
      LogicalKeyboardKey.keyW,
      PhysicalKeyboardKey.keyW,
      modifier: LogicalKeyboardKey.controlLeft,
    );
    await tester.pumpAndSettle();
    expect(_activeTitle(tester), 'Second note');

    // Ctrl+Shift+T reopens the most recently closed note.
    _press(
      LogicalKeyboardKey.keyT,
      PhysicalKeyboardKey.keyT,
      modifier: LogicalKeyboardKey.controlLeft,
      shift: LogicalKeyboardKey.shiftLeft,
    );
    await tester.pumpAndSettle();
    expect(_activeTitle(tester), 'Visible secret');
  });

  testWidgets('changing a shortcut in the store applies immediately', (
    tester,
  ) async {
    final repo = await home.fixture(tester);
    await tester.runAsync(() async {
      final vault = repo.vaults.single.id;
      final second = await repo.createNote(vault);
      await repo.save(second.copyWith(title: 'Second note'));
    });
    await home.mount(tester, repo, desktop: true);
    expect(_activeTitle(tester), 'Second note');

    // Open the older note as a second tab.
    await tester.tap(find.text('Visible secret'));
    await tester.pumpAndSettle();
    expect(_activeTitle(tester), 'Visible secret');

    // Rebind closeTab to Ctrl+Shift+X.
    await tester.runAsync(() async {
      await deviceSettings.setBinding(
        ShortcutAction.closeTab,
        ShortcutBinding(
          modifiers: {ShortcutModifier.ctrl, ShortcutModifier.shift},
          key: 'x',
        ),
      );
    });
    await tester.pumpAndSettle();

    // Ctrl+W (the old default) no longer closes; Ctrl+Shift+X does.
    _press(
      LogicalKeyboardKey.keyW,
      PhysicalKeyboardKey.keyW,
      modifier: LogicalKeyboardKey.controlLeft,
    );
    await tester.pumpAndSettle();
    expect(_activeTitle(tester), 'Visible secret');

    _press(
      LogicalKeyboardKey.keyX,
      PhysicalKeyboardKey.keyX,
      modifier: LogicalKeyboardKey.controlLeft,
      shift: LogicalKeyboardKey.shiftLeft,
    );
    await tester.pumpAndSettle();
    expect(_activeTitle(tester), 'Second note');

    await tester.runAsync(deviceSettings.resetToDefaults);
  });
}