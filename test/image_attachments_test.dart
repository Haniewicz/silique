import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/storage/native_files.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;
import 'fixtures/image_fixtures.dart';

void main() {
  test(
    'photos larger than 600 kB are accepted and non-images are rejected',
    () async {
      final bytes = sampleBmp();
      final image = await readImageFile(
        XFile.fromData(bytes, name: 'large.BMP'),
      );
      expect(image.bytes.length, greaterThan(600000));
      expect(image.mime, 'image/bmp');
      await expectLater(
        readImageFile(
          XFile.fromData(Uint8List.fromList([1, 2, 3]), name: 'fake.png'),
        ),
        throwsFormatException,
      );
    },
  );
  test('large image survives restart encrypted at rest, keeps the note small and follows permanent deletion', () async {
    final dir = Directory.systemTemp.createTempSync('silique-images-');
    final keys = MemoryKeys();
    Notebook make() => Notebook(
      storage: NativeStorage(dir.path),
      keys: keys,
      crypto: TestCrypto(),
    );
    var repo = make();
    await repo.initialize();
    await repo.createVault('Photos', password: 'protected photos password 123');
    final vault = repo.vaults.single.id;
    final note = await repo.createNote(vault);
    final bytes = sampleBmp();
    final reference = await repo.addImage(vault, note.id, bytes, 'image/bmp');
    final id = reference.split(':').last;
    await repo.save(note.copyWith(body: '![photo]($reference)'));
    expect(repo.notes[vault]![note.id]!.body.length, lessThan(100));
    expect(repo.storage.pendingImages(vault), hasLength(1));
    expect(
      repo.storage
          .imageChunk(vault, id, 0)!
          .contains(base64Encode(bytes.sublist(0, 128))),
      false,
    );
    await repo.close();
    repo = make();
    await repo.initialize();
    await expectLater(repo.imageBytes(vault, id), throwsStateError);
    await repo.unlock(
      repo.vaults.single,
      password: 'protected photos password 123',
    );
    expect(await repo.imageBytes(vault, id), bytes);
    final exported = await repo.noteWithEmbeddedImages(
      repo.notes[vault]![note.id]!,
    );
    expect(exported.body.contains('data:image/bmp;base64,'), true);
    expect(exported.body.contains('silique-image:'), false);
    final copy = await repo.createNote(vault);
    await repo.save(copy.copyWith(body: '![shared]($reference)'));
    await repo.save(repo.notes[vault]![note.id]!.copyWith(deleted: true));
    await repo.purgeNote(repo.notes[vault]![note.id]!);
    expect(await repo.imageBytes(vault, id), bytes);
    await repo.save(repo.notes[vault]![copy.id]!.copyWith(deleted: true));
    await repo.purgeNote(repo.notes[vault]![copy.id]!);
    expect(repo.storage.imageAsset(vault, id), isNull);
    expect(repo.storage.imageChunk(vault, id, 0), isNull);
    await repo.close();
    dir.deleteSync(recursive: true);
  });
}
