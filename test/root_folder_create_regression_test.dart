import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'hidden_notes_home_test.dart' show drainUntil, fixture, mount;

void main() {
  testWidgets(
    'sidebar "Nowy folder" button creates a folder at the vault root',
    (tester) async {
      final repo = await fixture(tester);
      await mount(tester, repo, desktop: true);
      expect(repo.allFolders(repo.vaults.single.id), isEmpty);

      await tester.tap(find.byKey(const Key('new-root-folder')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('folder-name')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('folder-name')), 'Projekty');
      await tester.tap(find.byKey(const Key('folder-create')));
      // Creation persists through real async storage; the nested _run used to
      // see _busy from the outer _run and drop it silently (RED before fix).
      await drainUntil(
        tester,
        () => repo.allFolders(repo.vaults.single.id).contains('Projekty'),
      );
      await tester.pump(const Duration(seconds: 1));

      expect(repo.allFolders(repo.vaults.single.id), contains('Projekty'));
      expect(find.text('Projekty'), findsWidgets);
      expect(
        find.descendant(
          of: find.byKey(const Key('folder-menu-Projekty')),
          matching: find.byIcon(Icons.more_horiz),
        ),
        findsOneWidget,
        reason: 'the new folder must appear as a row in the sidebar tree',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
