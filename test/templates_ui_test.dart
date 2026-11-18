import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/models.dart';
import 'package:silique/ui/dialogs.dart';
import 'package:silique/ui/theme.dart';

import 'hidden_notes_home_test.dart' show drainUntil, fixture, mount;

/// Mounts a bare [chooseTemplate] picker and returns it so a test can interact
/// with the dialog.
Future<void> openPicker(
  WidgetTester tester,
  ValueChanged<Note?> onResult, {
  required List<Note> templates,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: siliqueTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                onResult(await chooseTemplate(context, templates: templates)),
            child: const Text('Open picker'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open picker'));
  await tester.pumpAndSettle();
}

Note template({
  required String id,
  required String title,
  String body = '',
  String folder = 'Szablony',
}) => Note(
  id: id,
  vaultId: 'vault',
  title: title,
  body: body,
  folder: folder,
  updatedAt: DateTime(2026, 1, 1),
);

void main() {
  testWidgets('picker lists templates and returns the chosen one', (
    tester,
  ) async {
    Note? result;
    await openPicker(
      tester,
      (value) => result = value,
      templates: [
        template(id: 'a', title: 'Spotkanie'),
        template(id: 'b', title: 'Dziennik'),
      ],
    );
    expect(find.text('Spotkanie'), findsOneWidget);
    expect(find.text('Dziennik'), findsOneWidget);
    await tester.tap(find.byKey(const Key('template-b')));
    await tester.pumpAndSettle();
    expect(result?.id, 'b');
  });

  testWidgets('picker lists a subfolder template with its relative path', (
    tester,
  ) async {
    Note? result;
    await openPicker(
      tester,
      (value) => result = value,
      templates: [
        template(id: 'a', title: 'Spotkanie'),
        template(id: 'b', title: 'Codzienny', folder: 'Szablony/Spotkania'),
      ],
    );
    expect(find.text('Spotkanie'), findsOneWidget);
    expect(find.text('Codzienny'), findsOneWidget);
    // The subfolder path is shown as a subtitle, without changing the title.
    expect(find.text('Spotkania'), findsOneWidget);
    await tester.tap(find.byKey(const Key('template-b')));
    await tester.pumpAndSettle();
    expect(result?.id, 'b');
  });

  testWidgets('empty template list shows the hint', (tester) async {
    Note? result;
    await openPicker(tester, (value) => result = value, templates: const []);
    expect(
      find.text('Utwórz notatkę w folderze Szablony, aby dodać szablon.'),
      findsOneWidget,
    );
    expect(find.byType(ListTile), findsNothing);
    // Closing without a selection yields null.
    await tester.tap(find.text('Anuluj'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets('note options menu no longer offers creating from a template', (
    tester,
  ) async {
    final repo = await fixture(tester);
    final vault = repo.vaults.single;
    // A template note in the `Szablony` folder, still picked up by `templatesOf`
    // for the "Apply template…" flow.
    await tester.runAsync(() async {
      final created = await repo.createNote(vault.id, folder: 'Szablony');
      await repo.save(
        created.copyWith(
          title: 'Spotkanie',
          body: 'Tytuł: {{title}} — vault: {{vault}} — stały tekst',
        ),
      );
    });
    // An ordinary note to open so the toolbar note-options menu is available.
    final ordinary = repo.notes[vault.id]!.values.firstWhere(
      (n) => n.folder != 'Szablony',
    );

    await mount(tester, repo, desktop: true);
    await tester.tap(find.byKey(Key('note-card-${ordinary.id}')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('note-options')));
    await tester.tap(find.byKey(const Key('note-options')));
    await tester.pumpAndSettle();

    // Creating a note from a template was removed in 0.2.59 and replaced by
    // "Apply template…" on an existing note (covered by apply_template_test.dart
    // and the note-options test below), so this only asserts the old entry is
    // gone, not that the menu is template-free.
    expect(find.text('Nowa notatka z szablonu…'), findsNothing);
  });

  testWidgets('note options applies a template to the open note', (
    tester,
  ) async {
    final repo = await fixture(tester);
    final vault = repo.vaults.single;
    late final String templateId;
    await tester.runAsync(() async {
      final created = await repo.createNote(vault.id, folder: 'Szablony');
      templateId = created.id;
      await repo.save(
        created.copyWith(
          title: 'Spotkanie',
          body: 'Szablon {{title}} — {{vault}}',
        ),
      );
    });
    // The ordinary note seeded by `fixture` (title "Visible secret", non-empty
    // body), to open so the toolbar note-options menu is available.
    final ordinary = repo.notes[vault.id]!.values.firstWhere(
      (n) => n.folder != 'Szablony',
    );
    final noteCountBefore = repo.notes[vault.id]!.length;

    await mount(tester, repo, desktop: true);
    // Drain the fire-and-forget `ensureTemplatesFolder` started by `initState`
    // before touching the repository in real async below.
    await drainUntil(
      tester,
      () => repo.allFolders(vault.id).contains('Szablony'),
    );

    await tester.tap(find.byKey(Key('note-card-${ordinary.id}')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('note-options')));
    await tester.tap(find.byKey(const Key('note-options')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zastosuj szablon…'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('template-$templateId')));
    await tester.pumpAndSettle();

    await drainUntil(tester, () {
      final n = repo.notes[vault.id]![ordinary.id]!;
      return n.body.contains('Szablon');
    });

    final updated = repo.notes[vault.id]![ordinary.id]!;
    // The open note received the rendered template content…
    expect(updated.body, contains('Szablon ${ordinary.title}'));
    // …and no extra note was created.
    expect(repo.notes[vault.id]!.length, noteCountBefore);
  });
}
