import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/models.dart';
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

    _press(
      LogicalKeyboardKey.keyK,
      PhysicalKeyboardKey.keyK,
      modifier: LogicalKeyboardKey.controlLeft,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('quick-switcher-field')), findsOneWidget);
    // The switcher owns keyboard focus (autofocus), not a focus onto the list
    // search field as the pre-quick-switcher Ctrl+K used to do.
    final switcherField = tester.widget<TextField>(
      find.byKey(const Key('quick-switcher-field')),
    );
    expect(switcherField.focusNode?.hasFocus ?? false, isTrue);
  });

  testWidgets('opening the switcher steals focus from the editor', (
    tester,
  ) async {
    final repo = await home.fixture(tester);
    await home.mount(tester, repo, desktop: true);

    // Open the seeded note so its title field exists and owns keyboard focus,
    // mirroring real use where the editor/title holds focus before Ctrl+K.
    final noteId = repo.notes[repo.vaults.single.id]!.values.single.id;
    await tester.tap(find.byKey(Key('note-card-$noteId')));
    await tester.pumpAndSettle();
    final titleField = tester.widget<TextField>(
      find.byKey(const Key('note-title')),
    );
    titleField.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    expect(titleField.focusNode!.hasFocus, isTrue);

    _press(
      LogicalKeyboardKey.keyK,
      PhysicalKeyboardKey.keyK,
      modifier: LogicalKeyboardKey.controlLeft,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('quick-switcher-field')), findsOneWidget);
    final switcherField = tester.widget<TextField>(
      find.byKey(const Key('quick-switcher-field')),
    );
    expect(switcherField.focusNode?.hasFocus ?? false, isTrue);
    expect(
      titleField.focusNode!.hasFocus,
      isFalse,
      reason: 'the title field must lose focus to the quick switcher',
    );
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

    _press(
      LogicalKeyboardKey.keyK,
      PhysicalKeyboardKey.keyK,
      modifier: LogicalKeyboardKey.controlLeft,
    );
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
    _press(
      LogicalKeyboardKey.keyK,
      PhysicalKeyboardKey.keyK,
      modifier: LogicalKeyboardKey.controlLeft,
    );
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

  testWidgets('global shortcuts defer to the open quick switcher', (
    tester,
  ) async {
    final repo = await home.fixture(tester);
    await home.mount(tester, repo, desktop: true);
    final before = repo.notes.values.expand((notes) => notes.values).length;

    _press(
      LogicalKeyboardKey.keyK,
      PhysicalKeyboardKey.keyK,
      modifier: LogicalKeyboardKey.controlLeft,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick-switcher-field')), findsOneWidget);

    // Ctrl+N and Ctrl+W would create a note / close a tab if the global handler
    // acted on the document underneath the overlay. With the switcher open both
    // are rejected before dispatch, and the panel keeps the keyboard.
    final newNoteHandled = _press(
      LogicalKeyboardKey.keyN,
      PhysicalKeyboardKey.keyN,
      modifier: LogicalKeyboardKey.controlLeft,
    );
    final closeTabHandled = _press(
      LogicalKeyboardKey.keyW,
      PhysicalKeyboardKey.keyW,
      modifier: LogicalKeyboardKey.controlLeft,
    );
    expect(newNoteHandled, isFalse);
    expect(closeTabHandled, isFalse);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('quick-switcher-field')), findsOneWidget);
    expect(
      repo.notes.values.expand((notes) => notes.values).length,
      before,
      reason: 'Ctrl+N must not create a note under the quick switcher',
    );
  });

  testWidgets('macOS binding ignores the non-primary modifier', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final repo = await home.fixture(tester);
      await home.mount(tester, repo, desktop: true);

      // The stored default on macOS is Cmd+K: Ctrl+K must not fire, so a
      // system combination such as Cmd+Tab can never be reached by Ctrl either.
      final ctrlHandled = _press(
        LogicalKeyboardKey.keyK,
        PhysicalKeyboardKey.keyK,
        modifier: LogicalKeyboardKey.controlLeft,
        modifierPhysical: PhysicalKeyboardKey.controlLeft,
      );
      await tester.pumpAndSettle();
      expect(ctrlHandled, isFalse);
      expect(find.byKey(const Key('quick-switcher-field')), findsNothing);

      final metaHandled = _press(
        LogicalKeyboardKey.keyK,
        PhysicalKeyboardKey.keyK,
        modifier: LogicalKeyboardKey.metaLeft,
        modifierPhysical: PhysicalKeyboardKey.metaLeft,
      );
      await tester.pumpAndSettle();
      expect(metaHandled, isTrue);
      expect(find.byKey(const Key('quick-switcher-field')), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  group('tag search', () {
    Note tagged(String id, String title, List<String> tags) => Note(
      id: id,
      vaultId: 'vault',
      title: title,
      body: '',
      updatedAt: DateTime.utc(2026, 1, 1),
      tags: tags,
    );

    Future<void> pump(
      WidgetTester tester,
      List<Note> notes, {
      ValueChanged<Note>? onOpen,
      VoidCallback? onClose,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuickSwitcher(
              notes: notes,
              onOpen: onOpen ?? (_) {},
              onClose: onClose ?? () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(
        find.byKey(const Key('quick-switcher-field')),
        text,
      );
      await tester.pumpAndSettle();
    }

    Future<void> pressEnter(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    }

    testWidgets('typing # lists the vault tags, most used first', (
      tester,
    ) async {
      await pump(tester, [
        tagged('a', 'Alfa', ['praca', 'plan']),
        tagged('b', 'Beta', ['praca']),
        tagged('c', 'Gamma', ['dom']),
      ]);
      await type(tester, '#');

      expect(find.byKey(const Key('quick-switcher-tag-list')), findsOneWidget);
      expect(find.byKey(const Key('quick-switcher-tag-praca')), findsOneWidget);
      expect(find.byKey(const Key('quick-switcher-tag-plan')), findsOneWidget);
      expect(find.byKey(const Key('quick-switcher-tag-dom')), findsOneWidget);
      // `praca` is cited twice, so it precedes the single-use tags.
      final praca = tester
          .getTopLeft(find.byKey(const Key('quick-switcher-tag-praca')))
          .dy;
      final dom = tester
          .getTopLeft(find.byKey(const Key('quick-switcher-tag-dom')))
          .dy;
      expect(praca, lessThan(dom));
      expect(
        find.descendant(
          of: find.byKey(const Key('quick-switcher-tag-praca')),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );
      // Note rows are replaced by tag suggestions while `#` is typed.
      expect(find.byKey(const Key('quick-switcher-list')), findsNothing);
    });

    testWidgets('the # fragment narrows tags case-insensitively', (
      tester,
    ) async {
      await pump(tester, [
        tagged('a', 'Alfa', ['Praca']),
        tagged('b', 'Beta', ['dom']),
      ]);
      await type(tester, '#pra');

      expect(find.byKey(const Key('quick-switcher-tag-Praca')), findsOneWidget);
      expect(find.byKey(const Key('quick-switcher-tag-dom')), findsNothing);
    });

    testWidgets('Enter on a tag filters the list to that tag\'s notes', (
      tester,
    ) async {
      await pump(tester, [
        tagged('a', 'Alfa', ['praca']),
        tagged('b', 'Beta', ['dom']),
      ]);
      await type(tester, '#pra');
      await pressEnter(tester);

      expect(
        find.byKey(const Key('quick-switcher-tag-filter')),
        findsOneWidget,
      );
      expect(find.text('#praca'), findsOneWidget);
      expect(find.byKey(const Key('quick-switcher-list')), findsOneWidget);
      expect(find.text('Alfa'), findsOneWidget);
      expect(find.text('Beta'), findsNothing);
      // The field is cleared so typing narrows the tagged notes again.
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('quick-switcher-field')))
            .controller!
            .text,
        isEmpty,
      );
    });

    testWidgets('a note opened from a tag filter is opened and closes', (
      tester,
    ) async {
      Note? opened;
      var closed = 0;
      await pump(
        tester,
        [
          tagged('a', 'Alfa', ['praca']),
        ],
        onOpen: (note) => opened = note,
        onClose: () => closed++,
      );
      await type(tester, '#praca');
      await pressEnter(tester);
      await pressEnter(tester);

      expect(opened?.title, 'Alfa');
      expect(closed, 1);
    });

    testWidgets('Escape clears the tag filter before closing the switcher', (
      tester,
    ) async {
      var closed = 0;
      await pump(tester, [
        tagged('a', 'Alfa', ['praca']),
        tagged('b', 'Beta', ['dom']),
      ], onClose: () => closed++);
      await type(tester, '#praca');
      await pressEnter(tester);
      expect(
        find.byKey(const Key('quick-switcher-tag-filter')),
        findsOneWidget,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quick-switcher-tag-filter')), findsNothing);
      expect(find.text('Beta'), findsOneWidget);
      expect(closed, 0, reason: 'Escape drops the filter first');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(closed, 1);
    });

    testWidgets('# with no matching tag explains the empty state', (
      tester,
    ) async {
      await pump(tester, [
        tagged('a', 'Alfa', ['praca']),
      ]);
      await type(tester, '#zzz');
      expect(find.textContaining('pasujących tagów'), findsOneWidget);
    });
  });
}
