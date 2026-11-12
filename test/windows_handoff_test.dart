import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/windows_update_handoff.dart';
import 'package:silique/core/server_trust.dart';
import 'package:silique/storage/startup_notebook.dart';

import 'update_quiescence_test.dart' show Keys;

void main() {
  test(
    'failed flush restores admission and permits a verified preparation retry',
    () async {
      final dir = Directory.systemTemp.createTempSync(
        'silique-handoff-failure-',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final repo = await openStartupNotebook(dir.path, keys: Keys(), trustStore: InMemoryTrustStore());
      final blocked = <bool>[];
      await expectLater(
        PreparedWindowsUpdate.prepare(
          notebook: repo,
          blockInput: blocked.add,
          beforeClose: () async => throw StateError('save failed'),
          close: () async {},
        ),
        throwsStateError,
      );
      expect(blocked, [true, false]);
      await repo.createVault('Admission restored');
      final handoff = await PreparedWindowsUpdate.prepare(
        notebook: repo,
        blockInput: blocked.add,
        beforeClose: () async {},
        close: () async {},
      );
      await handoff.abort();
      await repo.createVault('Admission restored before launch');
      expect(blocked, [true, false, true, false]);
      await repo.close();
    },
  );
  test('failed postlaunch close keeps admission and input fenced across abort and close retry', () async {
    final dir = Directory.systemTemp.createTempSync('silique-handoff-close-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final repo = await openStartupNotebook(dir.path, keys: Keys(), trustStore: InMemoryTrustStore());
    addTearDown(repo.close);
    final blocked = <bool>[];
    var closes = 0;
    final handoff = await PreparedWindowsUpdate.prepare(
      notebook: repo,
      blockInput: blocked.add,
      beforeClose: () async {},
      close: () async {
        closes++;
        if (closes == 1) throw StateError('window close failed');
      },
    );
    await expectLater(handoff.commit(), throwsStateError);
    await handoff.abort();
    expect(blocked, [true]);
    await expectLater(repo.createVault('Must remain fenced'), throwsStateError);
    await handoff.commit();
    await handoff.abort();
    expect(closes, 2);
    expect(blocked, [true]);
    await expectLater(repo.createVault('Still fenced'), throwsStateError);
  });

  test(
    'synchronous close failure can retry without reopening input or writes',
    () async {
      final dir = Directory.systemTemp.createTempSync(
        'silique-handoff-sync-close-',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final repo = await openStartupNotebook(dir.path, keys: Keys(), trustStore: InMemoryTrustStore());
      addTearDown(repo.close);
      final blocked = <bool>[];
      var closes = 0;
      final handoff = await PreparedWindowsUpdate.prepare(
        notebook: repo,
        blockInput: blocked.add,
        beforeClose: () async {},
        close: () {
          if (++closes == 1) throw StateError('synchronous close failure');
          return Future.value();
        },
      );
      await expectLater(handoff.commit(), throwsStateError);
      await handoff.commit();
      expect(closes, 2);
      await handoff.abort();
      expect(blocked, [true]);
      await expectLater(repo.createVault('Still fenced'), throwsStateError);
    },
  );

  test(
    'prepare fences mutations before editor flush and admits only the flush',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-handoff-flush-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final keys = Keys();
      final repo = await openStartupNotebook(dir.path, keys: keys, trustStore: InMemoryTrustStore());
      await repo.createVault('Synthetic');
      final note = await repo.createNote(repo.vaults.single.id);
      final entered = Completer<void>(), release = Completer<void>();
      final preparing = PreparedWindowsUpdate.prepare(
        notebook: repo,
        blockInput: (_) {},
        beforeClose: () async {
          entered.complete();
          await release.future;
          await repo.save(note.copyWith(body: 'last editor flush'));
        },
        close: () async {},
      );
      await entered.future;
      final lateWrite = repo.save(note.copyWith(body: 'late background write'));
      final rejected = expectLater(lateWrite, throwsStateError);
      release.complete();
      final handoff = await preparing;
      await rejected;
      expect(repo.notes[note.vaultId]![note.id]!.body, 'last editor flush');
      await handoff.abort();
      await repo.close();
      final reopened = await openStartupNotebook(dir.path, keys: keys, trustStore: InMemoryTrustStore());
      expect(reopened.notes[note.vaultId]![note.id]!.body, 'last editor flush');
      await reopened.close();
    },
  );
  test(
    'abort cannot reopen writes while a commit close is still pending',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-handoff-race-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final repo = await openStartupNotebook(dir.path, keys: Keys(), trustStore: InMemoryTrustStore());
      final release = Completer<void>();
      final handoff = await PreparedWindowsUpdate.prepare(
        notebook: repo,
        blockInput: (_) {},
        beforeClose: () async {},
        close: () => release.future,
      );
      final committing = handoff.commit();
      final aborting = handoff.abort();
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        repo.createVault('Must remain fenced'),
        throwsStateError,
      );
      release.complete();
      await committing;
      await aborting;
      repo.resumeAfterUpdate();
      await repo.close();
    },
  );
  test(
    'commit closes only after preparation and keeps writes fenced',
    () async {
      final dir = Directory.systemTemp.createTempSync(
        'silique-handoff-commit-',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final repo = await openStartupNotebook(dir.path, keys: Keys(), trustStore: InMemoryTrustStore());
      var closed = 0;
      final handoff = await PreparedWindowsUpdate.prepare(
        notebook: repo,
        blockInput: (_) {},
        beforeClose: () async {},
        close: () async {
          closed++;
        },
      );
      await handoff.commit();
      await handoff.abort();
      expect(closed, 1);
      await expectLater(repo.createVault('Late write'), throwsStateError);
      repo.resumeAfterUpdate();
      await repo.close();
    },
  );
  test('handoff blocks input, performs full close preparation and restores writes on cancellation', () async {
    final dir = Directory.systemTemp.createTempSync('silique-handoff-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final repo = await openStartupNotebook(dir.path, keys: Keys(), trustStore: InMemoryTrustStore());
    await repo.createVault('Keep');
    final events = <String>[];
    final handoff = await PreparedWindowsUpdate.prepare(
      notebook: repo,
      blockInput: (value) => events.add('blocked:$value'),
      beforeClose: () async {
        events.add('flush-lock-checkpoint');
      },
      close: () async {
        events.add('close');
      },
    );
    expect(events, ['blocked:true', 'flush-lock-checkpoint']);
    await expectLater(repo.createVault('Rejected'), throwsStateError);
    await handoff.abort();
    await repo.createVault('Usable again');
    expect(events, ['blocked:true', 'flush-lock-checkpoint', 'blocked:false']);
    await repo.close();
  });
}
