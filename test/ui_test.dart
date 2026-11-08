import 'package:desktop_drop/desktop_drop.dart';

import 'fixtures/image_fixtures.dart';

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/services/api.dart';

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/main.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/ui/home.dart' show exampleBody;
import 'package:silique/ui/menus.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

class UiStorage extends NativeStorage {
  UiStorage(super.root);
  @override
  Future<void> mirror(Note note) async {}
}

void main() {
  var emojiLoaded = false;
  Future<Notebook> seed() async {
    final dir = Directory.systemTemp.createTempSync('silique-ui-');
    final repo = Notebook(
      storage: UiStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Osobiste');
    final id = repo.vaults.single.id;
    final examples = [
      ('Plan na tydzień', 'Projekty', exampleBody),
      (
        'Mercaro – pomysły',
        'Projekty/Mercaro',
        'Nowe funkcjonalności, roadmapa oraz pomysły na rozwój aplikacji.',
      ),
      (
        'Homelab – konfiguracja',
        'Projekty/Homelab',
        'Proxmox, kontenery, kopie zapasowe i konfiguracja sieci.',
      ),
      (
        'Notatki ze spotkania',
        'Projekty',
        'Omówienie postępów i dalsze kroki dotyczące projektu.',
      ),
      ('Zakupy', 'Prywatne/Zakupy', 'Lista rzeczy do domu i biura.'),
      (
        'Pomysły na wakacje',
        'Prywatne/Podróże',
        'Miejsca, które warto zobaczyć i plany na wolne dni.',
      ),
      (
        'Cele na 2026',
        'Prywatne/Cele',
        'Rozwój, zdrowie, finanse. To będzie dobry rok!',
      ),
      (
        'Czytanie – książki',
        'Obszary/Rozwój',
        'Lista i notatki z przeczytanych książek.',
      ),
    ];
    for (final e in examples) {
      final n = await repo.createNote(id, folder: e.$2);
      await repo.save(
        n.copyWith(
          title: e.$1,
          body: e.$3,
          favorite: e.$1 == 'Plan na tydzień',
          tags: e.$1 == 'Plan na tydzień'
              ? ['planowanie', 'praca', 'cele']
              : [],
        ),
      );
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
      final font = FontLoader('Inter')
        ..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
      final emoji = File('/System/Library/Fonts/Apple Color Emoji.ttc');
      if (Platform.isMacOS && !emojiLoaded && await emoji.exists()) {
        final bytes = await emoji.readAsBytes();
        final font = FontLoader('Apple Color Emoji')
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await font.load();
        emojiLoaded = true;
      }
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [notebookProvider.overrideWithValue(repo)],
        child: const SiliqueApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'desktop matches the three-pane design and searches note content',
    (tester) async {
      final repo = (await tester.runAsync(seed))!;
      await mount(tester, repo, const Size(1380, 880));
      expect(tester.takeException(), isNull);
      if (Platform.environment['SILIQUE_CAPTURE_UI'] == '1') {
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/desktop.png'),
        );
      }
      await tester.enterText(find.byType(TextField).first, 'kontenery');
      await tester.pumpAndSettle();
      expect(find.text('Homelab – konfiguracja'), findsOneWidget);
      expect(find.text('Mercaro – pomysły'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('mobile list, editor, autosave and journal stay usable', (
    tester,
  ) async {
    final repo = (await tester.runAsync(seed))!;
    await mount(tester, repo, const Size(390, 844));
    expect(tester.takeException(), isNull);
    if (Platform.environment['SILIQUE_CAPTURE_UI'] == '1') {
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/android.png'),
      );
    }
    await tester.tap(find.text('Plan na tydzień'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('note-title'), skipOffstage: false),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const Key('note-title'), skipOffstage: false),
      'Zmieniony tytuł',
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(
      repo.notes[repo.vaults.single.id]!.values.any(
        (n) => n.title == 'Zmieniony tytuł',
      ),
      true,
    );
    // Android system Back returns to the list and flushes a fresh edit.
    await tester.enterText(
      find.byKey(const Key('note-title'), skipOffstage: false),
      'Zapisany przy powrocie',
    );
    await tester.binding.handlePopRoute();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('note-title'), skipOffstage: false),
      findsNothing,
    );
    expect(
      repo.notes[repo.vaults.single.id]!.values.any(
        (n) => n.title == 'Zapisany przy powrocie',
      ),
      true,
    );
    await tester.tap(find.text('Dziennik').last);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    expect(
      repo.notes[repo.vaults.single.id]!.values
          .where((n) => n.journalDate != null)
          .length,
      1,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('new ordinary note persists an editable default title', (
    tester,
  ) async {
    final repo = (await tester.runAsync(seed))!;
    final note = (await tester.runAsync(
      () => repo.createNote(repo.vaults.single.id),
    ))!;
    await mount(tester, repo, const Size(390, 844));
    await tester.tap(find.byKey(Key('note-card-${note.id}')));
    await tester.pumpAndSettle();
    final title = tester.widget<TextField>(
      find.byKey(const Key('note-title'), skipOffstage: false),
    );
    expect(repo.notes[note.vaultId]![note.id]!.title, 'Bez tytułu');
    expect(title.controller!.text, 'Bez tytułu');
    expect(title.decoration!.hintText, 'Bez tytułu');
    expect(
      find.descendant(
        of: find.byKey(const Key('note-title'), skipOffstage: false),
        matching: find.byType(EditableText),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cleared title stays empty after autosave and reopening', (
    tester,
  ) async {
    final repo = (await tester.runAsync(seed))!;
    final vaultId = repo.vaults.single.id;
    final note = repo.notes[vaultId]!.values.firstWhere(
      (note) => note.title == 'Plan na tydzień',
    );
    await mount(tester, repo, const Size(390, 844));
    await tester.tap(find.text(note.title));
    await tester.pumpAndSettle();
    final title = find.byKey(const Key('note-title'), skipOffstage: false);
    await tester.enterText(title, '');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    expect(repo.notes[vaultId]![note.id]!.title, isEmpty);
    expect(tester.widget<TextField>(title).controller!.text, isEmpty);
    expect(tester.widget<TextField>(title).decoration!.hintText, 'Bez tytułu');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('note-card-${note.id}')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(title).controller!.text, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mobile vault selection lives only in drawer, desktop keeps it', (
    tester,
  ) async {
    final repo = (await tester.runAsync(seed))!;
    await tester.runAsync(() => repo.createVault('Drugi'));
    await mount(tester, repo, const Size(390, 844));
    expect(find.byType(SiliqueChoice<String?>), findsNothing);
    await tester.tap(find.byTooltip('Foldery i vaulty'));
    await tester.pumpAndSettle();
    expect(find.byType(SiliqueChoice<String?>), findsOneWidget);
    await tester.tap(find.byType(SiliqueChoice<String?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Osobiste').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SiliqueChoice<String?>>(find.byType(SiliqueChoice<String?>))
          .value,
      repo.vaults.firstWhere((v) => v.name == 'Osobiste').id,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(const Size(1380, 880));
    await tester.pumpAndSettle();
    expect(find.byType(SiliqueChoice<String?>), findsOneWidget);
    expect(
      find.byKey(const Key('note-title'), skipOffstage: false),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'vault choice management and creation retain their dialog actions',
    (tester) async {
      final repo = (await tester.runAsync(seed))!;
      await mount(tester, repo, const Size(1380, 880));
      await tester.tap(find.byType(SiliqueChoice<String?>));
      await tester.pumpAndSettle();
      expect(find.byType(PopupMenuDivider), findsOneWidget);
      await tester.tap(find.text('Zarządzaj vaultami'));
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsOneWidget);
      expect(
        find.widgetWithText(SiliqueMenuRow, 'Utwórz vault'),
        findsOneWidget,
      );
      expect(find.byTooltip('Zmień nazwę'), findsOneWidget);
      await tester.tap(find.widgetWithText(SiliqueMenuRow, 'Osobiste'));
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsNothing);
      await tester.tap(find.byType(SiliqueChoice<String?>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('+ Nowy vault'));
      await tester.pumpAndSettle();
      expect(find.text('Nowy vault'), findsOneWidget);
      await tester.tap(find.text('Anuluj'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      expect(repo.vaults.length, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('creation sorting offers both directions with stable ties', (
    tester,
  ) async {
    final repo = (await tester.runAsync(seed))!;
    final vaultId = repo.vaults.single.id;
    final notes = repo.notes[vaultId]!;
    notes.clear();
    for (final entry in [('c', 2022), ('b', 2020), ('a', 2020)]) {
      notes[entry.$1] = Note(
        id: entry.$1,
        vaultId: vaultId,
        title: entry.$1,
        body: '',
        createdAt: DateTime.utc(entry.$2),
        updatedAt: DateTime.utc(2030),
      );
    }
    notes['pinned'] = Note(
      id: 'pinned',
      vaultId: vaultId,
      title: 'Pinned',
      body: '',
      favorite: true,
      createdAt: DateTime.utc(2021),
      updatedAt: DateTime.utc(2019),
    );
    await mount(tester, repo, const Size(390, 844));
    Future<void> sort(String label, List<String> expected) async {
      await tester.tap(find.byTooltip('Sortowanie notatek'));
      await tester.pumpAndSettle();
      expect(find.text('Według ostatniej zmiany'), findsOneWidget);
      expect(find.byIcon(Icons.update_outlined), findsOneWidget);
      final menuInk = tester.widgetList<InkWell>(find.byType(InkWell));
      expect(
        menuInk
            .where((ink) => ink.borderRadius == BorderRadius.circular(10))
            .length,
        greaterThanOrEqualTo(4),
      );
      expect(find.text('Według nazwy'), findsOneWidget);
      expect(find.text(label), findsOneWidget);
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      final order = find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('note-card-'),
          )
          .evaluate()
          .map((e) => (e.widget.key! as ValueKey<String>).value)
          .toList();
      expect(order, expected.map((id) => 'note-card-$id').toList());
    }

    await sort('Data utworzenia: od najstarszych', ['pinned', 'a', 'b', 'c']);
    await sort('Data utworzenia: od najnowszych', ['pinned', 'c', 'a', 'b']);
    await tester.pumpWidget(const SizedBox());
  });

  for (final source in [false, true]) {
    testWidgets(
      'mobile top downward pull returns to list without deleting (${source ? 'source' : 'live'})',
      (tester) async {
        final repo = (await tester.runAsync(seed))!;
        final vaultId = repo.vaults.single.id;
        final note = repo.notes[vaultId]!.values.firstWhere(
          (n) => n.title == 'Plan na tydzień',
        );
        await mount(tester, repo, const Size(390, 844));
        await tester.tap(find.text(note.title));
        await tester.pumpAndSettle();
        if (source) {
          await tester.ensureVisible(
            find.byTooltip('Markdown / podgląd na żywo'),
          );
          await tester.tap(find.byTooltip('Markdown / podgląd na żywo'));
          await tester.pumpAndSettle();
        }
        final body = find.byKey(
          Key(source ? 'mobile-note-scroll' : 'livemd-document-field'),
        );
        await tester.enterText(
          find.byKey(const Key('note-title'), skipOffstage: false),
          'Zapis przy geście',
        );
        await tester.dragFrom(tester.getCenter(body), const Offset(0, 140));
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('note-title'), skipOffstage: false),
          findsNothing,
        );
        expect(repo.notes[vaultId]![note.id]!.deleted, isFalse);
        expect(repo.notes[vaultId]![note.id]!.title, 'Zapis przy geście');
        expect(repo.notes[vaultId]!.length, 8);
        await tester.tap(find.byKey(Key('note-card-${note.id}')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('note-title'), skipOffstage: false),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final source in [false, true]) {
    testWidgets(
      'mobile scrolling never dismisses upward or from middle (${source ? 'source' : 'live'})',
      (tester) async {
        final repo = (await tester.runAsync(seed))!;
        final vaultId = repo.vaults.single.id;
        final note = repo.notes[vaultId]!.values.firstWhere(
          (n) => n.title == 'Plan na tydzień',
        );
        repo.notes[vaultId]![note.id] = note.copyWith(
          body: List.generate(120, (i) => 'Wiersz $i').join('\n\n'),
        );
        await mount(tester, repo, const Size(390, 844));
        await tester.tap(find.text(note.title));
        await tester.pumpAndSettle();
        if (source) {
          await tester.ensureVisible(
            find.byTooltip('Markdown / podgląd na żywo'),
          );
          await tester.tap(find.byTooltip('Markdown / podgląd na żywo'));
          await tester.pumpAndSettle();
        }
        final body = find.byKey(const Key('mobile-note-scroll'));
        // The phone document viewport owns the offset in both modes: the live
        // editor field is content-sized, so its own scrollable stays at zero.
        final scroll = tester.state<ScrollableState>(
          find.descendant(of: body, matching: find.byType(Scrollable)).first,
        );
        expect(scroll.position.pixels, 0);
        await tester.dragFrom(const Offset(195, 420), const Offset(0, -160));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('note-title'), skipOffstage: false),
          findsOneWidget,
        );
        expect(scroll.position.pixels, greaterThan(0));
        scroll.position.jumpTo(100);
        await tester.pumpAndSettle();
        // One continuous drag reaching the top is still ordinary scrolling.
        await tester.dragFrom(const Offset(195, 420), const Offset(0, 220));
        await tester.pumpAndSettle();
        expect(scroll.position.pixels, closeTo(0, .5));
        expect(
          find.byKey(const Key('note-title'), skipOffstage: false),
          findsOneWidget,
        );
        expect(repo.notes[vaultId]![note.id]!.deleted, isFalse);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final source in [false, true]) {
    testWidgets(
      'mobile selection extension at top keeps editor open (${source ? 'source' : 'live'})',
      (tester) async {
        final repo = (await tester.runAsync(seed))!;
        final note = repo.notes[repo.vaults.single.id]!.values.first;
        repo.notes[note.vaultId]![note.id] = note.copyWith(
          body: List.generate(12, (i) => 'Selection line $i words').join('\n'),
        );
        await mount(tester, repo, const Size(390, 844));
        await tester.tap(find.byKey(Key('note-card-${note.id}')));
        await tester.pumpAndSettle();
        if (source) {
          await tester.ensureVisible(
            find.byTooltip('Markdown / podgląd na żywo'),
          );
          await tester.tap(find.byTooltip('Markdown / podgląd na żywo'));
          await tester.pumpAndSettle();
        }
        final body = find.byKey(
          Key(source ? 'source-editor' : 'livemd-document-field'),
        );
        final editable = tester.state<EditableTextState>(
          find.descendant(of: body, matching: find.byType(EditableText)),
        );
        final render = editable.renderEditable;
        final start = render.localToGlobal(
          render.getLocalRectForCaret(const TextPosition(offset: 2)).center,
        );
        final gesture = await tester.startGesture(start);
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
        final initial = editable.widget.controller.selection;
        expect(initial.isCollapsed, isFalse);
        await gesture.moveBy(const Offset(0, 110));
        await tester.pump();
        expect(editable.widget.controller.selection, isNot(initial));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('note-title'), skipOffstage: false),
          findsOneWidget,
        );
        expect(repo.notes[note.vaultId]![note.id]!.deleted, isFalse);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets('desktop downward pull does not close editor', (tester) async {
    final repo = (await tester.runAsync(seed))!;
    await mount(tester, repo, const Size(1380, 880));
    await tester.dragFrom(
      tester.getCenter(find.byKey(const Key('livemd-document-field'))),
      const Offset(0, 140),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('note-title'), skipOffstage: false),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('narrow mobile and tablet have no overflow', (tester) async {
    final repo = (await tester.runAsync(seed))!;
    await mount(tester, repo, const Size(320, 740));
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(const Size(780, 800));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'tabs keep saved edits, find works, and right click offers note actions',
    (tester) async {
      final repo = (await tester.runAsync(seed))!;
      await mount(tester, repo, const Size(1380, 880));
      await tester.tap(find.text('Mercaro – pomysły').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Markdown / podgląd na żywo'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('source-editor')),
        'persisted across tabs',
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 450));
        await tester.tap(find.text('Homelab – konfiguracja').first);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.text('Mercaro – pomysły'), findsNWidgets(2));
      await tester.tap(find.text('Mercaro – pomysły').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('source-editor')))
            .controller!
            .text,
        'persisted across tabs',
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(TextField, 'Szukaj w notatce'),
        findsOneWidget,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Szukaj w notatce'),
        'across',
      );
      await tester.pumpAndSettle();
      final selection = tester
          .widget<TextField>(find.byKey(const Key('source-editor')))
          .controller!
          .selection;
      expect(selection.textInside('persisted across tabs'), 'across');
      await tester.tap(find.text('Mercaro – pomysły').first, buttons: 2);
      await tester.pumpAndSettle();
      expect(find.text('Otwórz w karcie'), findsOneWidget);
      expect(find.text('Przenieś do kosza'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'wiki suggestions complete an existing note from the source editor',
    (tester) async {
      final repo = (await tester.runAsync(seed))!;
      await mount(tester, repo, const Size(1380, 880));
      await tester.tap(find.byTooltip('Markdown / podgląd na żywo'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('source-editor')),
        'See [[Merc',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(SiliqueMenuRow, 'Mercaro – pomysły'),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('source-editor')))
            .controller!
            .text,
        'See [[Mercaro – pomysły]]',
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 450));
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'devices load on opening settings and stay cached across reopening',
    (tester) async {
      final repo = (await tester.runAsync(seed))!;
      var requests = 0;
      repo.session = Session(
        server: 'http://127.0.0.1:18790',
        token: 'test',
        userId: 'test-user',
        email: 'ui@example.com',
      );
      repo.api = SiliqueApi(
        repo.session!.server,
        token: 'test',
        client: MockClient((request) async {
          expect(request.url.path, '/v1/devices');
          requests++;
          return http.Response(
            jsonEncode({
              'devices': [
                {
                  'id': 'test-device-id',
                  'name': 'Laptop testowy',
                  'revoked': 0,
                },
              ],
            }),
            200,
          );
        }),
      );
      await mount(tester, repo, const Size(1380, 880));
      // Icon-only sync indicator: its readable label lives in the tooltip.
      expect(find.text('Lokalnie'), findsNothing);
      expect(find.byTooltip('Lokalnie'), findsOneWidget);
      await tester.tap(find.byTooltip('Ustawienia synchronizacji'));
      await tester.pumpAndSettle();
      expect(requests, 1);
      // The device list lives on the account & sync tab.
      await tester.tap(find.byKey(const Key('settings-tab-account')));
      await tester.pumpAndSettle();
      expect(find.text('Laptop testowy'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(repo.devices!.single['name'], 'Laptop testowy');
      await tester.tap(find.byTooltip('Ustawienia synchronizacji'));
      await tester.pumpAndSettle();
      expect(requests, 2);
      await tester.tap(find.byKey(const Key('settings-tab-account')));
      await tester.pumpAndSettle();
      expect(find.text('Laptop testowy'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      repo.api!.close();
    },
  );
  testWidgets(
    'dropping multiple large photos inserts references and retains original bytes',
    (tester) async {
      final repo = (await tester.runAsync(seed))!;
      await mount(tester, repo, const Size(1380, 880));
      final target = repo.notes[repo.vaults.single.id]!.values.firstWhere(
        (n) => n.title == 'Plan na tydzień',
      );
      final bytes = sampleBmp();
      final drop = tester.widget<DropTarget>(find.byType(DropTarget));
      final point = tester.getCenter(find.byType(DropTarget));
      final details = DropDoneDetails(
        files: [
          DropItemFile.fromData(
            bytes,
            path: '/tmp/Zrzut ekranu 2026-09-24 o 15.33.36.bmp',
          ),
          DropItemFile.fromData(bytes, path: '/tmp/two.bmp'),
        ],
        localPosition: Offset.zero,
        globalPosition: point,
      );
      await tester.runAsync(() async {
        final result = Function.apply(drop.onDragDone!, [details]);
        if (result is Future) await result;
      });
      await tester.pumpAndSettle();
      final body = repo.notes[target.vaultId]![target.id]!.body;
      final images = imageReferencePattern
          .allMatches(body)
          .map((match) => match.group(1)!)
          .toList();
      expect(images, hasLength(2));
      await tester.runAsync(() async {
        for (final id in images) {
          expect(await repo.imageBytes(target.vaultId, id), bytes);
        }
      });
      // Decode the attachment providers, then verify real previews rather
      // than only checking that their Markdown references were saved.
      await tester.runAsync(() async {
        for (final image in tester.widgetList<Image>(find.byType(Image))) {
          await precacheImage(
            image.image,
            tester.element(find.byType(Image).first),
          );
        }
      });
      await tester.pumpAndSettle();
      final previews = tester.widgetList<RawImage>(find.byType(RawImage));
      expect(previews, hasLength(2));
      expect(previews.every((image) => image.image?.width == 1024), isTrue);
      await tester.runAsync(() async {
        await tester.tap(find.text('Mercaro – pomysły').first);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Plan na tydzień').first);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.byType(RawImage), findsNWidgets(2));
      expect(
        tester
            .widgetList<RawImage>(find.byType(RawImage))
            .every((image) => image.image?.width == 1024),
        isTrue,
      );
      expect(body, contains('Zrzut ekranu 2026-09-24 o 15.33.36.bmp'));
      expect(body, contains('two.bmp'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
