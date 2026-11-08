import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'hidden_folder_ui_test.dart' show seedHidden, waitForRealTime;
import 'hidden_notes_home_test.dart'
    show fixture, mount, chooseHiddenFolder, drainUntil;

void main() {
  testWidgets(
    'entering the hidden folder adopts the configured inactivity auto-lock',
    (tester) async {
      final repo = await fixture(tester);
      await seedHidden(tester, repo);
      await mount(tester, repo);
      const window = Duration(milliseconds: 1200);
      // Reproduce a slow native runner: setup may outlive the short test window.
      await tester.runAsync(() => Future<void>.delayed(window * 2));
      await tester.runAsync(() async {
        // Changing the setting preserves the last activity timestamp. Start the
        // short observation window now, not when seedHidden created the key.
        repo.hiddenActivity();
        await repo.setHiddenAutoLock(window);
      });
      await chooseHiddenFolder(tester);
      expect(repo.hiddenUnlocked, isTrue);
      await drainUntil(
        tester,
        () => find.text('Private title').evaluate().isNotEmpty,
      );
      final clock = Stopwatch()..start();
      await waitForRealTime(tester, clock, window * 2);
      // Folder entry re-arms the timer in the widget zone. Advance that clock
      // too, so the callback and the UI wipe run, not just the expiry getter.
      await tester.pump(window * 2);
      expect(
        repo.hiddenUnlocked,
        isFalse,
        reason: 'folder entry must not suspend the inactivity auto-lock',
      );
      // The folder must also stop showing plaintext titles, not just drop the key.
      expect(
        find.text('Private title'),
        findsNothing,
        reason: 'an expired folder must not keep listing secret titles',
      );
    },
    skip: false,
  );

  testWidgets(
    'unlocking by entering the folder arms the configured auto-lock again',
    (tester) async {
      final repo = await fixture(tester);
      await seedHidden(tester, repo);
      await mount(tester, repo);
      const window = Duration(milliseconds: 1200);
      await tester.runAsync(() async {
        await repo.setHiddenAutoLock(window);
        await repo.lockHidden();
      });
      expect(repo.hiddenUnlocked, isFalse);
      await chooseHiddenFolder(tester);
      // The prompt appears because the section was locked.
      final fields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(
        fields,
        findsWidgets,
        reason: 'locked section must ask for the password',
      );
      await tester.enterText(fields.first, 'test hidden password');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Odblokuj'));
      await tester.pumpAndSettle();
      await drainUntil(tester, () => repo.hiddenUnlocked);
      expect(repo.hiddenUnlocked, isTrue);
      final clock = Stopwatch()..start();
      await waitForRealTime(tester, clock, window * 2);
      await tester.pump(window * 2);
      expect(
        repo.hiddenUnlocked,
        isFalse,
        reason: 'unlocking from the folder must arm the same inactivity rule',
      );
    },
    skip: false,
  );
}
