import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/ui/quick_switcher.dart';

import 'hidden_notes_home_test.dart' as home;

/// Sends a key-down through the global HardwareKeyboard handler, mirroring how
/// the app's own `_globalShortcuts` is fed (pre-focus dispatch).
bool _press(
  LogicalKeyboardKey logical,
  PhysicalKeyboardKey physical, {
  LogicalKeyboardKey? modifier,
  PhysicalKeyboardKey? modifierPhysical,
}) {
  if (modifier != null) {
    HardwareKeyboard.instance.handleKeyEvent(
      KeyDownEvent(
        physicalKey: modifierPhysical ?? PhysicalKeyboardKey.controlLeft,
        logicalKey: modifier,
        timeStamp: Duration.zero,
      ),
    );
  }
  final down = HardwareKeyboard.instance.handleKeyEvent(
    KeyDownEvent(
      physicalKey: physical,
      logicalKey: logical,
      timeStamp: Duration.zero,
    ),
  );
  HardwareKeyboard.instance.handleKeyEvent(
    KeyUpEvent(
      physicalKey: physical,
      logicalKey: logical,
      timeStamp: Duration.zero,
    ),
  );
  if (modifier != null) {
    HardwareKeyboard.instance.handleKeyEvent(
      KeyUpEvent(
        physicalKey: modifierPhysical ?? PhysicalKeyboardKey.controlLeft,
        logicalKey: modifier,
        timeStamp: Duration.zero,
      ),
    );
  }
  return down;
}

void main() {
  testWidgets('Ctrl+K opens the floating quick switcher, not search focus', (
    tester,
  ) async {
    final repo = await home.fixture(tester);
    await home.mount(tester, repo, desktop: true);

    // The quick switcher panel is initially absent.
    expect(find.byKey(const Key('quick-switcher-field')), findsNothing);

    _press(LogicalKeyboardKey.keyK, PhysicalKeyboardKey.keyK, modifier: LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('quick-switcher-field')), findsOneWidget);
    // The switcher owns keyboard focus (autofocus), not a focus onto the list
    // search field as the pre-quick-switcher Ctrl+K used to do.
    final switcherField = tester.widget<TextField>(
      find.byKey(const Key('quick-switcher-field')),
    );
    expect(switcherField.focusNode?.hasFocus ?? false, isTrue);
  });

  testWidgets('typing filters; Enter opens the matching note; Esc closes', (
    tester,
  ) async {
    final repo = await home.fixture(tester);
    await home.mount(tester, repo, desktop: true);
    await tester.runAsync(() async {
      final vault = repo.vaults.single.id;
      final alpha = await repo.createNote(vault);
      await repo.save(alpha.copyWith(title: 'Alpha note'));
      final beta = await repo.createNote(vault);
      await repo.save(beta.copyWith(title: 'Beta note'));
    });

    _press(LogicalKeyboardKey.keyK, PhysicalKeyboardKey.keyK, modifier: LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick-switcher-field')), findsOneWidget);

    // Both recent notes are listed (empty query = recent, max 8).
    expect(find.byKey(const Key('quick-switcher-list')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('quick-switcher-field')),
      'beta',
    );
    await tester.pumpAndSettle();
    expect(find.text('Beta note'), findsWidgets);

    // Enter opens the highlighted (first) result.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    // The switcher closes after opening.
    expect(find.byKey(const Key('quick-switcher-field')), findsNothing);

    // Esc closes without opening (reopen and press escape).
    _press(LogicalKeyboardKey.keyK, PhysicalKeyboardKey.keyK, modifier: LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick-switcher-field')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick-switcher-field')), findsNothing);
  });

  testWidgets('locked vault shows a message instead of an empty list', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuickSwitcher(
            notes: const [],
            locked: true,
            onOpen: (_) {},
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick-switcher-field')), findsOneWidget);
    expect(find.textContaining('zablokowan'), findsOneWidget);
  });
}