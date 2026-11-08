import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:livemd_flutter/livemd_flutter.dart';
import 'package:silique/core/models.dart';
import 'package:silique/main.dart';
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

class _QuietStorage extends NativeStorage {
  _QuietStorage(super.root);
  @override
  Future<void> mirror(Note note) async {}
}

/// Counts spans that paint a background, i.e. real search highlights.
int _highlightedSpans(WidgetTester tester, String containing) {
  final editable = tester
      .widgetList<EditableText>(find.byType(EditableText))
      .firstWhere(
        (widget) => widget.controller.text.contains(containing),
        orElse: () => throw StateError('No editor contains "$containing"'),
      );
  final span = editable.controller.buildTextSpan(
    context: tester.element(find.byType(EditableText).first),
    withComposing: false,
  );
  var count = 0;
  void visit(InlineSpan node) {
    if (node.style?.backgroundColor != null) count++;
    if (node is TextSpan) node.children?.forEach(visit);
  }

  visit(span);
  return count;
}

/// Collects the font sizes of spans that carry visible text.
List<double> _fontSizes(WidgetTester tester, String containing) {
  final editable = tester
      .widgetList<EditableText>(find.byType(EditableText))
      .firstWhere((widget) => widget.controller.text.contains(containing));
  final span = editable.controller.buildTextSpan(
    context: tester.element(find.byType(EditableText).first),
    withComposing: false,
  );
  final sizes = <double>[];
  void visit(InlineSpan node) {
    if (node is TextSpan) {
      final text = node.text ?? '';
      if (text.trim().isNotEmpty && node.style?.fontSize != null) {
        sizes.add(node.style!.fontSize!);
      }
      node.children?.forEach(visit);
    }
  }

  visit(span);
  return sizes;
}

/// The Markdown source currently held by the live editor (longest field).
String _editorText(WidgetTester tester) => tester
    .widgetList<EditableText>(find.byType(EditableText))
    .reduce(
      (a, b) => a.controller.text.length >= b.controller.text.length ? a : b,
    )
    .controller
    .text;

void main() {
  var fontsLoaded = false;

  Future<Notebook> seed() async {
    final dir = Directory.systemTemp.createTempSync('silique-ws-ui-');
    final repo = Notebook(
      storage: _QuietStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Osobiste');
    final id = repo.vaults.single.id;
    final examples = [
      ('Alfa', 'Projekty', 'kot chodzi po dachu'),
      ('Beta', 'Projekty/Mercaro', 'drugi kot śpi'),
      ('Gamma', 'Prywatne', 'bez zwierząt'),
      ('Delta', '', 'czwarta notatka'),
    ];
    for (final e in examples) {
      final note = await repo.createNote(id, folder: e.$2);
      await repo.save(note.copyWith(title: e.$1, body: e.$3));
    }
    addTearDown(() async {
      await repo.storage.close();
      dir.deleteSync(recursive: true);
    });
    return repo;
  }

  Future<void> mount(WidgetTester tester, Notebook repo, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      if (!fontsLoaded) {
        final font = FontLoader('Inter')
          ..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
        await font.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
        fontsLoaded = true;
      }
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('workspace-menu-capture'),
        child: ProviderScope(
          overrides: [notebookProvider.overrideWithValue(repo)],
          child: const SiliqueApp(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Note noteByTitle(Notebook repo, String title) => repo
      .notes[repo.vaults.single.id]!
      .values
      .firstWhere((note) => note.title == title);

  Finder card(Notebook repo, String title) =>
      find.byKey(Key('note-card-${noteByTitle(repo, title).id}'));

  Future<void> ctrlTap(WidgetTester tester, Finder finder) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(finder);
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }

  Future<void> shiftTap(WidgetTester tester, Finder finder) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(finder);
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }

  Future<void> openSourceMode(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Markdown / podgląd na żywo'));
    await tester.pumpAndSettle();
  }

  /// Lets real asynchronous storage work finish, then rebuilds the widgets.
  Future<void> settleWork(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
  }

  /// Drags [from] onto [to] with enough movement to start an internal drag.
  Future<void> dragOnto(WidgetTester tester, Finder from, Finder to) async {
    final gesture = await tester.startGesture(tester.getCenter(from));
    // Desktop rows turn into a drag only after a short hold, so a jittered
    // click still reaches the row's tap handler.
    await tester.pump(const Duration(milliseconds: 250));
    await gesture.moveBy(const Offset(0, 24));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveTo(tester.getCenter(to));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.up();
    await settleWork(tester);
  }

  /// Lets delayed dialog disposals and autosave timers finish before teardown.
  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 2));
    await settleWork(tester);
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets(
    'ctrl and shift clicks select notes without switching the editor',
    (tester) async {
      final repo = (await tester.runAsync(seed))!;
      await mount(tester, repo, const Size(1380, 880));
      await tester.tap(card(repo, 'Alfa'));
      await tester.pumpAndSettle();
      await openSourceMode(tester);
      await tester.enterText(
        find.byKey(const Key('source-editor')),
        'brudnopis',
      );
      await tester.pump();

      await ctrlTap(tester, card(repo, 'Beta'));
      expect(find.byKey(const Key('selection-bar')), findsOneWidget);
      expect(find.text('Zaznaczono 1'), findsOneWidget);
      // Selecting must not replace the open note with unsaved text.
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('source-editor')))
            .controller!
            .text,
        'brudnopis',
      );

      await ctrlTap(tester, card(repo, 'Gamma'));
      expect(find.text('Zaznaczono 2'), findsOneWidget);

      await ctrlTap(tester, card(repo, 'Beta'));
      expect(find.text('Zaznaczono 1'), findsOneWidget);

      await ctrlTap(tester, card(repo, 'Alfa'));
      await shiftTap(tester, card(repo, 'Gamma'));
      // Alfa..Gamma in the visible order is three notes.
      expect(find.text('Zaznaczono 3'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('selection-bar')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('bulk pin, trash and restore act on every selected note', (
    tester,
  ) async {
    final repo = (await tester.runAsync(seed))!;
    await mount(tester, repo, const Size(1380, 880));
    await ctrlTap(tester, card(repo, 'Alfa'));
    await ctrlTap(tester, card(repo, 'Beta'));
    expect(find.text('Zaznaczono 2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('bulk-pin')));
    await settleWork(tester);
    expect(noteByTitle(repo, 'Alfa').favorite, true);
    expect(noteByTitle(repo, 'Beta').favorite, true);
    expect(noteByTitle(repo, 'Gamma').favorite, false);

    await tester.tap(find.byKey(const Key('bulk-trash')));
    await settleWork(tester);
    expect(noteByTitle(repo, 'Alfa').deleted, true);
    expect(noteByTitle(repo, 'Beta').deleted, true);
    expect(find.byKey(const Key('selection-bar')), findsNothing);

    // Trashed notes disappear from the default filter and reappear in Kosz.
    expect(card(repo, 'Alfa'), findsNothing);
    await tester.tap(find.text('Usunięte'));
    await tester.pumpAndSettle();
    expect(card(repo, 'Alfa'), findsOneWidget);
    await ctrlTap(tester, card(repo, 'Alfa'));
    await ctrlTap(tester, card(repo, 'Beta'));
    await tester.tap(find.byKey(const Key('bulk-restore')));
    await settleWork(tester);
    expect(noteByTitle(repo, 'Alfa').deleted, false);
    expect(noteByTitle(repo, 'Beta').deleted, false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('bulk move flushes unsaved editor text and moves every note', (
    tester,
  ) async {
    final repo = (await tester.runAsync(seed))!;
    await mount(tester, repo, const Size(1380, 880));
    await tester.tap(card(repo, 'Alfa'));
    await tester.pumpAndSettle();
    await openSourceMode(tester);
    await tester.enterText(
      find.byKey(const Key('source-editor')),
      'tekst jeszcze nezapisany',
    );
    await tester.pump();

    await ctrlTap(tester, card(repo, 'Beta'));
    await ctrlTap(tester, card(repo, 'Alfa'));
    await tester.tap(find.byKey(const Key('bulk-move')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('folder-target-Prywatne')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('folder-target-confirm')));
    await settleWork(tester);

    final alfa = noteByTitle(repo, 'Alfa');
    expect(alfa.body, 'tekst jeszcze nezapisany');
    expect(alfa.folder, 'Prywatne');
    expect(noteByTitle(repo, 'Beta').folder, 'Prywatne');
    // The editor still shows the note that was being edited.
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('source-editor')))
          .controller!
          .text,
      'tekst jeszcze nezapisany',
    );
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('context move waits for folder confirmation and offers hiding', (
    tester,
  ) async {
    final repo = (await tester.runAsync(seed))!;
    await mount(tester, repo, const Size(1380, 880));
    await tester.tap(card(repo, 'Alfa'), buttons: 2);
    await tester.pumpAndSettle();
    expect(find.text('Przenieś do ukrytych'), findsOneWidget);
    await tester.tap(find.text('Przenieś do folderu'));
    await tester.pumpAndSettle();
    expect(noteByTitle(repo, 'Alfa').folder, 'Projekty');
    await tester.tap(find.byKey(const Key('folder-target-Prywatne')));
    await tester.pumpAndSettle();
    expect(noteByTitle(repo, 'Alfa').folder, 'Projekty');
    await tester.tap(find.byKey(const Key('folder-target-confirm')));
    await settleWork(tester);
    expect(noteByTitle(repo, 'Alfa').folder, 'Prywatne');
    await finish(tester);
  });

  testWidgets('dragging a note or a selected group onto a folder moves it', (
    tester,
  ) async {
    final repo = (await tester.runAsync(seed))!;
    await mount(tester, repo, const Size(1380, 880));
    final folderRow = find.byKey(const Key('folder-toggle-Prywatne'));
    expect(folderRow, findsNothing, reason: 'Prywatne has no children yet');

    final target = find.text('Prywatne');
    expect(target, findsOneWidget);
    await dragOnto(tester, card(repo, 'Delta'), target);
    expect(noteByTitle(repo, 'Delta').folder, 'Prywatne');

    // Dragging a group moves every selected note.
    await ctrlTap(tester, card(repo, 'Alfa'));
    await ctrlTap(tester, card(repo, 'Beta'));
    await dragOnto(tester, card(repo, 'Alfa'), find.text('Prywatne').first);
    expect(noteByTitle(repo, 'Alfa').folder, 'Prywatne');
    expect(noteByTitle(repo, 'Beta').folder, 'Prywatne');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('folder drag moves a subtree and refuses its own descendant', (
    tester,
  ) async {
    final repo = (await tester.runAsync(seed))!;
    await mount(tester, repo, const Size(1380, 880));
    // Projekty has a child (Mercaro), so it exposes an expand arrow.
    expect(find.byKey(const Key('folder-toggle-Projekty')), findsOneWidget);
    await dragOnto(tester, find.text('Mercaro'), find.text('Prywatne'));
    expect(
      repo.allFolders(repo.vaults.single.id),
      contains('Prywatne/Mercaro'),
    );
    expect(noteByTitle(repo, 'Beta').folder, 'Prywatne/Mercaro');

    // Dropping a folder onto its own child is a no-op, never a cycle.
    await dragOnto(tester, find.text('Prywatne'), find.text('Mercaro'));
    expect(noteByTitle(repo, 'Beta').folder, 'Prywatne/Mercaro');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'folder menu moves a complete subtree only after parent confirmation',
    (tester) async {
      final repo = (await tester.runAsync(seed))!;
      await tester.runAsync(
        () => repo.createFolder(repo.vaults.single, 'Projekty/Empty/Deep'),
      );
      final oldShadows = debugDisableShadows;
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = oldShadows);
      await mount(tester, repo, const Size(1380, 880));
      await tester.tap(find.text('Projekty').first, buttons: 2);
      await tester.pumpAndSettle();
      final output = Platform.environment['SILIQUE_HOME_MENU_CAPTURE'];
      expect(find.byType(PopupMenuDivider), findsNWidgets(2));
      if (output != null) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('workspace-menu-capture')),
          );
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          await File(output).writeAsBytes(bytes.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(find.text('Zmień nazwę'), findsOneWidget);
      await tester.tap(find.text('Przenieś folder'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('folder-target-confirm')),
            )
            .onPressed,
        isNull,
      );
      for (final path in ['Projekty', 'Projekty/Mercaro']) {
        expect(
          tester.widget<ListTile>(find.byKey(Key('folder-target-$path'))).onTap,
          isNull,
        );
      }
      await tester.enterText(
        find.byKey(const Key('folder-target-search')),
        'Prywatne',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('folder-target-Prywatne')));
      await tester.pumpAndSettle();
      expect(noteByTitle(repo, 'Beta').folder, 'Projekty/Mercaro');
      await tester.tap(find.byKey(const Key('folder-target-confirm')));
      await settleWork(tester);
      expect(noteByTitle(repo, 'Alfa').folder, 'Prywatne/Projekty');
      expect(noteByTitle(repo, 'Beta').folder, 'Prywatne/Projekty/Mercaro');
      expect(
        repo.foldersOf(repo.vaults.single.id),
        contains('Prywatne/Projekty/Empty/Deep'),
      );
      expect(tester.takeException(), isNull);
      debugDisableShadows = oldShadows;
      await finish(tester);
    },
  );

  testWidgets('a folder context menu creates a relative subfolder', (
    tester,
  ) async {
    final repo = (await tester.runAsync(seed))!;
    await mount(tester, repo, const Size(1380, 880));
    await tester.tap(find.text('Projekty'), buttons: 2);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nowy podfolder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('folder-name')), 'Nowy');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('folder-create')));
    await settleWork(tester);
    expect(repo.allFolders(repo.vaults.single.id), contains('Projekty/Nowy'));
    expect(find.text('Nowy'), findsOneWidget);
    expect(find.byKey(const Key('folder-toggle-Projekty/Nowy')), findsNothing);
    // The empty folder is stored as vault metadata, not as a synthetic note.
    expect(repo.foldersOf(repo.vaults.single.id), contains('Projekty/Nowy'));
    expect(repo.notes[repo.vaults.single.id]!.values.length, 4);
    await finish(tester);
  });

  testWidgets('in-note find highlights every match and cycles in both modes', (
    tester,
  ) async {
    final repo = (await tester.runAsync(seed))!;
    await mount(tester, repo, const Size(1380, 880));
    await tester.tap(card(repo, 'Alfa'));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('find-bar')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('find-field')), 'kot');
    await tester.pumpAndSettle();
    expect(find.text('1 / 1'), findsOneWidget);
    expect(_highlightedSpans(tester, 'kot chodzi'), greaterThan(0));

    // Two matches in source mode, with a counter and cyclic movement.
    await openSourceMode(tester);
    await tester.enterText(
      find.byKey(const Key('source-editor')),
      'kot oraz KOT oraz kot',
    );
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);
    expect(_highlightedSpans(tester, 'kot oraz'), 3);
    // Editing the source moved focus; cycling always happens from the field.
    await tester.tap(find.byKey(const Key('find-field')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('3 / 3'), findsOneWidget);
    // Focus stays in the find field while cycling.
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('find-field')))
          .focusNode
          ?.hasFocus,
      true,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('find-bar')), findsNothing);
    expect(_highlightedSpans(tester, 'kot oraz'), 0);
    // Searching never changes the stored note.
    expect(noteByTitle(repo, 'Alfa').body, 'kot chodzi po dachu');
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('no matches and accent-insensitive counters stay consistent', (
    tester,
  ) async {
    final repo = (await tester.runAsync(seed))!;
    await mount(tester, repo, const Size(1380, 880));
    await tester.tap(card(repo, 'Alfa'));
    await tester.pumpAndSettle();
    await openSourceMode(tester);
    await tester.enterText(
      find.byKey(const Key('source-editor')),
      'Zażółć gęślą jaźń. Zażółć.',
    );
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('find-field')), 'ŻÓŁĆ');
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('find-field')), 'nie ma');
    await tester.pumpAndSettle();
    expect(find.text('Brak wyników'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('find-field')), '');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('find-count')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('find-count'))).data, '');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'the font size field formats only the selection and persists it',
    (tester) async {
      final repo = (await tester.runAsync(seed))!;
      await mount(tester, repo, const Size(1380, 880));
      await tester.tap(card(repo, 'Delta'));
      await tester.pumpAndSettle();
      await openSourceMode(tester);
      final source = tester.widget<TextField>(
        find.byKey(const Key('source-editor')),
      );
      source.controller!.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 7,
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('span-size')), '24');
      await tester.tap(find.byKey(const Key('span-size-apply')));
      await tester.pumpAndSettle();
      expect(
        source.controller!.text,
        '<span style="font-size:24px">czwarta</span> notatka',
      );

      // The live view renders the stored size for that run only.
      await tester.tap(find.byTooltip('Markdown / podgląd na żywo'));
      await tester.pumpAndSettle();
      final sizes = _fontSizes(tester, 'notatka');
      expect(sizes, contains(24));
      expect(sizes.where((size) => size == 24).length, lessThan(sizes.length));

      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 450)),
      );
      await tester.pumpAndSettle();
      final saved = noteByTitle(repo, 'Delta');
      expect(saved.body, contains('font-size:24px'));

      // Undo and redo use the editor history that belongs to this document.
      await tester.tap(find.byType(LiveMarkdownEditor));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(
        _editorText(tester),
        'czwarta notatka',
        reason: 'undo restores the plain text',
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(_editorText(tester), contains('font-size:24px'));

      // Reopening the note shows the committed Markdown again.
      await settleWork(tester);
      await tester.tap(card(repo, 'Alfa'));
      await tester.pumpAndSettle();
      await tester.tap(card(repo, 'Delta'));
      await tester.pumpAndSettle();
      await openSourceMode(tester);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('source-editor')))
            .controller!
            .text,
        contains('font-size:24px'),
      );
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets('sync status lives in the bottom bar, not above the toolbar', (
    tester,
  ) async {
    final repo = (await tester.runAsync(seed))!;
    await mount(tester, repo, const Size(1380, 880));
    await tester.tap(card(repo, 'Alfa'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sync-status')), findsOneWidget);
    // Icon-only badge: the local vault paints the orange cloud-off icon and
    // the readable state moved into the hover tooltip.
    expect(find.text('Lokalnie'), findsNothing);
    expect(find.byTooltip('Lokalnie'), findsOneWidget);
    // The whole header section above the toolbar is gone; the note menu now
    // lives in the toolbar itself.
    expect(find.byKey(const Key('editor-breadcrumb')), findsNothing);
    expect(find.byKey(const Key('note-options')), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const Key('note-options'))).height,
      lessThanOrEqualTo(42),
    );
    // The status is painted below the editor content, next to the word count.
    final status = tester.getRect(find.byKey(const Key('sync-status')));
    final words = tester.getRect(find.textContaining('słów'));
    final change = tester.getRect(find.textContaining('Ostatnia zmiana'));
    expect((status.center.dy - words.center.dy).abs(), lessThan(6));
    expect((status.center.dy - change.center.dy).abs(), lessThan(6));
    expect(status.center.dx, greaterThan(change.center.dx));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mobile selection mode stays readable and overflow free', (
    tester,
  ) async {
    final repo = (await tester.runAsync(seed))!;
    await mount(tester, repo, const Size(390, 844));
    await tester.tap(find.byKey(const Key('select-mode')));
    await tester.pumpAndSettle();
    await tester.tap(card(repo, 'Alfa'));
    await tester.pumpAndSettle();
    expect(find.text('Zaznaczono 1'), findsOneWidget);
    await tester.tap(card(repo, 'Beta'));
    await tester.pumpAndSettle();
    expect(find.text('Zaznaczono 2'), findsOneWidget);
    // Selecting never opens the editor on mobile.
    expect(find.byKey(const Key('note-title')), findsNothing);
    await tester.binding.setSurfaceSize(const Size(320, 740));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'device rename is confirmed by the server and errors stay visible',
    (tester) async {
      final repo = (await tester.runAsync(seed))!;
      var renames = 0;
      var fail = false;
      var serverName = 'Stary laptop';
      repo.session = Session(
        server: 'http://127.0.0.1:18791',
        token: 'test',
        userId: 'test-user',
        email: 'ui@example.com',
      );
      repo.api = SiliqueApi(
        repo.session!.server,
        token: 'test',
        client: MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/v1/devices') {
            return http.Response(
              jsonEncode({
                'devices': [
                  {'id': repo.deviceId, 'name': serverName, 'revoked': 0},
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (request.method == 'PUT' &&
              request.url.path == '/v1/devices/${repo.deviceId}/name') {
            renames++;
            if (fail) {
              return http.Response(
                jsonEncode({'error': 'Device not found'}),
                404,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            serverName = (body['name'] as String).trim();
            return http.Response(
              jsonEncode({'ok': true, 'name': serverName}),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response(
            jsonEncode({'error': 'unexpected'}),
            500,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      await mount(tester, repo, const Size(1380, 880));
      await tester.tap(find.byTooltip('Ustawienia synchronizacji'));
      await tester.pumpAndSettle();
      await settleWork(tester);
      expect(repo.devices, isNotNull);
      // The device list lives on the account & sync tab.
      await tester.tap(find.byKey(const Key('settings-tab-account')));
      await tester.pumpAndSettle();
      expect(find.text('Stary laptop (to urządzenie)'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('device-rename')));
      await tester.tap(find.byKey(const Key('device-rename')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '  Laptop Kamila  ');
      await tester.tap(find.text('Zapisz'));
      await settleWork(tester);
      expect(renames, 1);
      expect(repo.devices!.single['name'], 'Laptop Kamila');
      expect(find.text('Laptop Kamila (to urządzenie)'), findsWidgets);

      fail = true;
      await tester.ensureVisible(find.byKey(const Key('device-rename')));
      await tester.tap(find.byKey(const Key('device-rename')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Inna nazwa');
      await tester.tap(find.text('Zapisz'));
      await settleWork(tester);
      expect(renames, 2);
      expect(find.text('Device not found'), findsOneWidget);
      expect(repo.devices!.single['name'], 'Laptop Kamila');
      expect(tester.takeException(), isNull);
      await finish(tester);
      repo.api!.close();
    },
  );
}
