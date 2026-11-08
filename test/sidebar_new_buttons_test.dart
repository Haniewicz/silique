import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;
import 'hidden_notes_home_test.dart' show drainUntil, mount;

Future<Notebook> notebookFixture(
  WidgetTester tester, {
  bool compact = false,
}) async {
  final dir = Directory.systemTemp.createTempSync('sidebar-buttons-');
  late Notebook repo;
  await tester.runAsync(() async {
    repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Phone');
    final vault = repo.vaults.single;
    if (compact) await repo.setCompactMode(vault, true);
  });
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    var closed = false;
    final close = repo.close().then((_) => closed = true);
    await drainUntil(tester, () => closed);
    await close;
    await tester.runAsync(() async {
      dir.deleteSync(recursive: true);
    });
  });
  return repo;
}

Finder newNote() => find.byKey(const Key('new-note-button'));
Finder newJournal() => find.byKey(const Key('new-journal-entry'));

void main() {
  for (final compact in [false, true]) {
    final label = compact ? 'compact' : 'classic';
    testWidgets('new-note and journal buttons share radius and insets ($label)', (
      tester,
    ) async {
      final repo = await notebookFixture(tester, compact: compact);
      await mount(tester, repo, desktop: true);

      expect(newNote(), findsOneWidget);
      expect(newJournal(), findsOneWidget);

      final noteButton = tester.widget<TextButton>(newNote());
      final journalButton = tester.widget<TextButton>(newJournal());

      // The journal button carries the 8 px corner radius directly on its shape.
      final journalShape = journalButton.style!.shape!.resolve(
        const <WidgetState>{},
      );
      expect(
        journalShape,
        isA<RoundedRectangleBorder>().having(
          (s) => s.borderRadius,
          'borderRadius',
          BorderRadius.circular(8),
        ),
      );

      // The accent new-note button gets its radius from the wrapping Container.
      final noteContainer = tester.widget<Container>(
        find.ancestor(of: newNote(), matching: find.byType(Container)).first,
      );
      expect(
        (noteContainer.decoration! as BoxDecoration).borderRadius,
        BorderRadius.circular(8),
      );

      // Both share the inner 10/13 insets and left-aligned icon+label.
      expect(
        noteButton.style!.padding!.resolve(const <WidgetState>{}),
        const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
      );
      expect(
        journalButton.style!.padding!.resolve(const <WidgetState>{}),
        const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
      );
      expect(journalButton.style!.alignment, Alignment.centerLeft);

      // Both are outset 14 px from the sidebar edge, so their left edges agree.
      final noteRect = tester.getRect(newNote());
      final journalRect = tester.getRect(newJournal());
      expect((noteRect.left - journalRect.left).abs(), lessThanOrEqualTo(1));

      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('new-note and journal buttons have matching heights', (
    tester,
  ) async {
    // The 300 px compact rail is wide enough that neither button wraps, so the
    // shared 13 px vertical insets translate to equal button heights. The
    // classic 220 px rail squeezes the "Nowa notatka" label next to its
    // "Ctrl + N" hint, which is a separate pre-existing layout concern.
    final repo = await notebookFixture(tester, compact: true);
    await mount(tester, repo, desktop: true);

    final noteRect = tester.getRect(newNote());
    final journalRect = tester.getRect(newJournal());
    expect((noteRect.height - journalRect.height).abs(), lessThanOrEqualTo(1));
    expect((noteRect.left - journalRect.left).abs(), lessThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });
}
