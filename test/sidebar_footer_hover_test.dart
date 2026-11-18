import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/ui/footer_floating_label.dart';
import 'package:silique/ui/theme.dart' show accent;

import 'hidden_notes_home_test.dart' show fixture, mount;

void main() {
  testWidgets(
    'footer actions hover like folder rows: rounded InkWell, no TextButton',
    (tester) async {
      final repo = await fixture(tester);
      await mount(tester, repo, desktop: true);
      final footer = find.byKey(const Key('sidebar-footer-actions'));
      expect(footer, findsOneWidget);
      expect(
        find.descendant(of: footer, matching: find.byType(TextButton)),
        findsNothing,
      );
      final wells = find.descendant(of: footer, matching: find.byType(InkWell));
      expect(wells, findsNWidgets(4));
      for (final element in wells.evaluate()) {
        final well = element.widget as InkWell;
        expect(well.borderRadius, BorderRadius.circular(6));
        expect(well.onTap, isNotNull);
      }
      // The stable navigation keys stay on the hidden, deleted, import and
      // settings actions.
      for (final key in [
        'deleted-folder-nav',
        'hidden-folder-nav',
        'import-folder-nav',
        'sidebar-settings-nav',
      ]) {
        expect(
          find.descendant(
            of: find.byKey(Key(key)),
            matching: find.byType(InkWell),
          ),
          findsOneWidget,
        );
      }

      // Selecting an action keeps the accent .12 surface with radius 6.
      await tester.tap(find.byKey(const Key('deleted-folder-nav')));
      await tester.pumpAndSettle();
      final surfaces = tester
          .widgetList<Material>(
            find.descendant(
              of: find.byKey(const Key('deleted-folder-nav')),
              matching: find.byType(Material),
            ),
          )
          .where(
            (material) =>
                material.color == accent.withValues(alpha: .12) &&
                material.borderRadius == BorderRadius.circular(6),
          );
      expect(surfaces, isNotEmpty);
      expect(find.byKey(const Key('hidden-folder-nav')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('footer buttons are icon-only with a floating label on hover', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final repo = await fixture(tester);
    await mount(tester, repo, desktop: true);
    final footer = find.byKey(const Key('sidebar-footer-actions'));
    expect(footer, findsOneWidget);

    // No visible text labels live inside the buttons themselves.
    expect(
      find.descendant(of: footer, matching: find.byType(Text)),
      findsNothing,
    );

    // Hovering the deleted action reveals exactly one floating label pill.
    final deleted = find.byKey(const Key('deleted-folder-nav'));
    expect(find.byType(FloatingFooterLabel), findsNWidgets(4));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: tester.getCenter(deleted));
    await gesture.moveTo(tester.getCenter(deleted));
    await tester.pumpAndSettle();
    expect(
      find.text('Usunięte'),
      findsOneWidget,
      reason: 'the floating label shows the localized action name on hover',
    );
    // The accessible name remains available to assistive tech.
    expect(find.bySemanticsLabel('Usunięte'), findsOneWidget);

    // Leaving hides the floating label again.
    await gesture.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(find.text('Usunięte'), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
