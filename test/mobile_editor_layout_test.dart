import 'dart:io';

import 'package:flutter/gestures.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/main.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

class MobileStorage extends NativeStorage {
  MobileStorage(super.root);
  @override
  Future<void> mirror(Note note) async {}
}

Future<Notebook> openPhone(WidgetTester tester, {bool long = false}) async {
  final dir = Directory.systemTemp.createTempSync('silique-mobile-layout-');
  late Notebook repo;
  await tester.runAsync(() async {
    repo = Notebook(
      storage: MobileStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Phone');
    final note = await repo.createNote(repo.vaults.single.id);
    await repo.save(
      note.copyWith(
        title: 'Stable heading',
        tags: ['stable'],
        body: long
            ? List.generate(90, (i) => 'Line $i words for selection').join('\n')
            : 'Short body',
      ),
    );
  });
  addTearDown(
    () => tester.runAsync(() async {
      await repo.storage.close();
      dir.deleteSync(recursive: true);
    }),
  );
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [notebookProvider.overrideWithValue(repo)],
      child: const SiliqueApp(),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Stable heading'));
  await tester.pumpAndSettle();
  return repo;
}

/// The phone document viewport that owns the note offset. The editor field is
/// content-sized, so it must not own scrolling itself.
ScrollPosition documentPosition(WidgetTester tester) => tester
    .stateList<ScrollableState>(find.byType(Scrollable))
    .map((s) => s.position)
    .firstWhere(
      (p) =>
          axisDirectionToAxis(p.axisDirection) == Axis.vertical &&
          p.hasContentDimensions &&
          p.maxScrollExtent > 500,
    );

void main() {
  for (final upwards in [false, true]) {
    testWidgets(
      'phone live selection edge scrolls ${upwards ? 'up' : 'down'} while held',
      (tester) async {
        await openPhone(tester, long: true);
        final field = find.byKey(const ValueKey('livemd-document-field'));
        final widget = tester.widget<TextField>(field);
        final viewport = field;
        ScrollController scroll() =>
            Scrollable.of(tester.element(field)).widget.controller!;
        if (upwards) {
          scroll().jumpTo(900);
          await tester.pumpAndSettle();
        }
        final rect = tester.getRect(viewport);
        if (!upwards) {
          // A downward pull that starts at the top belongs to dismissal, not
          // selection; select while already reading inside the note.
          tester
              .widget<SingleChildScrollView>(
                find.byKey(const Key('mobile-note-scroll')),
              )
              .controller!
              .jumpTo(200);
          await tester.pumpAndSettle();
        }
        final gesture = await tester.startGesture(Offset(rect.left + 65, 400));
        await tester.pump(
          kLongPressTimeout + const Duration(milliseconds: 100),
        );
        expect(widget.controller!.selection.isCollapsed, isFalse);
        await gesture.moveTo(Offset(rect.left + 90, upwards ? 60 : 830));
        await tester.pump(const Duration(milliseconds: 30));
        final offset = documentPosition(tester).pixels;
        final selection = widget.controller!.selection;
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          documentPosition(tester).pixels,
          upwards ? lessThan(offset) : greaterThan(offset),
        );
        expect(widget.controller!.selection, isNot(selection));
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 150));
        final stopped = documentPosition(tester).pixels;
        await tester.pump(const Duration(milliseconds: 400));
        expect(documentPosition(tester).pixels, stopped);
        expect(field, findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  for (final upwards in [false, true]) {
    testWidgets(
      'phone source selection edge scrolls ${upwards ? 'up' : 'down'} while held',
      (tester) async {
        await openPhone(tester, long: true);
        await tester.ensureVisible(
          find.byTooltip('Markdown / podgląd na żywo'),
        );
        await tester.tap(find.byTooltip('Markdown / podgląd na żywo'));
        await tester.pumpAndSettle();
        final field = find.byKey(const Key('source-editor'));
        final widget = tester.widget<TextField>(field);
        final viewport = find.byKey(const Key('mobile-note-scroll'));
        final scroll = tester
            .widget<SingleChildScrollView>(viewport)
            .controller!;
        if (upwards) {
          scroll.jumpTo(900);
          await tester.pumpAndSettle();
        }
        final rect = tester.getRect(viewport);
        if (!upwards) {
          // A downward pull that starts at the top belongs to dismissal, not
          // selection; select while already reading inside the note.
          tester
              .widget<SingleChildScrollView>(
                find.byKey(const Key('mobile-note-scroll')),
              )
              .controller!
              .jumpTo(200);
          await tester.pumpAndSettle();
        }
        final gesture = await tester.startGesture(Offset(rect.left + 65, 400));
        await tester.pump(
          kLongPressTimeout + const Duration(milliseconds: 100),
        );
        expect(widget.controller!.selection.isCollapsed, isFalse);
        await gesture.moveTo(Offset(rect.left + 90, upwards ? 60 : 830));
        await tester.pump(const Duration(milliseconds: 30));
        final offset = documentPosition(tester).pixels;
        final selection = widget.controller!.selection;
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          documentPosition(tester).pixels,
          upwards ? lessThan(offset) : greaterThan(offset),
        );
        expect(widget.controller!.selection, isNot(selection));
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 150));
        final stopped = documentPosition(tester).pixels;
        await tester.pump(const Duration(milliseconds: 400));
        expect(documentPosition(tester).pixels, stopped);
        expect(find.byKey(const Key('source-editor')), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
  testWidgets(
    'phone editable viewport reaches bottom status bar without dead strip',
    (tester) async {
      await openPhone(tester, long: true);
      final field = find.byKey(const ValueKey('livemd-document-field'));
      final status = find
          .ancestor(
            of: find.textContaining('Ostatnia zmiana:'),
            matching: find.byWidgetPredicate(
              (w) => w is Container && w.constraints?.maxHeight == 28,
            ),
          )
          .first;
      expect(
        tester.getTopLeft(status).dy - tester.getBottomLeft(field).dy,
        lessThanOrEqualTo(12),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final source in [false, true]) {
    testWidgets('phone heading and tags scroll with body source=$source', (
      tester,
    ) async {
      await openPhone(tester, long: true);
      if (source) {
        await tester.ensureVisible(
          find.byTooltip('Markdown / podgląd na żywo'),
        );
        await tester.tap(find.byTooltip('Markdown / podgląd na żywo'));
        await tester.pumpAndSettle();
      }
      final title = find.byKey(const Key('note-title'), skipOffstage: false);
      final before = tester.getTopLeft(title).dy;
      await tester.dragFrom(const Offset(195, 500), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(title).dy, lessThan(before - 50));
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('phone heading and tags retain geometry when keyboard opens', (
    tester,
  ) async {
    await openPhone(tester);
    final title = find.byKey(const Key('note-title'));
    final before = tester.widget<TextField>(title);
    final tagTop = tester.getTopLeft(find.text('#stable'));
    await tester.tap(title);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    final after = tester.widget<TextField>(title);
    expect(after.style!.fontSize, before.style!.fontSize);
    expect(after.maxLines, before.maxLines);
    expect(find.text('#stable'), findsOneWidget);
    expect(tester.getTopLeft(find.text('#stable')), tagTop);
    await tester.pumpWidget(const SizedBox());
  });
}
