import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';
import 'package:silique/ui/menus.dart';

import 'hidden_notes_home_test.dart' show fixture, mount, drainUntil;
import 'hidden_folder_ui_test.dart'
    show seedHidden, openHidden, expectHistoryForgotten;

void main() {
  for (final targetKind in ['wiki', 'hidden id', 'ordinary id']) {
    testWidgets(
      'native hidden link opening stays in hidden namespace target=$targetKind',
      (tester) async {
        final repo = await fixture(tester);
        final hidden = await seedHidden(tester, repo);
        await tester.runAsync(() async {
          await repo.setHiddenAutoLock(null);
          var body = '[[Private target]]';
          if (targetKind == 'hidden id') {
            final target = await repo.createHiddenNote(hidden.vaultId);
            await repo.save(
              target.copyWith(title: 'Linked hidden', body: 'Linked secret'),
            );
            body = '[Private target](silique-note:${target.id})';
          } else if (targetKind == 'ordinary id') {
            final target = repo.notes[hidden.vaultId]!.values.single;
            body = '[Private target](silique-note:${target.id})';
          }
          await repo.save(hidden.copyWith(body: body));
        });
        await mount(tester, repo, desktop: true);
        await openHidden(tester);
        final field = find
            .descendant(
              of: find.byType(LiveMarkdownEditor),
              matching: find.byType(EditableText),
            )
            .first;
        final editable = tester.state<EditableTextState>(field);
        final source = editable.widget.controller.text;
        final start = source.indexOf('Private target');
        final box = editable.renderEditable
            .getBoxesForSelection(
              TextSelection(baseOffset: start, extentOffset: start + 7),
            )
            .first;
        await tester.tapAt(
          editable.renderEditable.localToGlobal(box.toRect().center),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        final expected = switch (targetKind) {
          'wiki' => 'Private target',
          'hidden id' => 'Linked hidden',
          _ => 'Private title',
        };
        await drainUntil(
          tester,
          () =>
              tester
                  .widget<TextField>(find.byKey(const Key('note-title')))
                  .controller!
                  .text ==
              expected,
        );
        expect(
          repo.notes[hidden.vaultId]!.values.single.title,
          'Visible secret',
        );
        expect(repo.storage.documents(hidden.vaultId), hasLength(1));
        expect(
          repo.storage.documents('hidden:${hidden.vaultId}'),
          hasLength(targetKind == 'ordinary id' ? 1 : 2),
        );
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      }),
    );
  }

  for (final hidden in [false, true]) {
    for (final source in [false, true]) {
      testWidgets(
        'actual Home desktop menu source=$source hidden=$hidden retains history and privacy',
        (tester) async {
          final repo = await fixture(tester);
          if (hidden) {
            await seedHidden(tester, repo);
            await tester.runAsync(() => repo.setHiddenAutoLock(null));
          }
          await mount(tester, repo, desktop: true);
          if (hidden) {
            await openHidden(tester);
          } else {
            final id = repo.notes[repo.vaults.single.id]!.values.single.id;
            await tester.tap(find.byKey(Key('note-card-$id')));
            await tester.pumpAndSettle();
          }
          final document = tester
              .widget<LiveMarkdownEditor>(find.byType(LiveMarkdownEditor))
              .controller;
          if (source) {
            await tester.tap(find.byTooltip('Markdown / podgląd na żywo'));
            await tester.pumpAndSettle();
          }
          final body = source
              ? find.byKey(const Key('source-editor'))
              : find.byType(LiveMarkdownEditor);
          final finder = find
              .descendant(of: body, matching: find.byType(EditableText))
              .first;
          await tester.tapAt(tester.getTopLeft(finder) + const Offset(8, 8));
          await tester.pumpAndSettle();
          final editable = tester.state<EditableTextState>(finder);
          final editing = editable.widget.controller;
          if (hidden) {
            expect(editable.widget.enableSuggestions, isFalse);
            expect(editable.widget.enableIMEPersonalizedLearning, isFalse);
          }
          final original = document.text;
          editable.userUpdateTextEditingValue(
            editing.value.copyWith(
              selection: const TextSelection(baseOffset: 0, extentOffset: 7),
            ),
            SelectionChangedCause.keyboard,
          );
          await tester.pump();
          final box = editable.renderEditable
              .getBoxesForSelection(
                const TextSelection(baseOffset: 0, extentOffset: 7),
              )
              .first;
          await tester.tapAt(
            editable.renderEditable.localToGlobal(box.toRect().center),
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          final menu = tester.widget<SiliqueSelectionToolbar>(
            find.byType(SiliqueSelectionToolbar),
          );
          expect(menu.buttonItems.length, 7);
          expect(
            menu.buttonItems
                .map((item) => item.label ?? item.type.name)
                .toList(),
            ['Cofnij', 'Ponów', 'cut', 'copy', 'paste', 'Usuń', 'selectAll'],
          );
          expect(menu.buttonItems[5].onPressed, isNotNull);
          menu.buttonItems[5].onPressed!();
          await tester.pumpAndSettle();
          expect(document.text, original.substring(7));
          final undo = (markdownPasteContextMenu(
            editable.context,
            editable,
          ) as SiliqueSelectionToolbar).buttonItems[0];
          expect(undo.onPressed, isNotNull);
          undo.onPressed!();
          await tester.pumpAndSettle();
          expect(document.text, original);
          expect(editing.text, original);
          if (hidden) {
            await tester.runAsync(() => repo.lockHidden());
            await tester.pumpAndSettle();
            expect(editing.text, isEmpty);
            expectHistoryForgotten(document);
            undo.onPressed!();
            menu.buttonItems[5].onPressed!();
            await tester.pump();
            expect(editing.text, isEmpty);
            expectHistoryForgotten(document);
          }
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({
          TargetPlatform.linux,
          TargetPlatform.macOS,
          TargetPlatform.windows,
        }),
      );
    }
  }
}
