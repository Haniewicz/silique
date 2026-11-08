import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'hidden_notes_home_test.dart' show fixture, mount, drainUntil;
import 'hidden_folder_ui_test.dart' show openHidden, seedHidden;

class DelayedImageBinding extends AutomatedTestWidgetsFlutterBinding {
  Completer<void>? decodeGate;
  int started = 0;
  int finished = 0;

  @override
  Future<ui.Codec> instantiateImageCodecWithSize(
    ui.ImmutableBuffer buffer, {
    ui.TargetImageSizeCallback? getTargetSize,
  }) async {
    started++;
    await decodeGate?.future;
    final codec = await super.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: getTargetSize,
    );
    finished++;
    return codec;
  }
}

void main() {
  final binding = DelayedImageBinding();
  testWidgets(
    'moving rendered data image to hidden evicts its former ordinary cache key',
    (tester) async {
      final repo = await fixture(tester);
      await seedHidden(tester, repo);
      final ordinary = repo.notes[repo.vaults.single.id]!.values.single;
      final png = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder)
            .drawColor(const Color(0xffd12345), ui.BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(4, 4);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        return base64Encode(data!.buffer.asUint8List());
      });
      await tester.runAsync(
        () => repo.save(
          ordinary.copyWith(
            body: '![private](data:image/png;base64,$png)\n\nParagraph',
          ),
        ),
      );
      await mount(tester, repo);
      await tester.tap(find.text('Visible secret'));
      await tester.pumpAndSettle();
      await drainUntil(
        tester,
        () => tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image != null),
      );
      final provider = tester
          .widgetList<Image>(find.byType(Image))
          .map((w) => w.image)
          .whereType<MemoryImage>()
          .single;
      expect(binding.imageCache.statusForKey(provider).keepAlive, isTrue);
      await tester.tap(find.byKey(const Key('note-options')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ukryj notatkę (hasło)'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(FilledButton),
        ),
      );
      await drainUntil(
        tester,
        () =>
            !repo.notes[ordinary.vaultId]!.containsKey(ordinary.id) &&
            find.byKey(const Key('note-title')).evaluate().isEmpty,
      );
      final status = binding.imageCache.statusForKey(provider);
      expect(
        status.keepAlive,
        isFalse,
        reason: 'the former ordinary image is now private too',
      );
      expect(status.pending, isFalse);
      expect(status.live, isFalse);
      final locking = repo.lockHidden();
      await tester.pump();
      await locking;
    },
  );
  for (final lateDecode in [false, true]) {
    for (final action in ['lock', 'departure', 'dispose']) {
      testWidgets(
        'hidden data image cache revoked on $action late=$lateDecode',
        (tester) async {
          final repo = await fixture(tester);
          final hidden = await seedHidden(tester, repo);
          if (action == 'departure') {
            await tester.runAsync(() => repo.setHiddenAutoLock(null));
          }
          final png = await tester.runAsync(() async {
            final recorder = ui.PictureRecorder();
            ui.Canvas(recorder)
                .drawColor(const Color(0xffd12345), ui.BlendMode.src);
            final picture = recorder.endRecording();
            final image = await picture.toImage(4, 4);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            image.dispose();
            picture.dispose();
            return base64Encode(data!.buffer.asUint8List());
          });
          await tester.runAsync(
            () => repo.save(
              hidden.copyWith(
                body: '![private](data:image/png;base64,$png)\n\nParagraph',
              ),
            ),
          );
          await mount(tester, repo, desktop: true);
          binding.decodeGate = lateDecode ? Completer<void>() : null;
          addTearDown(() {
            binding.decodeGate?.complete();
            binding.decodeGate = null;
          });
          final started = binding.started;
          final finished = binding.finished;
          await openHidden(tester);
          await drainUntil(tester, () => binding.started > started);
          final images = tester
              .widgetList<Image>(find.byType(Image))
              .map((w) => w.image)
              .whereType<MemoryImage>()
              .toList();
          expect(
            images,
            isNotEmpty,
            reason: 'exercise actual rendered data image',
          );
          if (!lateDecode) {
            await drainUntil(tester, () => binding.finished > finished);
            await tester.pumpAndSettle();
            await drainUntil(
              tester,
              () => find.byType(RawImage).evaluate().isNotEmpty,
            );
            expect(
              tester.widget<RawImage>(find.byType(RawImage).first).image,
              isNotNull,
            );
          }
          if (action == 'lock') {
            await tester.tap(find.byKey(const Key('hidden-lock-now')).last);
            await drainUntil(tester, () => !repo.hiddenUnlocked);
          } else if (action == 'departure') {
            await tester.tap(find.text('Wszystkie notatki'));
            await drainUntil(tester, () => !repo.hiddenUnlocked);
          } else {
            await tester.pumpWidget(const SizedBox());
            await tester.pumpAndSettle();
            await drainUntil(tester, () => !repo.hiddenUnlocked);
          }
          void expectEvicted() {
            for (final image in images) {
              final status = binding.imageCache.statusForKey(image);
              expect(status.pending, isFalse);
              expect(status.live, isFalse);
              expect(
                status.keepAlive,
                isFalse,
                reason: 'no plaintext data-image keys or pixels after $action',
              );
            }
          }

          expectEvicted();
          if (lateDecode) {
            binding.decodeGate!.complete();
            binding.decodeGate = null;
            await drainUntil(tester, () => binding.finished > finished);
            await tester.pumpAndSettle();
            expectEvicted();
          }
        },
      );
    }
  }
}
