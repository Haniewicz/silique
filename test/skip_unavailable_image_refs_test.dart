import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

const _server = 'https://example.invalid';

Future<Notebook> _repo(Directory dir) async {
  final repo = Notebook(
    storage: NativeStorage(dir.path),
    keys: MemoryKeys(),
    crypto: TestCrypto(),
  );
  await repo.initialize();
  repo.session = Session(
    server: _server,
    token: 'test',
    userId: 'current-user',
    email: 'a@example.invalid',
  );
  repo.accountKey = repo.crypto.randomKey();
  return repo;
}

Json _emptyChanges() => {
  'purged': <Object>[],
  'revisions': <Object>[],
  'cursor': 0,
  'hasMore': false,
};

/// A client that accepts batches only when none of their revisions cite a
/// "missing" image id, and otherwise answers `409 "Image not uploaded yet"`.
MockClient _batchClient({
  required String vaultId,
  required String missingImageId,
  required List<Json> sentBatches,
  required List<String> responses,
}) {
  return MockClient((request) async {
    final path = request.url.path;
    if (path == '/.well-known/silique') {
      return http.Response(
        jsonEncode({
          'api_version': '1',
          'features': {'image_attachments': true},
        }),
        200,
      );
    }
    if (path == '/v1/vaults') {
      return http.Response(
        jsonEncode({'vaults': <Object>[], 'deletedVaults': <Object>[]}),
        200,
      );
    }
    if (request.method == 'PUT' && path == '/v1/vaults/$vaultId') {
      return http.Response(jsonEncode({'version': 1}), 200);
    }
    if (RegExp(r'/images/[a-f0-9-]{36}/chunks/\d+$').hasMatch(path)) {
      return http.Response('{}', 200);
    }
    if (RegExp(r'/images/[a-f0-9-]{36}$').hasMatch(path) &&
        request.method == 'PUT') {
      return http.Response('{}', 200);
    }
    if (request.method == 'POST' && path.endsWith('/batches')) {
      final body = jsonDecode(request.body) as Json;
      sentBatches.add(body);
      final ids = (body['revisions'] as List)
          .map((r) => (r as Json)['id'] as String)
          .toList();
      final citesMissing = (body['revisions'] as List).any((r) {
        final images = (r as Json)['images'] as List?;
        return images != null && images.contains(missingImageId);
      });
      if (citesMissing) {
        responses.add('409-missing');
        return http.Response(
          jsonEncode({'error': 'Image not uploaded yet'}),
          409,
        );
      }
      responses.add('200');
      return http.Response(
        jsonEncode({'batchId': body['batchId'], 'accepted': ids}),
        200,
      );
    }
    if (path.endsWith('/changes')) {
      return http.Response(jsonEncode(_emptyChanges()), 200);
    }
    return http.Response('{}', 200);
  });
}

void main() {
  test(
    'a revision citing an image with no local asset is pushed without that id '
    'and sync finishes',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-skip-img-1-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      vault.owner = 'current-user';
      vault.syncEnabled = true;
      repo.storage.putVault(vault);
      final note = await repo.createNote(vault.id);
      // The body cites an image the client has NEVER stored locally, then the
      // note is edited back to a clean body. The image reference therefore lives
      // only in history, exactly like the reported vault: current notes no
      // longer cite it, but a pending revision still does.
      const missingId = 'c466b777-62fa-4b71-bd4a-e23b0f8e94be';
      await repo.save(note.copyWith(body: '![photo](silique-image:$missingId)'));
      await repo.save(note.copyWith(body: 'clean'));
      // No local asset exists for that id.
      expect(repo.storage.imageAsset(vault.id, missingId), isNull);

      final sentBatches = <Json>[];
      final responses = <String>[];
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: _batchClient(
          vaultId: vault.id,
          missingImageId: missingId,
          sentBatches: sentBatches,
          responses: responses,
        ),
      );

      await repo.sync();

      // No batch was ever rejected for the missing image, so no self-heal path
      // was needed: the very first (and only) batch already omitted the id.
      expect(responses, everyElement('200'));
      expect(responses, isNotEmpty);
      expect(sentBatches, isNotEmpty);
      for (final batch in sentBatches) {
        for (final raw in batch['revisions'] as List) {
          final images = (raw as Json)['images'] as List?;
          expect(images, isNot(contains(missingId)));
        }
      }
      // The note payload was not rewritten: the current body stays clean, and all
      // revisions (including the historical one that cites the image) were sent
      // without the missing image id in their `images`.
      expect(repo.notes[vault.id]![note.id]!.body, 'clean');
      expect(sentBatches.fold<int>(0, (n, b) => n + (b['revisions'] as List).length), greaterThanOrEqualTo(3));
      expect(repo.syncIssues, isEmpty);
    },
  );

  test(
    'a persisted batch citing a missing image plus a present asset is re-sent '
    'under a new batchId with only the present asset',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-skip-img-2-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      vault.owner = 'current-user';
      vault.syncEnabled = true;
      repo.storage.putVault(vault);
      final note = await repo.createNote(vault.id);

      // A present image (has local asset + chunks).
      final reference = await repo.addImage(
        vault.id,
        note.id,
        Uint8List.fromList(List<int>.generate(64, (i) => i)),
        'image/png',
      );
      final presentId = reference.split(':').last;

      // A missing image referenced only in history (not the current body).
      const missingId = 'c466b777-62fa-4b71-bd4a-e23b0f8e94be';
      await repo.save(note.copyWith(body: '![a]($reference)'));
      expect(repo.storage.imageAsset(vault.id, presentId), isNotNull);
      expect(repo.storage.imageAsset(vault.id, missingId), isNull);

      // Pretend a prior pass already persisted a durable batch whose revisions
      // still cite the missing image (the batch was written before the asset
      // vanished). Build it manually so the stored batch genuinely cites it.
      final pendingWires = <Json>[];
      for (final revision in repo.storage.pending(vault.id)) {
        final wire = {
          'id': revision.id,
          'noteId': revision.noteId,
          'parents': revision.parents,
          'payload': revision.payload,
          'images': [presentId, missingId],
        };
        pendingWires.add(wire);
      }
      const staleBatchId = '00000000-0000-0000-0000-000000000000';
      repo.storage.putBatch(vault.id, {
        'batchId': staleBatchId,
        'revisions': pendingWires,
      });

      final sentBatches = <Json>[];
      final responses = <String>[];
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: _batchClient(
          vaultId: vault.id,
          missingImageId: missingId,
          sentBatches: sentBatches,
          responses: responses,
        ),
      );

      await repo.sync();

      expect(responses, everyElement('200'));
      expect(sentBatches, isNotEmpty);
      final sent = sentBatches.first;
      // A fresh batch id replaced the stale one.
      expect(sent['batchId'], isNot(staleBatchId));
      final sentImages = (sent['revisions'] as List)
          .map((r) => (r as Json)['images'] as List?)
          .where((l) => l != null)
          .expand((l) => l!)
          .toSet();
      expect(sentImages, contains(presentId));
      expect(sentImages, isNot(contains(missingId)));
      // Payloads are untouched.
      for (final raw in sent['revisions'] as List) {
        final wire = raw as Json;
        final original = pendingWires.firstWhere(
          (w) => w['id'] == wire['id'],
        );
        expect(wire['payload'], original['payload']);
        expect(wire['noteId'], original['noteId']);
        expect(wire['parents'], original['parents']);
      }
      expect(repo.syncIssues, isEmpty);
    },
  );

  test(
    'a purged image is not marked uploaded and its id is dropped from the batch',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-skip-img-3-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      vault.owner = 'current-user';
      vault.syncEnabled = true;
      repo.storage.putVault(vault);
      final note = await repo.createNote(vault.id);
      final reference = await repo.addImage(
        vault.id,
        note.id,
        Uint8List.fromList(List<int>.generate(64, (i) => i)),
        'image/png',
      );
      final imageId = reference.split(':').last;
      await repo.save(note.copyWith(body: '![photo]($reference)'));
      // The image is pending (uploaded=0) so _uploadImages will try to send it.

      final sentBatches = <Json>[];
      final responses = <String>[];
      var batchCount = 0;
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: MockClient((request) async {
          final path = request.url.path;
          if (path == '/.well-known/silique') {
            return http.Response(
              jsonEncode({
                'api_version': '1',
                'features': {'image_attachments': true},
              }),
              200,
            );
          }
          if (path == '/v1/vaults') {
            return http.Response(
              jsonEncode({'vaults': <Object>[], 'deletedVaults': <Object>[]}),
              200,
            );
          }
          if (request.method == 'PUT' && path == '/v1/vaults/${vault.id}') {
            return http.Response(jsonEncode({'version': 1}), 200);
          }
          if (RegExp(r'/images/[a-f0-9-]{36}/chunks/\d+$').hasMatch(path)) {
            // The server reports the image as purged on the very first chunk.
            return http.Response(jsonEncode({'purged': true}), 200);
          }
          if (RegExp(r'/images/[a-f0-9-]{36}$').hasMatch(path) &&
              request.method == 'PUT') {
            return http.Response('{}', 200);
          }
          if (request.method == 'POST' && path.endsWith('/batches')) {
            batchCount++;
            final body = jsonDecode(request.body) as Json;
            sentBatches.add(body);
            final ids = (body['revisions'] as List)
                .map((r) => (r as Json)['id'] as String)
                .toList();
            final cites = (body['revisions'] as List).any((r) {
              final images = (r as Json)['images'] as List?;
              return images != null && images.contains(imageId);
            });
            if (cites) {
              responses.add('409-missing');
              return http.Response(
                jsonEncode({'error': 'Image not uploaded yet'}),
                409,
              );
            }
            responses.add('200');
            return http.Response(
              jsonEncode({'batchId': body['batchId'], 'accepted': ids}),
              200,
            );
          }
          if (path.endsWith('/changes')) {
            return http.Response(jsonEncode(_emptyChanges()), 200);
          }
          return http.Response('{}', 200);
        }),
      );

      await repo.sync();

      // The image must NOT be marked uploaded after a purged response.
      expect(repo.storage.imageAsset(vault.id, imageId)!['uploaded'], 0);
      // Sync still finished: the retried batch dropped the purged id.
      expect(batchCount, greaterThanOrEqualTo(2));
      expect(responses, contains('200'));
      final last = sentBatches.last;
      for (final raw in last['revisions'] as List) {
        expect((raw as Json)['images'] as List?, isNot(contains(imageId)));
      }
      expect(repo.syncIssues, isEmpty);
    },
  );
}