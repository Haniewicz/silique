import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/device_settings.dart';
import 'package:silique/core/models.dart';

import 'hidden_notes_home_test.dart' show drainUntil, fixture, mount;

void main() {
  tearDown(() async {
    // Reset the process-wide defaults so one test's choice never leaks into the
    // next (the singleton never wrote to disk because it was not initialized).
    await deviceSettings.setJournalTemplateId(null);
    await deviceSettings.setNoteTemplateId(null);
  });

  testWidgets('configured journal template fills a new entry silently', (
    tester,
  ) async {
    final repo = await fixture(tester);
    final vault = repo.vaults.single;
    final tpl = (await tester.runAsync(() async {
      final created = await repo.createNote(vault.id, folder: 'Szablony');
      await repo.save(
        created.copyWith(
          title: 'Dziennik',
          body: 'Szablon: {{title}} — {{vault}}',
        ),
      );
      return repo.notes[vault.id]![created.id]!;
    }))!;
    await tester.runAsync(() => deviceSettings.setJournalTemplateId(tpl.id));

    await mount(tester, repo, desktop: true);
    await tester.tap(find.byKey(const Key('new-journal-entry')));
    await tester.pumpAndSettle();

    Note? entry;
    await drainUntil(tester, () {
      final notes = repo.notes[vault.id]?.values ?? const <Note>[];
      entry = notes
          .where((n) => n.journalDate != null && n.body.contains('Szablon:'))
          .firstOrNull;
      return entry != null;
    });

    expect(entry!.journalDate, isNotNull);
    expect(entry!.body, contains('Szablon: Dziennik'));
    expect(entry!.body, contains('— ${vault.name}'));
  });

  testWidgets('missing template degrades to an empty entry with no error', (
    tester,
  ) async {
    final repo = await fixture(tester);
    final vault = repo.vaults.single;
    // Point the default at a template id that does not exist.
    await tester.runAsync(
      () => deviceSettings.setJournalTemplateId('missing-template-id'),
    );

    await mount(tester, repo, desktop: true);
    await tester.tap(find.byKey(const Key('new-journal-entry')));
    await tester.pumpAndSettle();

    Note? entry;
    await drainUntil(tester, () {
      final notes = repo.notes[vault.id]?.values ?? const <Note>[];
      entry = notes.where((n) => n.journalDate != null).firstOrNull;
      return entry != null;
    });

    expect(entry!.journalDate, isNotNull);
    // The ordinary empty journal body, not the (missing) template's content.
    expect(entry!.body, isNot(contains('Szablon:')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('configured note template fills a new ordinary note silently', (
    tester,
  ) async {
    final repo = await fixture(tester);
    final vault = repo.vaults.single;
    final tpl = (await tester.runAsync(() async {
      final created = await repo.createNote(vault.id, folder: 'Szablony');
      await repo.save(
        created.copyWith(
          title: 'Spotkanie',
          body: 'Szablon: {{title}} — {{vault}}',
        ),
      );
      return repo.notes[vault.id]![created.id]!;
    }))!;
    await tester.runAsync(() => deviceSettings.setNoteTemplateId(tpl.id));

    await mount(tester, repo, desktop: true);
    await tester.tap(find.byKey(const Key('new-note-button')));
    await tester.pumpAndSettle();

    Note? note;
    await drainUntil(tester, () {
      final notes = repo.notes[vault.id]?.values ?? const <Note>[];
      note = notes
          .where((n) => n.folder == '' && n.title == 'Spotkanie')
          .firstOrNull;
      return note != null;
    });

    expect(note!.journalDate, isNull);
    expect(note!.title, 'Spotkanie');
    expect(note!.body, contains('Szablon: Spotkanie'));
    expect(note!.body, contains('— ${vault.name}'));
    expect(
      note!.folder,
      '',
      reason: 'a filled ordinary note keeps the current folder, not Szablony',
    );
  });
}
