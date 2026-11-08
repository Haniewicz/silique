import 'dart:async';

import 'package:flutter/material.dart';
import 'package:silique/ui/menus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';

import 'fixtures/image_fixtures.dart';
import 'hidden_notes_home_test.dart'
    show fixture, mount, chooseHiddenFolder, drainUntil;

void main() {
  for (final source in [false, true]) {
    for (final lock in [false, true]) {
      testWidgets(
        'late clipboard is revoked on ${lock ? 'hidden lock' : 'note switch'} source=$source',
        (tester) async {
          const channel = MethodChannel('silique.notes/clipboard');
          final gate = Completer<Map<String, Object?>>();
          var started = false;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            (call) {
              started = true;
              return gate.future;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null),
          );
          final repo = await fixture(tester);
          final id = repo.vaults.single.id;
          late String noteId;
          await tester.runAsync(() async {
            if (lock) {
              await repo.setHiddenPassword('synthetic password');
              noteId = (await repo.createHiddenNote(id)).id;
            } else {
              noteId = (await repo.createNote(id)).id;
            }
          });
          await mount(tester, repo);
          if (lock) {
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
          await tester.tapAt(
            tester.getTopLeft(editable) + const Offset(10, 10),
          );
          await tester.pump();
          final state = tester.state<EditableTextState>(editable);
          final previous = state.widget.controller;
          Actions.invoke(
            state.context,
            const PasteTextIntent(SelectionChangedCause.keyboard),
          );
          await tester.pump();
          expect(started, isTrue);
          if (lock) {
            await tester.runAsync(() => repo.lockHidden());
            await tester.pumpAndSettle();
          } else {
            await tester.tap(find.byKey(const Key('editor-back')));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Visible secret'));
            await tester.pumpAndSettle();
          }
          gate.complete({
            'media': [
              {
                'mimeType': 'image/bmp',
                'bytes': sampleBmp(width: 4, height: 4),
              },
            ],
          });
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 50));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }
          expect(
            repo.notes[id]!.values.any(
              (note) => note.body.contains('data:image'),
            ),
            isFalse,
          );
          if (lock) {
            expect(previous.text, isEmpty);
            await tester.runAsync(
              () => repo.unlockHidden('synthetic password'),
            );
            expect(
              (await tester.runAsync(() => repo.hiddenNotes(id)))!.single.body,
              isEmpty,
            );
          } else {
            expect(repo.notes[id]![noteId]!.body, isEmpty);
          }
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }
  }

  for (final hidden in [false, true]) {
    for (final source in [false, true]) {
      testWidgets(
        'explicit native image paste and IME source=$source hidden=$hidden',
        (tester) async {
          var reads = 0;
          const channel = MethodChannel('silique.notes/clipboard');
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            (call) async {
              reads++;
              expect(['read', 'readUri'], contains(call.method));
              return {
                'media': [
                  {
                    'mimeType': 'image/bmp',
                    'bytes': sampleBmp(width: 4, height: 4),
                  },
                ],
              };
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null),
          );
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
          await tester.tapAt(
            tester.getTopLeft(editable) + const Offset(10, 10),
          );
          await tester.pump();
          expect(
            reads,
            0,
            reason: 'Focus and rebuilding must not read clipboard',
          );
          final state = tester.state<EditableTextState>(editable);
          expect(state.widget.contentInsertionConfiguration, isNotNull);
          final rendered = state.widget.contextMenuBuilder!(
            state.context,
            state,
          );
          expect(rendered, isNot(isA<AdaptiveTextSelectionToolbar>()));
          final menu = state.widget.contextMenuBuilder!(
            state.context,
            state,
          ) as SiliqueSelectionToolbar;
          final paste = menu.buttonItems.singleWhere(
            (item) => item.type == ContextMenuButtonType.paste,
          );
          expect(
            reads,
            0,
            reason:
                'Building image-only paste toolbar must not inspect clipboard',
          );
          paste.onPressed!();
          final destinationPrefix = hidden
              ? 'data:image/bmp;base64,'
              : 'silique-image:';
          await drainUntil(
            tester,
            () => state.widget.controller.text.contains(destinationPrefix),
          );
          expect(reads, 1);
          final pasted = state.widget.controller.text;
          state.widget.contentInsertionConfiguration!.onContentInserted(
            KeyboardInsertedContent(
              mimeType: 'image/bmp',
              uri: 'content://ime/item',
              data: sampleBmp(width: 4, height: 4),
            ),
          );
          await drainUntil(
            tester,
            () => state.widget.controller.text.length > pasted.length,
          );
          expect(reads, 1, reason: 'IME-supplied bytes do not read clipboard');
          final beforeUri = state.widget.controller.text;
          state.widget.contentInsertionConfiguration!.onContentInserted(
            const KeyboardInsertedContent(
              mimeType: 'image/bmp',
              uri: 'content://ime/item',
            ),
          );
          await drainUntil(
            tester,
            () => state.widget.controller.text.length > beforeUri.length,
          );
          expect(
            reads,
            2,
            reason:
                'URI-only IME content uses the explicit native content route',
          );
          if (hidden) {
            String? storedBody;
            final stored = repo
                .hiddenNotes(id)
                .then((notes) => storedBody = notes.single.body);
            await drainUntil(tester, () => storedBody != null);
            await stored;
            expect(storedBody, state.widget.controller.text);
            expect(
              repo.storage.pendingImages(id),
              isEmpty,
              reason: 'Hidden images never enter ordinary attachment storage',
            );
            expect(repo.notes[id]!.containsKey(noteId), isFalse);
            expect(
              repo.storage.documents(id).values.join(),
              isNot(contains('data:image')),
            );
            await tester.runAsync(() => repo.lockHidden());
            await tester.pumpAndSettle();
            expect(state.widget.controller.text, isEmpty);
          } else {
            await drainUntil(
              tester,
              () => repo.notes[id]![noteId]!.body.contains(destinationPrefix),
            );
          }
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }
  }
}
