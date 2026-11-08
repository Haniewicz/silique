import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/main.dart';
import 'package:silique/services/android_widgets.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/ui/home.dart';
import 'package:silique/ui/theme.dart';

import 'hidden_notes_home_test.dart'
    show fixture, drainUntil, chooseHiddenFolder;

Future<({AndroidWidgets bridge, List<Map<String, Object?>> pending})>
mountWidgets(WidgetTester tester, Notebook repo) async {
  const channel = MethodChannel('silique.notes/widgets-home-test');
  final pending = <Map<String, Object?>>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'takePendingAction') {
          return pending.isEmpty ? null : pending.removeAt(0);
        }
        return null;
      });
  final bridge = AndroidWidgets(
    notebook: repo,
    channel: channel,
    enabled: true,
  );
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [notebookProvider.overrideWithValue(repo)],
      child: MaterialApp(
        theme: siliqueTheme(),
        home: HomeScreen(androidWidgets: bridge),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (bridge: bridge, pending: pending);
}

Future<void> sendAction(WidgetTester tester, AndroidWidgets bridge) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        bridge.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('actionAvailable'),
        ),
        (_) {},
      );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('queued note creation survives real vault unlock in Home', (
    tester,
  ) async {
    final repo = await fixture(tester);
    final id = repo.vaults.single.id;
    repo.lock(id);
    final data = await mountWidgets(tester, repo);
    data.pending.add({
      'action': 'newNote',
      'requestId': 'locked-home-1',
      'vaultId': id,
    });
    await sendAction(tester, data.bridge);
    expect(repo.notes[id], isNull);
    var unlocked = false;
    final unlock = repo.unlock(repo.vaults.single).then((_) => unlocked = true);
    await drainUntil(
      tester,
      () =>
          unlocked &&
          repo.notes[id]!.length == 2 &&
          find.byKey(const Key('note-title')).evaluate().isNotEmpty,
    );
    await unlock;
    expect(
      repo.notes[id]!.values.where((n) => n.title == 'Bez tytułu'),
      hasLength(1),
    );
  });

  testWidgets(
    'rapid launcher taps are serialized instead of lost at the busy gate',
    (tester) async {
      final repo = await fixture(tester);
      final id = repo.vaults.single.id;
      final data = await mountWidgets(tester, repo);
      for (var i = 0; i < 3; i++) {
        data.pending.add({
          'action': 'newNote',
          'requestId': 'rapid-$i',
          'vaultId': id,
        });
      }
      await sendAction(tester, data.bridge);
      await drainUntil(
        tester,
        () =>
            repo.notes[id]!.length == 4 &&
            find.byKey(const Key('note-title')).evaluate().isNotEmpty,
      );
      expect(
        repo.notes[id]!.values.where((n) => n.title == 'Bez tytułu'),
        hasLength(3),
      );
    },
  );

  testWidgets(
    'launcher leaves and locks hidden mode before creating an ordinary note',
    (tester) async {
      final repo = await fixture(tester);
      final id = repo.vaults.single.id;
      await tester.runAsync(() async {
        await repo.setHiddenPassword('test hidden password');
        await repo.setHiddenAutoLock(null);
        await repo.createHiddenNote(id);
      });
      final data = await mountWidgets(tester, repo);
      await chooseHiddenFolder(tester);
      expect(repo.hiddenUnlocked, isTrue);
      data.pending.add({
        'action': 'newNote',
        'requestId': 'leave-hidden-1',
        'vaultId': id,
      });
      await sendAction(tester, data.bridge);
      await drainUntil(
        tester,
        () =>
            !repo.hiddenUnlocked &&
            repo.notes[id]!.length == 2 &&
            find.byKey(const Key('note-title')).evaluate().isNotEmpty,
      );
      expect(repo.storage.documents('hidden:$id'), hasLength(1));
      expect(repo.notes[id]!.values.every((n) => !n.hidden), isTrue);
    },
  );
  testWidgets(
    'widget creates an ordinary default-title note and opens its editor',
    (tester) async {
      final repo = await fixture(tester);
      final id = repo.vaults.single.id;
      final data = await mountWidgets(tester, repo);
      data.pending.add({
        'action': 'newNote',
        'requestId': 'new-1',
        'vaultId': id,
      });
      await sendAction(tester, data.bridge);
      await drainUntil(
        tester,
        () =>
            repo.notes[id]!.length == 2 &&
            find.byKey(const Key('note-title')).evaluate().isNotEmpty,
      );
      expect(
        repo.notes[id]!.values.where((n) => n.title == 'Bez tytułu'),
        hasLength(1),
      );
      expect(find.byKey(const Key('note-title')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('note-title')))
            .controller!
            .text,
        'Bez tytułu',
      );
      await sendAction(tester, data.bridge);
      expect(repo.notes[id], hasLength(2));
    },
  );

  testWidgets('journal action creates today entry and keeps journal semantics', (
    tester,
  ) async {
    final repo = await fixture(tester);
    final id = repo.vaults.single.id;
    final data = await mountWidgets(tester, repo);
    data.pending.add({
      'action': 'journal',
      'requestId': 'journal-1',
      'vaultId': id,
    });
    await sendAction(tester, data.bridge);
    await drainUntil(
      tester,
      () =>
          repo.notes[id]!.values.any((n) => n.journalDate != null) &&
          find.byKey(const Key('note-title')).evaluate().isNotEmpty,
    );
    final note = repo.notes[id]!.values.singleWhere(
      (n) => n.journalDate != null,
    );
    final today = DateTime.now();
    final date =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    expect(note.journalDate, date);
    expect(note.title, isNotEmpty);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('note-title')))
          .controller!
          .text,
      note.title,
    );
  });

  testWidgets(
    'openNote selects exact target across vaults and flushes former editor',
    (tester) async {
      final repo = await fixture(tester);
      final first = repo.vaults.single.id;
      late String second, targetId;
      await tester.runAsync(() async {
        await repo.createVault('Second');
        second = repo.vaults.last.id;
        final note = await repo.createNote(second);
        await repo.save(note.copyWith(title: 'Widget target'));
        targetId = note.id;
        await repo.rememberVault(first);
      });
      final data = await mountWidgets(tester, repo);
      await tester.tap(find.text('Visible secret'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('note-title')),
        'Unsaved before widget',
      );
      data.pending.add({
        'action': 'openNote',
        'requestId': 'open-1',
        'vaultId': second,
        'noteId': targetId,
      });
      await sendAction(tester, data.bridge);
      await drainUntil(
        tester,
        () =>
            repo.lastVaultId == second &&
            repo.notes[first]!.values.single.title == 'Unsaved before widget',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('note-title')))
            .controller!
            .text,
        'Widget target',
      );
    },
  );
}
