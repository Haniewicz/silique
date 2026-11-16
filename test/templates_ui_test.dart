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
            onPressed: () async => onResult(
              await chooseTemplate(context, templates: templates),
            ),
            child: const Text('Open picker'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open picker'));
  await tester.pumpAndSettle();
}

Note template({required String id, required String title, String body = ''}) =>
    Note(
      id: id,
      vaultId: 'vault',
      title: title,
      body: body,
      folder: 'Szablony',
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

  testWidgets('note options menu creates a note with rendered placeholders', (
    tester,
  ) async {
    final repo = await fixture(tester);
    final vault = repo.vaults.single;
    // A template note in the `Szablony` folder.
    final tpl = (await tester.runAsync(
      () async {
        final created = await repo.createNote(vault.id, folder: 'Szablony');
        await repo.save(
          created.copyWith(
            title: 'Spotkanie',
            body: 'Tytuł: {{title}} — vault: {{vault}} — stały tekst',
          ),
        );
        return repo.notes[vault.id]![created.id]!;
      },
    ))!;
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
    await tester.tap(find.text('Nowa notatka z szablonu…'));
    await tester.pumpAndSettle();

    // The picker dialog lists the template; select it.
    expect(
      find.byKey(Key('template-${tpl.id}')),
      findsOneWidget,
      reason: 'template picker should be open with the template listed',
    );
    await tester.tap(find.byKey(Key('template-${tpl.id}')));
    // The note is created asynchronously; poll until it materialises instead of
    // relying on `pumpAndSettle`, which can race the busy flag and spinner.
    Note? created;
    await drainUntil(tester, () {
      final notes = repo.notes[vault.id]?.values ?? const <Note>[];
      created = notes
          .where(
            (n) =>
                n.id != tpl.id &&
                n.id != ordinary.id &&
                n.title == 'Spotkanie',
          )
          .firstOrNull;
      return created != null;
    });

    expect(created!.title, 'Spotkanie');
    expect(created!.body, contains('Tytuł: Spotkanie'));
    expect(created!.body, contains('vault: ${vault.name}'));
    expect(created!.body, contains('stały tekst'));
  });
}