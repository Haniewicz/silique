import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
      final wells = find.descendant(
        of: footer,
        matching: find.byType(InkWell),
      );
      expect(wells, findsNWidgets(3));
      for (final element in wells.evaluate()) {
        final well = element.widget as InkWell;
        expect(well.borderRadius, BorderRadius.circular(6));
        expect(well.onTap, isNotNull);
      }
      // The stable navigation key stays on the middle (hidden) action.
      expect(
        find.descendant(
          of: find.byKey(const Key('hidden-folder-nav')),
          matching: find.byType(InkWell),
        ),
        findsOneWidget,
      );

      // Selecting an action keeps the accent .12 surface with radius 6.
      await tester.tap(find.text('Usunięte'));
      await tester.pumpAndSettle();
      final surfaces = tester
          .widgetList<Material>(
            find.ancestor(
              of: find.text('Usunięte'),
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
}
