import 'dart:typed_data';
import 'dart:io';

import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';
import 'package:silique/storage/native_image_clipboard.dart';

import 'fixtures/image_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'revocation during encryption stores no orphan ordinary attachment',
    () async {
      final dir = Directory.systemTemp.createTempSync('paste-revocation-');
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
      await repo.createVault('Paste');
      final id = repo.vaults.single.id;
      final note = await repo.createNote(id);
      var checks = 0;
      await expectLater(
        repo.addImage(
          id,
          note.id,
          sampleBmp(width: 4, height: 4),
          'image/bmp',
          isCurrent: () => ++checks == 1,
        ),
        throwsStateError,
      );
      expect(repo.storage.pendingImages(id), isEmpty);
      expect(repo.notes[id]![note.id]!.body, isEmpty);
    },
  );
  LiveMarkdownMediaImportRequest request(
    String mime,
    Stream<List<int>> bytes,
  ) => LiveMarkdownMediaImportRequest(
    operationId: 1,
    media: LiveMarkdownPasteMedia(mimeType: mime, openRead: () => bytes),
    cancellation: LiveMarkdownPasteCancellation(),
  );

  test(
    'IME bytes reject MIME spoofing, malformed and oversized images',
    () async {
      final bmp = sampleBmp(width: 4, height: 4);
      await expectLater(
        importClipboardImage(
          request('image/png', Stream.value(bmp)),
          isCurrent: () => true,
        ),
        throwsFormatException,
      );
      await expectLater(
        importClipboardImage(
          request(
            'image/bmp',
            Stream.value(Uint8List.fromList([66, 77, 1, 2])),
          ),
          isCurrent: () => true,
        ),
        throwsA(anything),
      );
      await expectLater(
        importClipboardImage(
          request(
            'image/bmp',
            Stream.value(Uint8List(NativeImageClipboard.maxBytes + 1)),
          ),
          isCurrent: () => true,
        ),
        throwsFormatException,
      );
      final huge = Uint8List.fromList(bmp);
      final header = ByteData.sublistView(huge);
      header.setInt32(18, 20000, Endian.little);
      header.setInt32(22, 20000, Endian.little);
      await expectLater(
        importClipboardImage(
          request('image/bmp', Stream.value(huge)),
          isCurrent: () => true,
        ),
        throwsA(anything),
      );
    },
  );

  test(
    'stream revocation rejects late image with no storage side effects',
    () async {
      var current = true;
      final bytes = sampleBmp(width: 4, height: 4);
      Stream<List<int>> stream() async* {
        yield bytes.sublist(0, 20);
        current = false;
        yield bytes.sublist(20);
      }

      expect(
        await importClipboardImage(
          request('image/bmp', stream()),
          isCurrent: () => current,
        ),
        isNull,
      );
      final cancelled = request('image/bmp', Stream.value(bytes));
      cancelled.cancellation.cancel();
      expect(
        await importClipboardImage(cancelled, isCurrent: () => true),
        isNull,
      );
    },
  );

  test(
    'clipboard owns and clears its byte snapshot after consumption',
    () async {
      final bytes = sampleBmp(width: 4, height: 4);
      final snapshot = NativeImageClipboard.snapshot({
        'media': [
          {'mimeType': 'image/bmp', 'bytes': bytes},
        ],
      });
      expect(snapshot.media.single.size, bytes.length);
      expect((await snapshot.media.single.openRead().single).first, 66);
      await snapshot.dispose();
      expect(bytes.every((byte) => byte == 0), isTrue);
      await snapshot.dispose();
    },
  );
}
