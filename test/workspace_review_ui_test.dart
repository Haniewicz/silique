// Independent review: see docs/workspace-review-2026-10-20.md.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silique/main.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/storage/native_window.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

class ReviewUiStorage extends NativeStorage {
  ReviewUiStorage(super.root);
  Completer<void>? gate;
  Completer<void>? entered;
  @override
  Future<void> mirror(Note note) async {
    final waiting = gate;
    if (waiting != null) {
      gate = null;
      entered?.complete();
      await waiting.future;
    }
  }
}

void main() {
  Future<({Notebook repo, Note note})> seed() async {
    final temp = Directory.systemTemp.createTempSync('silique-review-ui-');
    final repo = Notebook(
      storage: ReviewUiStorage(temp.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Review');
    final v = repo.vaults.single;
    await repo.createFolder(v, 'Source');
    await repo.createFolder(v, 'Destination');
    final note = await repo.createNote(v.id, folder: 'Source');
    await repo.save(note.copyWith(title: 'Active note', body: 'one two one'));
    addTearDown(() async {
      await repo.storage.close();
      temp.deleteSync(recursive: true);
    });
    return (repo: repo, note: repo.notes[v.id]![note.id]!);
  }

  Future<void> mount(
    WidgetTester tester,
    Notebook repo, {
    Size size = const Size(1380, 880),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
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
        child: const SiliqueApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> settleIo(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> editTitle(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('note-title')), text);
    await tester.pump(const Duration(milliseconds: 500));
    await settleIo(tester);
  }

  testWidgets(
    'update/quit save gate drains edits entered during an ongoing save',
    (tester) async {
      final data = (await tester.runAsync(seed))!;
      await mount(tester, data.repo);
      final storage = data.repo.storage as ReviewUiStorage;
      late Completer<void> gate;
      late Completer<void> entered;
      await tester.runAsync(() async {
        gate = Completer<void>();
        entered = Completer<void>();
        storage.gate = gate;
        storage.entered = entered;
      });
      await tester.enterText(find.byKey(const Key('note-title')), 'First save');
      late Future<void> saving;
      await tester.runAsync(() async {
        saving = NativeWindow.instance.beforeClose!();
        await entered.future.timeout(const Duration(seconds: 5));
      });
      await tester.enterText(
        find.byKey(const Key('note-title')),
        'Last keystrokes before update',
      );
      await tester.runAsync(() async {
        gate.complete();
        await saving.timeout(const Duration(seconds: 5));
      });
      await tester.pump();
      expect(
        data.repo.notes[data.note.vaultId]![data.note.id]!.title,
        'Last keystrokes before update',
      );
      expect(
        data.repo.storage.documents(data.note.vaultId)[data.note.id],
        contains('Last keystrokes before update'),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('review: active note keeps bulk pin after next autosave', (
    tester,
  ) async {
    final data = (await tester.runAsync(seed))!;
    await mount(tester, data.repo);
    await tester.tap(find.byKey(const Key('select-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('note-card-${data.note.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bulk-pin')));
    await settleIo(tester);
    expect(data.repo.notes[data.note.vaultId]![data.note.id]!.favorite, true);
    await editTitle(tester, 'Edited after pin');
    expect(
      data.repo.notes[data.note.vaultId]![data.note.id]!.title,
      'Edited after pin',
    );
    expect(data.repo.notes[data.note.vaultId]![data.note.id]!.favorite, true);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'review: active note keeps drag destination after next autosave',
    (tester) async {
      final data = (await tester.runAsync(seed))!;
      await mount(tester, data.repo);
      final card = find.byKey(Key('note-card-${data.note.id}'));
      final dest = find.text('Destination');
      final start = tester.getCenter(card), end = tester.getCenter(dest);
      final gesture = await tester.startGesture(start);
      // Desktop rows become a drag only after a short hold.
      await tester.pump(const Duration(milliseconds: 250));
      await gesture.moveBy(const Offset(12, 0));
      await tester.pump();
      await gesture.moveTo(end);
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await settleIo(tester);
      expect(
        data.repo.notes[data.note.vaultId]![data.note.id]!.folder,
        'Destination',
      );
      await editTitle(tester, 'Edited after drag');
      expect(
        data.repo.notes[data.note.vaultId]![data.note.id]!.title,
        'Edited after drag',
      );
      expect(
        data.repo.notes[data.note.vaultId]![data.note.id]!.folder,
        'Destination',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('review: mobile long press still opens the note context menu', (
    tester,
  ) async {
    final data = (await tester.runAsync(seed))!;
    await mount(tester, data.repo, size: const Size(390, 844));
    await tester.longPress(find.byKey(Key('note-card-${data.note.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Zmień nazwę'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
