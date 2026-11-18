import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/models.dart';
import 'package:silique/l10n/app_language.dart';
import 'package:silique/services/notebook.dart';

import 'hidden_notes_home_test.dart' show drainUntil, fixture, mount;

/// Switches the UI to English (the tests assert English labels) and builds the
/// standard single-vault fixture. Notes are seeded before [mount] so the home
/// tree is built from the complete repository state.
Future<Notebook> prepare(WidgetTester tester) async {
  await tester.runAsync(() => appLanguage.setLanguage('en'));
  return fixture(tester);
}

/// Creates a note and returns its stored instance. `folder: 'Szablony'` makes
/// it a template; the default `''` is an ordinary note at the vault root.
Future<Note> seedNote(
  WidgetTester tester,
  Notebook repo, {
  required String title,
  required String body,
  String folder = '',
}) async {
  final vault = repo.vaults.single;
  final created = await tester.runAsync(
    () => repo.createNote(vault.id, folder: folder),
  );
  final note = created!.copyWith(title: title, body: body);
  await tester.runAsync(() => repo.save(note));
  return note;
}

/// Opens the note's context menu and applies [templateId] through the picker.
Future<void> applyTemplate(
  WidgetTester tester,
  String noteId,
  String templateId,
) async {
  await tester.tap(
    find.byKey(Key('note-card-$noteId')),
    buttons: kSecondaryMouseButton,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Apply template…'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('template-$templateId')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('applying a template to an empty note sets title and body', (
    tester,
  ) async {
    final repo = await prepare(tester);
    final vault = repo.vaults.single;
    final tpl = await seedNote(
      tester,
      repo,
      title: 'Spotkanie',
      body: 'Szablon {{title}} — {{vault}}',
      folder: 'Szablony',
    );
    final note = await seedNote(tester, repo, title: 'Untitled', body: '');

    await mount(tester, repo, desktop: true);
    await applyTemplate(tester, note.id, tpl.id);
    await drainUntil(tester, () {
      final n = repo.notes[vault.id]![note.id]!;
      return n.body.contains('Szablon Spotkanie');
    });

    final updated = repo.notes[vault.id]![note.id]!;
    expect(updated.title, 'Spotkanie');
    expect(updated.body, 'Szablon Spotkanie — ${vault.name}');
  });

  testWidgets(
    'applying a template to a note with content appends without losing text',
    (tester) async {
      final repo = await prepare(tester);
      final vault = repo.vaults.single;
      final tpl = await seedNote(
        tester,
        repo,
        title: 'Spotkanie',
        body: 'Szablon {{title}}',
        folder: 'Szablony',
      );
      final note = await seedNote(
        tester,
        repo,
        title: 'Moja notatka',
        body: 'aaa',
      );

      await mount(tester, repo, desktop: true);
      await applyTemplate(tester, note.id, tpl.id);
      await drainUntil(tester, () {
        final n = repo.notes[vault.id]![note.id]!;
        return n.body.startsWith('aaa\n\n');
      });

      final updated = repo.notes[vault.id]![note.id]!;
      expect(updated.title, 'Moja notatka');
      expect(updated.body, 'aaa\n\nSzablon Moja notatka');
    },
  );

  testWidgets(
    'applying a template from the list context menu updates a non-open note',
    (tester) async {
      final repo = await prepare(tester);
      final vault = repo.vaults.single;
      final tpl = await seedNote(
        tester,
        repo,
        title: 'Szablon',
        body: 'Treść szablonu',
        folder: 'Szablony',
      );
      final note = await seedNote(tester, repo, title: 'Untitled', body: '');

      await mount(tester, repo, desktop: true);
      await applyTemplate(tester, note.id, tpl.id);
      await drainUntil(tester, () {
        final n = repo.notes[vault.id]![note.id]!;
        return n.title == 'Szablon';
      });

      // Product contract for a note that is not open: the template lands in the
      // stored note (title plus rendered body) without opening it. The list row
      // is refreshed by the same setState, but that rebuild is driven by a
      // real-async continuation the fake test clock cannot order reliably, so
      // the card text itself is not asserted here.
      final applied = repo.notes[vault.id]![note.id]!;
      expect(applied.title, 'Szablon');
      expect(applied.body, 'Treść szablonu');
    },
  );

  testWidgets('template menu is hidden for trashed notes', (tester) async {
    final repo = await prepare(tester);
    final vault = repo.vaults.single;
    await seedNote(
      tester,
      repo,
      title: 'Spotkanie',
      body: 'x',
      folder: 'Szablony',
    );
    final note = await seedNote(
      tester,
      repo,
      title: 'Moja notatka',
      body: 'aaa',
    );
    await tester.runAsync(() async {
      final n = repo.notes[vault.id]![note.id]!;
      await repo.save(n.copyWith(deleted: true));
    });

    await mount(tester, repo, desktop: true);
    await tester.tap(find.text('Deleted'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(Key('note-card-${note.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('Apply template…'), findsNothing);
    expect(find.text('Restore from trash'), findsOneWidget);
  });

  testWidgets('cancelling the template picker leaves the note untouched', (
    tester,
  ) async {
    final repo = await prepare(tester);
    final vault = repo.vaults.single;
    await seedNote(
      tester,
      repo,
      title: 'Spotkanie',
      body: 'x',
      folder: 'Szablony',
    );
    final note = await seedNote(
      tester,
      repo,
      title: 'Moja notatka',
      body: 'aaa',
    );

    await mount(tester, repo, desktop: true);
    final before = repo.notes[vault.id]![note.id]!;

    await tester.tap(
      find.byKey(Key('note-card-${note.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply template…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    final after = repo.notes[vault.id]![note.id]!;
    expect(after.title, before.title);
    expect(after.body, before.body);
  });

  testWidgets(
    'an empty template folder shows the hint and leaves the note untouched',
    (tester) async {
      final repo = await prepare(tester);
      final vault = repo.vaults.single;
      final note = await seedNote(
        tester,
        repo,
        title: 'Moja notatka',
        body: 'aaa',
      );

      await mount(tester, repo, desktop: true);
      final before = repo.notes[vault.id]![note.id]!;

      await tester.tap(
        find.byKey(Key('note-card-${note.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply template…'));
      await tester.pumpAndSettle();

      expect(
        find.text('Create a note in the Templates folder to add a template.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      final after = repo.notes[vault.id]![note.id]!;
      expect(after.title, before.title);
      expect(after.body, before.body);
    },
  );
}
