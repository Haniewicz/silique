import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;
import 'hidden_notes_home_test.dart' show drainUntil, mount;

/// A compact-tree fixture: folder `Alpha` holding two notes and a following
/// folder `Beta`, so the three 4 px gaps (folder→note, note→note, note→folder)
/// can all be measured on the same tree.
class SpacingFixture {
  SpacingFixture({
    required this.repo,
    required this.firstNote,
    required this.secondNote,
  });

  final Notebook repo;
  final String firstNote;
  final String secondNote;
}

Future<SpacingFixture> spacingFixture(WidgetTester tester) async {
  final dir = Directory.systemTemp.createTempSync('compact-spacing-');
  late Notebook repo;
  late String firstId, secondId;
  await tester.runAsync(() async {
    repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Phone');
    final vault = repo.vaults.single;
    await repo.createFolder(vault, 'Alpha');
    await repo.createFolder(vault, 'Beta');
    await repo.setCompactMode(vault, true);
    // Create the notes oldest-first so the newest sorts first in the list:
    // `secondId` renders above `firstId` directly under the Alpha folder.
    final first = await repo.createNote(vault.id, folder: 'Alpha');
    await repo.save(first.copyWith(title: 'Alpha first'));
    final second = await repo.createNote(vault.id, folder: 'Alpha');
    await repo.save(second.copyWith(title: 'Alpha second'));
    firstId = first.id;
    secondId = second.id;
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
  return SpacingFixture(repo: repo, firstNote: firstId, secondNote: secondId);
}

Finder noteCard(String id) => find.byKey(Key('note-card-$id'));
Finder folderRow(String path) => find.byKey(Key('folder-row-$path'));

void main() {
  testWidgets('compact tree (slivers) keeps a 4 px gap around each note', (
    tester,
  ) async {
    final fx = await spacingFixture(tester);
    await mount(tester, fx.repo, desktop: true);
    await tester.tap(find.byKey(const Key('folder-toggle-Alpha')));
    await tester.pumpAndSettle();

    final alpha = folderRow('Alpha');
    final beta = folderRow('Beta');
    final first = noteCard(fx.firstNote);
    final second = noteCard(fx.secondNote);

    expect(alpha, findsOneWidget);
    expect(beta, findsOneWidget);
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);

    final alphaRect = tester.getRect(alpha);
    final betaRect = tester.getRect(beta);
    // The newest note renders first, directly under the folder; the older one
    // follows it, so note-order by id is inverted from visual order.
    final topRect = tester.getRect(second); // newest, first under Alpha
    final bottomRect = tester.getRect(first); // older, second under Alpha

    // The two Alpha notes sit one under the other with a 4 px gap.
    expect(bottomRect.top - topRect.bottom, closeTo(4, 0.5));
    // The first (newest) Alpha note is 4 px below the Alpha folder row.
    expect(topRect.top - alphaRect.bottom, closeTo(4, 0.5));
    // The last (older) Alpha note is 4 px above the following Beta folder row.
    expect(betaRect.top - bottomRect.bottom, closeTo(4, 0.5));
    // The note card keeps its compact height.
    expect(topRect.height, closeTo(36, 1));
    expect(bottomRect.height, closeTo(36, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact tree (mobile drawer list) keeps a 4 px gap', (
    tester,
  ) async {
    final fx = await spacingFixture(tester);
    await mount(tester, fx.repo);
    await tester.tap(find.byTooltip('Foldery i vaulty'));
    await tester.pumpAndSettle();

    final drawer = find.byType(Drawer);
    Finder inDrawer(Finder f) => find.descendant(of: drawer, matching: f);

    await tester.tap(
      inDrawer(find.byKey(const Key('folder-toggle-Alpha'))),
    );
    await tester.pumpAndSettle();

    final alpha = tester.getRect(inDrawer(folderRow('Alpha')));
    final beta = tester.getRect(inDrawer(folderRow('Beta')));
    final top = tester.getRect(inDrawer(noteCard(fx.secondNote)));
    final bottom = tester.getRect(inDrawer(noteCard(fx.firstNote)));

    expect(bottom.top - top.bottom, closeTo(4, 0.5));
    expect(top.top - alpha.bottom, closeTo(4, 0.5));
    expect(beta.top - bottom.bottom, closeTo(4, 0.5));
    expect(top.height, closeTo(36, 1));
    expect(bottom.height, closeTo(36, 1));
    expect(tester.takeException(), isNull);
  });
}
