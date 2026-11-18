import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'hidden_notes_home_test.dart' show fixture, mount;

void main() {
  testWidgets('sidebar footer has a settings action and no vault badge', (
    tester,
  ) async {
    final repo = await fixture(tester);
    await mount(tester, repo, desktop: true);

    // The fourth footer action is Ustawienia, keyed for stable navigation.
    final settingsNav = find.byKey(const Key('sidebar-settings-nav'));
    expect(settingsNav, findsOneWidget);

    // The vault badge (note count + E2EE/local caption) is gone.
    expect(find.textContaining('notatek •'), findsNothing);
    expect(find.textContaining('notes •'), findsNothing);
    expect(find.textContaining('• E2EE'), findsNothing);
    expect(find.textContaining('• local'), findsNothing);

    // Tapping it opens the same settings panel (General tab first).
    await tester.tap(settingsNav);
    await tester.pumpAndSettle();
    expect(find.text('Ogólne'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('phone drawer closes when the footer settings action opens', (
    tester,
  ) async {
    final repo = await fixture(tester);
    await mount(tester, repo);
    await tester.tap(find.byTooltip('Foldery i vaulty'));
    await tester.pumpAndSettle();
    final footer = find.byKey(const Key('sidebar-footer-actions'));
    expect(footer, findsOneWidget);

    await tester.tap(find.byKey(const Key('sidebar-settings-nav')));
    await tester.pumpAndSettle();
    expect(find.text('Ogólne'), findsOneWidget);
    // The drawer was dismissed before the settings dialog opened.
    expect(footer, findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
