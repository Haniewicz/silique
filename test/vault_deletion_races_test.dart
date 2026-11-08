import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/core/models.dart';
import 'package:silique/main.dart';
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/ui/image_attachment_provider.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;
import 'fixtures/image_fixtures.dart';

class _UnlockGate extends TestCrypto {
  Completer<void>? entered, release;
  @override
  Future<String> open(List<int> key, String envelope, String context) async {
    if (context.startsWith('silique:2:local-vault:') && release != null) {
      final gate = release!;
      release = null;
      entered!.complete();
      await gate.future;
    }
    return super.open(key, envelope, context);
  }
}

class _DecodeGate extends AutomatedTestWidgetsFlutterBinding {
  Completer<void>? release;
  int started = 0, finished = 0;
  @override
  Future<ui.Codec> instantiateImageCodecWithSize(
    ui.ImmutableBuffer buffer, {
    ui.TargetImageSizeCallback? getTargetSize,
  }) async {
    started++;
    await release?.future;
    final codec = await super.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: getTargetSize,
    );
    finished++;
    return codec;
  }
}

void main() {
  final binding = _DecodeGate();
  test(
    'delayed unlock cannot repersist or expose a remotely deleted locked vault',
    () async {
      final dir = Directory.systemTemp.createTempSync('vault-delete-unlock-');
      final crypto = _UnlockGate();
      final repo = Notebook(
        storage: NativeStorage(dir.path),
        keys: MemoryKeys(),
        crypto: crypto,
      );
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.initialize();
      await repo.createVault('Target');
      final target = repo.vaults.single;
      await repo.createNote(target.id);
      target.owner = 'http://127.0.0.1|owner';
      target.syncEnabled = true;
      repo.storage.putVault(target);
      repo.lock(target.id);
      repo.session = Session(
        server: 'http://127.0.0.1',
        token: 'fixture',
        userId: 'owner',
        email: 'fixture@example.com',
      );
      repo.api = SiliqueApi(
        'http://127.0.0.1',
        client: MockClient(
          (r) async => http.Response(
            jsonEncode({
              'vaults': [],
              'deletedVaults': [target.id],
            }),
            200,
          ),
        ),
      );
      final release = Completer<void>();
      crypto.release = release;
      crypto.entered = Completer<void>();
      final unlock = repo.unlock(target);
      final check = expectLater(unlock, throwsStateError);
      await crypto.entered!.future;
      await repo.sync();
      release.complete();
      await check;
      expect(repo.vaults, isEmpty);
      expect(repo.unlocked, isEmpty);
      expect(repo.notes, isEmpty);
      expect(repo.storage.isVaultDeleted(target.id), isTrue);
    },
  );
  test('stale live-vault list followed by scoped HTTP410 retires local outbox in the same sync', () async {
    final dir = Directory.systemTemp.createTempSync('vault-delete-stale-get-');
    final repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    addTearDown(() async {
      await repo.close();
      dir.deleteSync(recursive: true);
    });
    await repo.initialize();
    await repo.createVault('Target');
    final target = repo.vaults.single;
    await repo.createNote(target.id);
    target.owner = 'http://127.0.0.1|owner';
    target.syncEnabled = true;
    repo.storage.putVault(target);
    repo.accountKey = repo.localKey;
    repo.session = Session(
      server: 'http://127.0.0.1',
      token: 'fixture',
      userId: 'owner',
      email: 'fixture@example.com',
    );
    var rejected = 0;
    repo.api = SiliqueApi(
      'http://127.0.0.1',
      client: MockClient((r) async {
        if (r.url.path == '/v1/vaults') {
          return http.Response(
            jsonEncode({
              'vaults': [
                {
                  'id': target.id,
                  'metadata': target.metadata,
                  'keyWrap': target.keyWrap,
                  'version': target.version,
                },
              ],
              'deletedVaults': [],
            }),
            200,
          );
        }
        rejected++;
        return http.Response('{"error":"vault_deleted"}', 410, request: r);
      }),
    );
    await repo.sync();
    expect(rejected, 1);
    expect(repo.vaults, isEmpty);
    expect(repo.storage.pending(target.id), isEmpty);
    expect(repo.storage.isVaultDeleted(target.id), isTrue);
  });
  for (final late in [false, true]) {
    testWidgets(
      'actual Home deletion evicts ordinary attachment pending/live/keepAlive cache late=$late',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        late Notebook repo;
        late Directory dir;
        await tester.runAsync(() async {
          dir = Directory.systemTemp.createTempSync('vault-delete-image-');
          repo = Notebook(
            storage: NativeStorage(dir.path),
            keys: MemoryKeys(),
            crypto: TestCrypto(),
          );
          await repo.initialize();
          await repo.createVault('Target');
          final note = await repo.createNote(repo.vaults.single.id);
          final image = await repo.addImage(
            note.vaultId,
            note.id,
            sampleBmp(width: 4, height: 4),
            'image/bmp',
          );
          await repo.save(note.copyWith(body: '![synthetic]($image)'));
        });
        binding.release = late ? Completer<void>() : null;
        final started = binding.started, finished = binding.finished;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [notebookProvider.overrideWithValue(repo)],
            child: const SiliqueApp(),
          ),
        );
        for (
          var i = 0;
          i < 80 &&
              (late
                  ? binding.started == started
                  : binding.finished == finished);
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(binding.started, greaterThan(started));
        final providers = tester
            .widgetList<Image>(find.byType(Image))
            .map((w) => w.image)
            .whereType<AttachmentImage>()
            .toList();
        expect(providers, isNotEmpty);
        var deleted = false;
        Object? deletionError;
        final deletion = repo
            .deleteVault(repo.vaults.single, confirmation: 'Target')
            .then(
              (_) {
                deleted = true;
              },
              onError: (Object error) {
                deletionError = error;
                deleted = true;
              },
            );
        for (var i = 0; i < 80 && !deleted; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(
          deleted,
          isTrue,
          reason: 'bounded drain of deletion and native revocation',
        );
        expect(deletionError, isNull);
        await deletion;
        await tester.pump();
        final gate = binding.release;
        binding.release = null;
        gate?.complete();
        for (var i = 0; i < 30; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        for (final provider in providers) {
          final status = binding.imageCache.statusForKey(provider);
          expect(status.pending || status.live || status.keepAlive, isFalse);
        }
        expect(repo.vaults, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        final close = repo.close();
        await tester.pump();
        await tester.runAsync(() => close);
        dir.deleteSync(recursive: true);
      },
    );
  }
}
