import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:silique/ui/menus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';
import 'package:silique/storage/native_storage.dart';

import 'hidden_notes_home_test.dart' show fixture, mount, drainUntil;
import 'hidden_folder_ui_test.dart' show seedHidden, openHidden;

void main() {
  for (final mode in ['live', 'source', 'table', 'callout']) {
    for (final failMove in [false, true]) {
      testWidgets(
        'reveal freezes $mode editing before draining writes and moving failure=$failMove',
        (tester) async {
          final repo = await fixture(tester);
          final hidden = await seedHidden(tester, repo);
          await tester.runAsync(() => repo.setHiddenAutoLock(null));
          final body = switch (mode) {
            'table' => '| Private cell | Other |\n| --- | --- |\n| Secret | Value |\n\nParagraph',
            'callout' =>
              '> [!NOTE] Private callout\n> Private content\n\nParagraph',
            _ => 'Private body before reveal',
          };
          await tester.runAsync(() => repo.save(hidden.copyWith(body: body)));
          await mount(tester, repo, desktop: true);
          await openHidden(tester);
          if (mode == 'source') {
            await tester.tap(find.byTooltip('Markdown / podgląd na żywo'));
            await tester.pumpAndSettle();
          } else if (mode == 'table' || mode == 'callout') {
            await tester.tap(
              mode == 'table'
                  ? find.byKey(const ValueKey('table-cell-0-2-0'))
                  : find.text('Private content', findRichText: true),
            );
            await tester.pumpAndSettle();
            expect(
              tester.widgetList<EditableText>(find.byType(EditableText)).length,
              greaterThan(3),
            );
          }
          await tester.enterText(
            find.byKey(const Key('note-title')),
            'Saved before reveal',
          );
          if (failMove) {
            (repo.storage as NativeStorage).db.execute(
              "CREATE TRIGGER fail_reveal BEFORE INSERT ON documents WHEN NEW.vault_id NOT LIKE 'hidden:%' BEGIN SELECT RAISE(ABORT, 'simulated reveal failure'); END",
            );
            addTearDown(
              () => (repo.storage as NativeStorage).db.execute(
                'DROP TRIGGER fail_reveal',
              ),
            );
          }
          final gate = Completer<void>();
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          var blocked = false;
          final barrier = repo.serialized(() async {
            blocked = true;
            await gate.future;
          });
          await drainUntil(tester, () => blocked);
          await tester.ensureVisible(find.byKey(const Key('note-options')));
          await tester.tap(find.byKey(const Key('note-options')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Przenieś do folderu'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('folder-target-confirm')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          try {
            final title = tester.widget<TextField>(
              find.byKey(const Key('note-title')),
            );
            expect(
              title.readOnly,
              isTrue,
              reason: 'freeze synchronously before async move',
            );
            final editorFields = tester
                .widgetList<EditableText>(
                  find.descendant(
                    of: find.byType(LiveMarkdownEditor),
                    matching: find.byType(EditableText, skipOffstage: false),
                    skipOffstage: false,
                  ),
                )
                .toList();
            if (mode == 'table' || mode == 'callout') {
              expect(editorFields.length, greaterThan(1));
            }
            for (final field in editorFields) {
              expect(
                field.readOnly,
                isTrue,
                reason: 'main and embedded fields freeze',
              );
            }
            if (mode == 'source') {
              expect(
                tester
                    .widget<TextField>(find.byKey(const Key('source-editor')))
                    .readOnly,
                isTrue,
              );
            }
            // Even stale controller/formatting callbacks cannot queue a hidden save
            // behind the move or alter the frozen snapshot.
            title.controller!.text = 'Late rejected title';
            for (final field in editorFields.skip(1)) {
              field.controller.text = 'Late rejected embedded';
            }
            if (mode == 'source') {
              tester
                      .widget<TextField>(find.byKey(const Key('source-editor')))
                      .controller!
                      .text =
                  'Late rejected body';
            } else {
              tester
                      .widget<LiveMarkdownEditor>(
                        find.byType(LiveMarkdownEditor),
                      )
                      .controller
                      .text =
                  'Late rejected body';
            }
            await tester.pump();
          } finally {
            gate.complete();
          }
          await barrier;
          if (failMove) {
            await drainUntil(
              tester,
              () =>
                  find.byKey(const Key('note-title')).evaluate().isNotEmpty &&
                  !tester
                      .widget<TextField>(find.byKey(const Key('note-title')))
                      .readOnly,
            );
            expect(repo.hiddenUnlocked, isTrue);
            expect(repo.notes[hidden.vaultId]!.containsKey(hidden.id), isFalse);
            expect(
              tester
                  .widget<TextField>(find.byKey(const Key('note-title')))
                  .controller!
                  .text,
              'Saved before reveal',
            );
            await tester.enterText(
              find.byKey(const Key('note-title')),
              'Editable after failed reveal',
            );
            var read = false;
            final reading = repo.hiddenNotes(hidden.vaultId);
            unawaited(reading.then((_) => read = true));
            await drainUntil(tester, () => read);
            final saved = (await reading).single;
            expect(saved.title, 'Editable after failed reveal');
            expect(saved.body, body);
            if (mode == 'source') {
              expect(
                tester
                    .widget<TextField>(find.byKey(const Key('source-editor')))
                    .readOnly,
                isFalse,
              );
            } else {
              for (final field in tester.widgetList<EditableText>(
                find.descendant(
                  of: find.byType(LiveMarkdownEditor),
                  matching: find.byType(EditableText),
                ),
              )) {
                expect(field.readOnly, isFalse);
              }
            }
            await tester.tap(find.byKey(const Key('hidden-lock-now')).last);
            await drainUntil(tester, () => !repo.hiddenUnlocked);
            return;
          }
          await drainUntil(
            tester,
            () =>
                !repo.hiddenUnlocked &&
                repo.notes[hidden.vaultId]!.containsKey(hidden.id),
          );
          final ordinary = repo.notes[hidden.vaultId]![hidden.id]!;
          expect(ordinary.title, 'Saved before reveal');
          expect(ordinary.body, body);
          expect(repo.storage.documents('hidden:${hidden.vaultId}'), isEmpty);
          expect(find.textContaining('Nie udało się zapisać'), findsNothing);
        },
      );
    }
  }
  testWidgets(
    'ordinary folder context creation leaves hidden namespace before editing',
    (tester) async {
      final repo = await fixture(tester);
      final hidden = await seedHidden(tester, repo);
      await tester.runAsync(() => repo.setHiddenAutoLock(null));
      await tester.runAsync(
        () => repo.createFolder(repo.vaults.single, 'Work'),
      );
      await mount(tester, repo, desktop: true);
      await openHidden(tester);
      await tester.tap(find.text('Work'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SiliqueMenuRow, 'Nowa notatka'));
      await drainUntil(
        tester,
        () =>
            repo.notes[hidden.vaultId]!.length == 2 &&
            find.byKey(const Key('note-title')).evaluate().isNotEmpty,
      );
      expect(
        repo.hiddenUnlocked,
        isFalse,
        reason: 'ordinary folder actions leave and lock hidden',
      );
      await tester.enterText(
        find.byKey(const Key('note-title')),
        'Ordinary folder title',
      );
      tester
              .widget<LiveMarkdownEditor>(find.byType(LiveMarkdownEditor))
              .controller
              .text =
          'Ordinary folder body';
      await drainUntil(
        tester,
        () => repo.notes[hidden.vaultId]!.values.any(
          (n) => n.body == 'Ordinary folder body',
        ),
      );
      final note = repo.notes[hidden.vaultId]!.values.singleWhere(
        (n) => n.title == 'Ordinary folder title',
      );
      expect(note.folder, 'Work');
      expect(note.hidden, isFalse);
      expect(repo.storage.documents(hidden.vaultId), hasLength(2));
      expect(repo.storage.documents('hidden:${hidden.vaultId}'), hasLength(1));
      var unlocked = false;
      final unlocking = repo
          .unlockHidden('test hidden password')
          .then((_) => unlocked = true);
      await drainUntil(tester, () => unlocked);
      await unlocking;
      var read = false;
      final reading = repo.hiddenNotes(hidden.vaultId);
      unawaited(reading.then((_) => read = true));
      await drainUntil(tester, () => read);
      expect((await reading).single.body, hidden.body);
      final locking = repo.lockHidden();
      await tester.pump();
      await locking;
    },
  );
}
