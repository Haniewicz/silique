import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'hidden_notes_home_test.dart' show fixture, mount, drainUntil;
import 'editor_column_width_test.dart' show contentColumn, openNote;

/// Regression guard for the note column limit: an image wider than the 820 px
/// column must not overflow the editor pane, and its rendered slot must stay
/// within the constrained note column.
///
/// Livemd already fits media into a fixed slot (`BoxFit.scaleDown` within its
/// own max width), so a very wide frame is downscaled rather than clipped; this
/// test locks that behavior in so no future change to the column or the media
/// slot lets a wide image push past the column.
void main() {
  testWidgets('a wide embedded image stays inside the 820 px note column', (
    tester,
  ) async {
    final repo = await fixture(tester);
    final note = repo.notes[repo.vaults.single.id]!.values.single;

    // A 1600 px-wide frame is well beyond the 820 px column and livemd's 480 px
    // media slot, so it must be downscaled to fit rather than overflow.
    final widePng = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawColor(const Color(0xffd12345), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(1600, 400);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      return base64Encode(data!.buffer.asUint8List());
    });

    await tester.runAsync(
      () => repo.save(
        note.copyWith(
          body: '![wide](data:image/png;base64,$widePng)\n\nParagraph',
        ),
      ),
    );

    await mount(tester, repo, desktop: true);
    await openNote(tester, note.id);

    // Wait for the wide image to decode and paint.
    await drainUntil(
      tester,
      () => tester.widgetList<RawImage>(find.byType(RawImage)).isNotEmpty,
    );
    await tester.pumpAndSettle();

    final column = contentColumn();
    expect(column, findsOneWidget);
    final columnRect = tester.getRect(column);

    final rawImages = tester.widgetList<RawImage>(find.byType(RawImage));
    expect(rawImages, isNotEmpty, reason: 'the wide image must render');

    // Every rendered image must fit within the constrained note column.
    for (final raw in rawImages) {
      final rect = tester.getRect(find.byWidget(raw));
      expect(
        rect.width,
        lessThanOrEqualTo(columnRect.width),
        reason:
            'image width ${rect.width} must not exceed the '
            '${columnRect.width} px column',
      );
      expect(
        rect.right,
        lessThanOrEqualTo(columnRect.right),
        reason: 'image must not spill past the column right edge',
      );
    }

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
