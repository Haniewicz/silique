import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/device_settings.dart';
import 'package:silique/core/templates.dart';
import 'package:silique/services/notebook.dart';

import 'hidden_notes_home_test.dart' show drainUntil, fixture, mount;

Finder folderRow(String path) => find.byKey(Key('folder-row-$path'));

/// Seeds a second folder plus a template note inside `Szablony`, so the tree
/// has both an ordinary folder and the built-in folder, and the "All notes"
/// list has a template note whose card must stay reachable when hidden.
/// Returns the id of the template note.
Future<String> seed(WidgetTester tester, Notebook repo) async {
  final vault = repo.vaults.single;
  late String templateId;
  await tester.runAsync(() async {
    await repo.createFolder(vault, 'Archiwum');
    final template = await repo.createNote(vault.id, folder: templatesFolder);
    templateId = template.id;
    await repo.save(
      template.copyWith(title: 'Meeting template', body: 'Template body'),
    );
    final archived = await repo.createNote(vault.id, folder: 'Archiwum');
    await repo.save(
      archived.copyWith(title: 'Archived note', body: 'Archived'),
    );
  });
  return templateId;
}

void main() {
  tearDown(() async {
    await deviceSettings.setHideTemplatesFolder(false);
  });

  testWidgets(
    'classic sidebar hides Szablony but keeps its notes and other folders',
    (tester) async {
      await tester.runAsync(() => deviceSettings.setHideTemplatesFolder(true));
      final repo = await fixture(tester);
      final templateId = await seed(tester, repo);

      await mount(tester, repo, desktop: true);
      // Drain the fire-and-forget `ensureTemplatesFolder` started by
      // `initState` before touching the repository in real async below.
      await drainUntil(
        tester,
        () => repo.allFolders(repo.vaults.single.id).contains(templatesFolder),
      );

      // The folder row disappears while the ordinary folder stays visible.
      expect(folderRow(templatesFolder), findsNothing);
      expect(find.text('Szablony'), findsNothing);
      expect(folderRow('Archiwum'), findsOneWidget);

      // The template note is still reachable through the "All notes" list.
      expect(find.byKey(Key('note-card-$templateId')), findsOneWidget);

      // Unhiding restores the folder row without remounting.
      await tester.runAsync(() => deviceSettings.setHideTemplatesFolder(false));
      await tester.pumpAndSettle();
      expect(folderRow(templatesFolder), findsOneWidget);
    },
  );

  testWidgets('compact tree hides Szablony and keeps other folders', (
    tester,
  ) async {
    await tester.runAsync(() => deviceSettings.setHideTemplatesFolder(true));
    final repo = await fixture(tester);
    final vault = repo.vaults.single;
    await seed(tester, repo);
    await tester.runAsync(() => repo.setCompactMode(vault, true));

    await mount(tester, repo, desktop: true);
    await drainUntil(
      tester,
      () => repo.allFolders(vault.id).contains(templatesFolder),
    );

    expect(folderRow(templatesFolder), findsNothing);
    expect(find.text('Szablony'), findsNothing);
    expect(folderRow('Archiwum'), findsOneWidget);

    await tester.runAsync(() => deviceSettings.setHideTemplatesFolder(false));
    await tester.pumpAndSettle();
    expect(folderRow(templatesFolder), findsOneWidget);
  });
}
