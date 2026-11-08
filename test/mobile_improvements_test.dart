import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';
import 'package:silique/main.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

class _Storage extends NativeStorage {
  _Storage(super.root);
  @override
  Future<void> mirror(Note note) async {}
}

void main() {
  Future<Notebook> seed() async {
    final dir = Directory.systemTemp.createTempSync('silique-mobile-');
    final repo = Notebook(
      storage: _Storage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Osobiste');
    for (var i = 0; i < 8; i++) {
      final note = await repo.createNote(
        repo.vaults.single.id,
        folder: 'Projekty/Aplikacja',
      );
      await repo.save(
        note.copyWith(
          title: 'Notatka $i',
          body: 'Pierwsza linia\n${List.filled(40, 'Tekst').join('\n')}\n',
        ),
      );
    }
    addTearDown(() async {
      await repo.storage.close();
      dir.deleteSync(recursive: true);
    });
    return repo;
  }

  Future<void> mount(
    WidgetTester tester,
    Notebook repo, {
    double width = 390,
    double height = 844,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
    });
    await tester.runAsync(() async {
      final font = FontLoader('Inter')
        ..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [notebookProvider.overrideWithValue(repo)],
        child: const RepaintBoundary(key: Key('capture'), child: SiliqueApp()),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
    });
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final box = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('capture')),
    );
    await tester.runAsync(() async {
      final image = await box.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('/tmp/silique-$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'content swipe opens navigation; system edge, vertical and reverse swipes do not',
    (tester) async {
      final repo = (await tester.runAsync(seed))!;
      await mount(tester, repo);
      bool open() =>
          tester.state<ScaffoldState>(find.byType(Scaffold).first).isDrawerOpen;
      await tester.dragFrom(const Offset(2, 500), const Offset(190, 0));
      await tester.pumpAndSettle();
      expect(open(), false);
      await tester.dragFrom(const Offset(200, 500), const Offset(-150, 0));
      await tester.pumpAndSettle();
      expect(open(), false);
      await tester.dragFrom(const Offset(90, 500), const Offset(0, -140));
      await tester.pumpAndSettle();
      expect(open(), false);
      await tester.dragFrom(const Offset(90, 500), const Offset(190, 0));
      await tester.pumpAndSettle();
      expect(open(), true);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets('keyboard leaves search results visible at narrow phone width', (
    tester,
  ) async {
    final repo = (await tester.runAsync(seed))!;
    await mount(tester, repo, width: 320, height: 640);
    final search = find.widgetWithText(TextField, 'Szukaj w nazwach i treści…');
    await tester.enterText(search, 'Notatka');
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    final cards = find.byKey(
      Key('note-card-${repo.notes[repo.vaults.single.id]!.values.last.id}'),
    );
    expect(tester.getRect(search).bottom, lessThan(150));
    expect(tester.getRect(cards).top, lessThan(240));
    expect(find.text('Moje notatki'), findsNothing);
    expect(tester.takeException(), isNull);
    await capture(tester, 'mobile-search');
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'select all follows visible search results and can clear without leaving selection mode',
    (tester) async {
      final repo = (await tester.runAsync(seed))!;
      await mount(tester, repo);
      await tester.tap(find.byKey(const Key('select-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('select-all')));
      await tester.pumpAndSettle();
      expect(find.text('Odznacz wszystko'), findsOneWidget);
      expect(find.text('Zaznaczono 8'), findsWidgets);
      await tester.enterText(
        find.widgetWithText(TextField, 'Szukaj w nazwach i treści…'),
        'Notatka 2',
      );
      await tester.pumpAndSettle();
      expect(find.text('Zaznaczono 1'), findsWidgets);
      await tester.enterText(
        find.widgetWithText(TextField, 'Szukaj w nazwach i treści…'),
        '',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('select-all')));
      await tester.pumpAndSettle();
      expect(find.text('Zaznaczono 8'), findsWidgets);
      await tester.tap(find.byKey(const Key('select-all')));
      await tester.pumpAndSettle();
      expect(find.text('Zaznacz wszystko'), findsOneWidget);
      expect(find.byKey(const Key('selection-bar')), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextField, 'Szukaj w nazwach i treści…'),
        'Notatka 2',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('select-all')));
      await tester.pumpAndSettle();
      expect(find.text('Zaznaczono 1'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'breadcrumbs, emoji insertion and trailing empty caret stay above phone keyboard',
    (tester) async {
      final repo = (await tester.runAsync(seed))!;
      await mount(tester, repo);
      final note = repo.notes[repo.vaults.single.id]!.values.last;
      await tester.tap(find.byKey(Key('note-card-${note.id}')));
      await tester.pumpAndSettle();
      final breadcrumbs = find.byKey(const Key('note-breadcrumbs'));
      expect(
        find.descendant(of: breadcrumbs, matching: find.text('Aplikacja')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Wstaw emotkę'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('😊'));
      await tester.pumpAndSettle();
      final editor = tester.widget<LiveMarkdownEditor>(
        find.byType(LiveMarkdownEditor),
      );
      expect(editor.controller.text, endsWith('😊'));
      final field = find.byKey(const ValueKey('livemd-document-field'));
      await tester.tap(field);
      editor.controller.setText(
        '${editor.controller.text}\n',
        selection: TextSelection.collapsed(
          offset: editor.controller.text.length + 1,
        ),
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 350);
      await tester.pumpAndSettle();
      final editable = tester
          .state<EditableTextState>(find.byType(EditableText).last)
          .renderEditable;
      final caret = editable.getLocalRectForCaret(
        TextPosition(offset: editor.controller.text.length),
      );
      final caretBottom = editable.localToGlobal(caret.bottomLeft).dy;
      expect(caretBottom, lessThanOrEqualTo(844 - 350));
      expect(find.text('Zapisywanie…'), findsNothing);
      expect(tester.takeException(), isNull);
      await capture(tester, 'mobile-editor');
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
