import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/storage/native_window.dart';
import 'package:silique/ui/hidden_notes_page.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

class _Storage extends NativeStorage {
  _Storage(super.root);
  bool failHiddenWrites = false;
  @override
  void putDocument(String vaultId, String noteId, String document) {
    if (failHiddenWrites && vaultId.startsWith('hidden:')) {
      throw FileSystemException('Test disk is full');
    }
    super.putDocument(vaultId, noteId, document);
  }

  @override
  Future<void> mirror(Note note) async {}
}

class _Notebook extends Notebook {
  _Notebook({
    required super.storage,
    required super.keys,
    required super.crypto,
  });
  int activityCalls = 0;
  @override
  void hiddenActivity() {
    activityCalls++;
    super.hiddenActivity();
  }
}

class _GatedCrypto extends TestCrypto {
  Completer<void>? gate;
  @override
  Future<String> seal(List<int> key, String plaintext, String aad) async {
    await gate?.future;
    return super.seal(key, plaintext, aad);
  }
}

const _password = 'hidden password 12345';

Future<Notebook> _fixture(WidgetTester tester, {_GatedCrypto? crypto}) async {
  return (await tester.runAsync(() async {
    final directory = await Directory(
      Platform.environment['TMPDIR'] ?? Directory.systemTemp.path,
    ).createTemp('hidden-page-');
    final repo = _Notebook(
      storage: _Storage(directory.path),
      keys: MemoryKeys(),
      crypto: crypto ?? TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Osobiste');
    await repo.setHiddenPassword(_password);
    await repo.setHiddenAutoLock(null);
    final note = await repo.createNote(repo.vaults.single.id);
    await repo.save(
      note.copyWith(title: 'Private title', body: 'Private body'),
    );
    await repo.hideNote(repo.notes[note.vaultId]![note.id]!);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      final closing = repo.close();
      await _settle(tester);
      await closing;
      await tester.runAsync(() => directory.delete(recursive: true));
    });
    return repo;
  }))!;
}

Future<void> _settle(WidgetTester tester) async {
  // Build the pushed route/start repository work before leaving fake async.
  for (var i = 0; i < 4; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
  }
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester, Notebook repo) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          return Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => HiddenNotesPage(
                    notebook: repo,
                    vaultId: repo.vaults.single.id,
                  ),
                ),
              ),
              child: const Text('Open hidden'),
            ),
          );
        },
      ),
    ),
  );
  await tester.tap(find.text('Open hidden'));
  await _settle(tester);
}

void main() {
  testWidgets('background policy off keeps the unlocked editor available', (
    tester,
  ) async {
    final repo = await _fixture(tester);
    await tester.runAsync(() => repo.setHiddenLockOnBackground(false));
    await _open(tester, repo);
    await tester.tap(find.text('Private title'));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _settle(tester);
    expect(repo.hiddenUnlocked, isTrue);
    expect(find.byKey(const Key('hidden-body')), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('background locks even when pending encrypted save fails', (
    tester,
  ) async {
    final repo = await _fixture(tester);
    await _open(tester, repo);
    await tester.tap(find.text('Private title'));
    await tester.pumpAndSettle();
    (repo.storage as _Storage).failHiddenWrites = true;
    await tester.enterText(
      find.byKey(const Key('hidden-body')),
      'Failed background body',
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await _settle(tester);
    expect(repo.hiddenUnlocked, isFalse);
    expect(find.byKey(const Key('hidden-body')), findsNothing);
    expect(find.byKey(const Key('hidden-error')), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'manual lock still clears plaintext and locks after save failure',
    (tester) async {
      final repo = await _fixture(tester);
      await _open(tester, repo);
      await tester.tap(find.text('Private title'));
      await tester.pumpAndSettle();
      final controller = tester
          .widget<TextField>(find.byKey(const Key('hidden-body')))
          .controller!;
      (repo.storage as _Storage).failHiddenWrites = true;
      await tester.enterText(
        find.byKey(const Key('hidden-body')),
        'Failed current body',
      );
      await tester.tap(find.byKey(const Key('hidden-lock-now')));
      await _settle(tester);
      expect(repo.hiddenUnlocked, isFalse);
      expect(controller.text, isEmpty);
      expect(find.byKey(const Key('hidden-body')), findsNothing);
      expect(find.byKey(const Key('hidden-error')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('move freezes editing and ignores duplicate move taps', (
    tester,
  ) async {
    final crypto = _GatedCrypto();
    final repo = await _fixture(tester, crypto: crypto);
    await _open(tester, repo);
    await tester.tap(find.text('Private title'));
    await tester.pumpAndSettle();
    crypto.gate = Completer<void>();
    await tester.enterText(
      find.byKey(const Key('hidden-body')),
      'Final move snapshot',
    );
    await tester.tap(find.byKey(const Key('hidden-reveal')));
    await tester.pump();
    final frozen = tester
        .widget<TextField>(find.byKey(const Key('hidden-body')))
        .readOnly;
    await tester.tap(find.byKey(const Key('hidden-reveal')));
    crypto.gate!.complete();
    await _settle(tester);
    expect(frozen, isTrue);
    expect(find.byType(HiddenNotesPage), findsNothing);
    expect(
      repo.notes[repo.vaults.single.id]!.values.single.body,
      'Final move snapshot',
    );
    expect(
      (await tester.runAsync(() => repo.hiddenNotes(repo.vaults.single.id)))!,
      isEmpty,
    );
  });

  testWidgets('save failures block exit reveal and quit until retry succeeds', (
    tester,
  ) async {
    final repo = await _fixture(tester);
    await _open(tester, repo);
    await tester.tap(find.text('Private title'));
    await tester.pumpAndSettle();
    final storage = repo.storage as _Storage;
    storage.failHiddenWrites = true;
    await tester.enterText(
      find.byKey(const Key('hidden-body')),
      'Unsaved current body',
    );
    await _settle(tester);
    expect(find.byKey(const Key('hidden-error')), findsOneWidget);
    await tester.pageBack();
    await _settle(tester);
    expect(find.byType(HiddenNotesPage), findsOneWidget);
    await tester.tap(find.byKey(const Key('hidden-reveal')));
    await _settle(tester);
    expect(repo.notes[repo.vaults.single.id], isEmpty);
    final quitFailure = expectLater(
      NativeWindow.instance.beforeClose!(),
      throwsA(isA<FileSystemException>()),
    );
    await _settle(tester);
    await quitFailure;
    storage.failHiddenWrites = false;
    await tester.tap(find.byKey(const Key('hidden-retry')));
    await _settle(tester);
    expect(find.byKey(const Key('hidden-error')), findsNothing);
    await tester.pageBack();
    await _settle(tester);
    expect(find.byType(HiddenNotesPage), findsNothing);
    expect(
      (await tester.runAsync(() => repo.hiddenNotes(repo.vaults.single.id)))!
          .single
          .body,
      'Unsaved current body',
    );
  });

  testWidgets('ordinary vault lock also clears hidden plaintext', (
    tester,
  ) async {
    final repo = await _fixture(tester);
    await _open(tester, repo);
    await tester.tap(find.text('Private title'));
    await tester.pumpAndSettle();
    final controller = tester
        .widget<TextField>(find.byKey(const Key('hidden-body')))
        .controller!;
    repo.lock(repo.vaults.single.id);
    await tester.pump(const Duration(milliseconds: 250));
    expect(controller.text, isEmpty);
    expect(find.byKey(const Key('hidden-body')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'idle timer removes rendered plaintext without further user input',
    (tester) async {
      final repo = await _fixture(tester);
      await _open(tester, repo);
      await tester.tap(find.text('Private title'));
      await tester.pumpAndSettle();
      final controller = tester
          .widget<TextField>(find.byKey(const Key('hidden-body')))
          .controller!;
      await tester.runAsync(
        () => repo.setHiddenAutoLock(const Duration(seconds: 1)),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1250)),
      );
      await _settle(tester);
      expect(repo.hiddenUnlocked, isFalse);
      expect(controller.text, isEmpty);
      expect(find.byKey(const Key('hidden-body')), findsNothing);
      expect(find.text('Private title'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('only real pointer key and input activity resets idle', (
    tester,
  ) async {
    final repo = await _fixture(tester) as _Notebook;
    final beforeOpen = repo.activityCalls;
    await _open(tester, repo);
    // Opening includes one real pointer action to the parent button, but no
    // pointer in the page and no service reads may count as hidden activity.
    expect(repo.activityCalls, beforeOpen);
    await tester.pump(const Duration(seconds: 2));
    expect(repo.activityCalls, beforeOpen);
    await tester.tapAt(const Offset(400, 300));
    expect(repo.activityCalls, greaterThan(beforeOpen));
    await tester.tap(find.text('Private title'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('hidden-title')));
    final beforeKey = repo.activityCalls;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(repo.activityCalls, greaterThan(beforeKey));
    final beforeInput = repo.activityCalls;
    await tester.enterText(
      find.byKey(const Key('hidden-body')),
      'Input activity',
    );
    expect(repo.activityCalls, greaterThan(beforeInput));
    await _settle(tester);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('background covers plaintext before pending saves finish', (
    tester,
  ) async {
    final crypto = _GatedCrypto();
    final repo = await _fixture(tester, crypto: crypto);
    await _open(tester, repo);
    await tester.tap(find.text('Private title'));
    await tester.pumpAndSettle();
    final controller = tester
        .widget<TextField>(find.byKey(const Key('hidden-body')))
        .controller!;
    crypto.gate = Completer<void>();
    await tester.enterText(
      find.byKey(const Key('hidden-body')),
      'Background current body',
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    final clearedImmediately =
        controller.text.isEmpty &&
        find.byKey(const Key('hidden-body')).evaluate().isEmpty;
    crypto.gate!.complete();
    await _settle(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(clearedImmediately, isTrue);
    expect(repo.hiddenUnlocked, isFalse);
    expect(find.text('Ukryte notatki są zablokowane.'), findsOneWidget);
    await tester.runAsync(() => repo.unlockHidden(_password));
    expect(
      (await tester.runAsync(() => repo.hiddenNotes(repo.vaults.single.id)))!
          .single
          .body,
      'Background current body',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('native close waits for hidden save and restores previous hook', (
    tester,
  ) async {
    final crypto = _GatedCrypto();
    final repo = await _fixture(tester, crypto: crypto);
    var parentCalls = 0;
    Future<void> parentFlush() async {
      parentCalls++;
    }

    NativeWindow.instance.beforeClose = parentFlush;
    addTearDown(() => NativeWindow.instance.beforeClose = null);
    await _open(tester, repo);
    await tester.tap(find.text('Private title'));
    await tester.pumpAndSettle();
    crypto.gate = Completer<void>();
    await tester.enterText(
      find.byKey(const Key('hidden-body')),
      'Saved on quit',
    );
    var finished = false;
    final closing = NativeWindow.instance.beforeClose!().then(
      (_) => finished = true,
    );
    await tester.pump();
    final premature = finished;
    final frozen = tester
        .widget<TextField>(find.byKey(const Key('hidden-body')))
        .readOnly;
    crypto.gate!.complete();
    await _settle(tester);
    await closing;
    expect(premature, isFalse);
    expect(
      frozen,
      isTrue,
      reason: 'Quit flush must not accept later unsaved edits',
    );
    expect(parentCalls, 1);
    expect(
      repo.hiddenUnlocked,
      isFalse,
      reason:
          'Successful native close must lock even if the process remains alive',
    );
    expect(await tester.runAsync(() => repo.unlockHidden(_password)), isTrue);
    expect(
      (await tester.runAsync(() => repo.hiddenNotes(repo.vaults.single.id)))!
          .single
          .body,
      'Saved on quit',
    );
    await tester.pumpWidget(const SizedBox());
    expect(NativeWindow.instance.beforeClose, same(parentFlush));
  });

  testWidgets('back waits for encrypted save before leaving', (tester) async {
    final crypto = _GatedCrypto();
    final repo = await _fixture(tester, crypto: crypto);
    await _open(tester, repo);
    await tester.tap(find.text('Private title'));
    await tester.pumpAndSettle();
    crypto.gate = Completer<void>();
    await tester.enterText(
      find.byKey(const Key('hidden-body')),
      'Saved on back',
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    final stillOpen = find.byType(HiddenNotesPage).evaluate().isNotEmpty;
    crypto.gate!.complete();
    await _settle(tester);
    expect(
      stillOpen,
      isTrue,
      reason: 'Never navigate before encryption/persistence completes',
    );
    expect(find.byType(HiddenNotesPage), findsNothing);
    expect(
      (await tester.runAsync(() => repo.hiddenNotes(repo.vaults.single.id)))!
          .single
          .body,
      'Saved on back',
    );
  });

  for (final editor in [false, true]) {
    testWidgets(
      'service lock clears ${editor ? 'editor controllers' : 'list'}',
      (tester) async {
        final repo = await _fixture(tester);
        await _open(tester, repo);
        TextEditingController? title, body;
        if (editor) {
          await tester.tap(find.text('Private title'));
          await tester.pumpAndSettle();
          title = tester
              .widget<TextField>(find.byKey(const Key('hidden-title')))
              .controller;
          body = tester
              .widget<TextField>(find.byKey(const Key('hidden-body')))
              .controller;
        }
        await tester.runAsync(repo.lockHidden);
        await tester.pumpAndSettle();
        expect(find.text('Private title'), findsNothing);
        expect(find.text('Private body'), findsNothing);
        expect(find.byKey(const Key('hidden-title')), findsNothing);
        expect(find.byKey(const Key('hidden-body')), findsNothing);
        expect(title?.text ?? '', isEmpty);
        expect(body?.text ?? '', isEmpty);
        expect(find.byKey(const Key('hidden-new')), findsNothing);
        expect(find.text('Ukryte notatki są zablokowane.'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('manual lock drains edits before forgetting the key', (
    tester,
  ) async {
    final repo = await _fixture(tester);
    await _open(tester, repo);
    await tester.tap(find.text('Private title'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('hidden-body')),
      'Saved before locking',
    );
    await tester.tap(find.byKey(const Key('hidden-lock-now')));
    await _settle(tester);
    expect(repo.hiddenUnlocked, isFalse);
    expect(find.byKey(const Key('hidden-body')), findsNothing);
    expect(await tester.runAsync(() => repo.unlockHidden(_password)), isTrue);
    expect(
      (await tester.runAsync(() => repo.hiddenNotes(repo.vaults.single.id)))!
          .single
          .body,
      'Saved before locking',
    );
    // Unlocking elsewhere must not revive any stale page/controller.
    await tester.pump();
    expect(find.byKey(const Key('hidden-body')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('explicit move saves edits and returns to ordinary notes', (
    tester,
  ) async {
    final repo = await _fixture(tester);
    await _open(tester, repo);
    await tester.tap(find.text('Private title'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('hidden-body')),
      'Moved current body',
    );
    await tester.tap(find.byKey(const Key('hidden-reveal')));
    await _settle(tester);
    expect(find.byType(HiddenNotesPage), findsNothing);
    expect(
      repo.notes[repo.vaults.single.id]!.values.single.body,
      'Moved current body',
    );
    expect(repo.notes[repo.vaults.single.id]!.values.single.hidden, isFalse);
    expect(
      (await tester.runAsync(() => repo.hiddenNotes(repo.vaults.single.id)))!,
      isEmpty,
    );
  });

  testWidgets('creates a new note directly in the hidden store', (
    tester,
  ) async {
    final repo = await _fixture(tester);
    await _open(tester, repo);
    await tester.tap(find.byKey(const Key('hidden-new')));
    await _settle(tester);
    await tester.enterText(find.byKey(const Key('hidden-title')), 'New secret');
    await tester.enterText(
      find.byKey(const Key('hidden-body')),
      'New secret body',
    );
    await _settle(tester);
    final notes = (await tester.runAsync(
      () => repo.hiddenNotes(repo.vaults.single.id),
    ))!;
    expect(notes, hasLength(2));
    expect(
      notes.where((note) => note.title == 'New secret').single.hidden,
      isTrue,
    );
    expect(repo.notes[repo.vaults.single.id], isEmpty);
    expect(
      (repo.storage as NativeStorage).db.select(
        'SELECT payload FROM revisions',
      ),
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('opening and editing keeps the note hidden and encrypted', (
    tester,
  ) async {
    final repo = await _fixture(tester);
    await _open(tester, repo);
    expect(find.text('Private title'), findsOneWidget);
    await tester.tap(find.text('Private title'));
    await tester.pumpAndSettle();
    final title = tester.widget<TextField>(
      find.byKey(const Key('hidden-title')),
    );
    final body = tester.widget<TextField>(find.byKey(const Key('hidden-body')));
    expect(title.controller!.text, 'Private title');
    expect(body.controller!.text, 'Private body');
    expect(title.autocorrect, isFalse);
    expect(title.enableSuggestions, isFalse);
    expect(body.autocorrect, isFalse);
    expect(body.enableSuggestions, isFalse);
    await tester.enterText(
      find.byKey(const Key('hidden-title')),
      'Edited private title',
    );
    await tester.enterText(
      find.byKey(const Key('hidden-body')),
      'Edited private body',
    );
    await _settle(tester);
    final notes = (await tester.runAsync(
      () => repo.hiddenNotes(repo.vaults.single.id),
    ))!;
    expect(notes.single.title, 'Edited private title');
    expect(notes.single.body, 'Edited private body');
    expect(notes.single.hidden, isTrue);
    expect(repo.notes[repo.vaults.single.id], isEmpty);
    final rows = (repo.storage as NativeStorage).db.select(
      'SELECT data FROM documents',
    );
    expect(rows.toString(), isNot(contains('Edited private')));
    await tester.pumpWidget(const SizedBox());
  });
}
