import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';

import 'hidden_notes_home_test.dart'
    show fixture, mount, chooseHiddenFolder, drainUntil;

void main() {
  for (final hidden in [false, true]) {
    for (final source in [false, true]) {
      testWidgets(
        'visible blank tap starts IME body editing source=$source hidden=$hidden',
        (tester) async {
          final repo = await fixture(tester);
          final id = repo.vaults.single.id;
          late String noteId;
          await tester.runAsync(() async {
            if (hidden) {
              await repo.setHiddenPassword('synthetic password');
              noteId = (await repo.createHiddenNote(id)).id;
            } else {
              noteId = (await repo.createNote(id)).id;
            }
          });
          await mount(tester, repo);
          if (hidden) {
            await chooseHiddenFolder(tester);
            await drainUntil(
              tester,
              () => find.byKey(Key('note-card-$noteId')).evaluate().isNotEmpty,
            );
          }
          await tester.tap(find.byKey(Key('note-card-$noteId')));
          await tester.pumpAndSettle();
          if (source) {
            final toggle = find.byTooltip('Markdown / podgląd na żywo');
            await tester.ensureVisible(toggle);
            await tester.tap(toggle);
            await tester.pumpAndSettle();
          }
          final body = source
              ? find.byKey(const Key('source-editor'))
              : find.byType(LiveMarkdownEditor);
          final editable = find
              .descendant(of: body, matching: find.byType(EditableText))
              .first;
          final state = tester.state<EditableTextState>(editable);
          final viewport = tester.getRect(
            find.byKey(const Key('mobile-note-scroll')),
          );
          await tester.tapAt(Offset(viewport.center.dx, viewport.bottom - 70));
          await tester.pump();
          expect(state.widget.focusNode.hasFocus, isTrue);
          expect(tester.testTextInput.isVisible, isTrue);
          tester.testTextInput.updateEditingValue(
            const TextEditingValue(
              text: 'Typed immediately',
              selection: TextSelection.collapsed(offset: 17),
            ),
          );
          await tester.pump();
          expect(tester.state<EditableTextState>(editable), same(state));
          expect(state.widget.controller.text, 'Typed immediately');
          await drainUntil(
            tester,
            () => hidden
                ? repo.storage.documents('hidden:$id').isNotEmpty
                : repo.notes[id]![noteId]!.body == 'Typed immediately',
          );
          if (hidden) {
            String? storedBody;
            final stored = repo
                .hiddenNotes(id)
                .then((notes) => storedBody = notes.single.body);
            await drainUntil(tester, () => storedBody != null);
            await stored;
            expect(storedBody, 'Typed immediately');
            expect(state.widget.enableIMEPersonalizedLearning, isFalse);
            expect(state.widget.enableSuggestions, isFalse);
            expect(repo.notes[id]!.containsKey(noteId), isFalse);
            await tester.runAsync(() => repo.lockHidden());
            await tester.pumpAndSettle();
            expect(state.widget.controller.text, isEmpty);
          }
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }
  }

  for (final hidden in [false, true]) {
    testWidgets(
      'title rejects hardware and IME newlines; wraps visually hidden=$hidden',
      (tester) async {
        final repo = await fixture(tester);
        final id = repo.vaults.single.id;
        late String noteId;
        if (hidden) {
          await tester.runAsync(() async {
            await repo.setHiddenPassword('synthetic password');
            noteId = (await repo.createHiddenNote(id)).id;
          });
        } else {
          noteId = repo.notes[id]!.values.single.id;
        }
        await mount(tester, repo);
        if (hidden) {
          await chooseHiddenFolder(tester);
          await drainUntil(
            tester,
            () => find.byKey(Key('note-card-$noteId')).evaluate().isNotEmpty,
          );
        }
        await tester.tap(find.byKey(Key('note-card-$noteId')));
        await tester.pumpAndSettle();
        final title = find.byKey(const Key('note-title'));
        await tester.tapAt(tester.getCenter(title));
        await tester.pump();
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'First\nSecond\r\nThird\u2028Fourth\u2029End',
            selection: TextSelection.collapsed(offset: 30),
          ),
        );
        await tester.pump();
        final field = tester.widget<TextField>(title);
        expect(field.controller!.text, 'FirstSecondThirdFourthEnd');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(field.controller!.text, 'FirstSecondThirdFourthEnd');
        expect(field.keyboardType, TextInputType.text);
        expect(
          field.maxLines,
          isNull,
          reason: 'Long single-paragraph titles may wrap without clipping',
        );
        await tester.tapAt(tester.getCenter(title));
        await tester.pump();
        final shortHeight = tester.getSize(title).height;
        final longTitle = List.filled(
          8,
          'A long title that wraps visually',
        ).join(' ');
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: longTitle,
            selection: TextSelection.collapsed(offset: longTitle.length),
          ),
        );
        await tester.pump();
        expect(tester.getSize(title).height, greaterThan(shortHeight));
        expect(field.controller!.text, longTitle);
        if (hidden) {
          expect(field.enableIMEPersonalizedLearning, isFalse);
          expect(field.enableSuggestions, isFalse);
          expect(repo.notes[id]!.values.single.title, 'Visible secret');
        }
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
}
