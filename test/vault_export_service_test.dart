import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/storage/vault_export.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;
import 'fixtures/image_fixtures.dart';

void main() {
  late Directory root;
  late Notebook repo;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('silique-export-service-');
    repo = Notebook(
      storage: NativeStorage('${root.path}/store'),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Local');
  });
  tearDown(() async {
    await repo.close();
    root.deleteSync(recursive: true);
  });

  test('trash is excluded and empty folders are included in the plan', () async {
    final id = repo.vaults.single.id;
    final vault = repo.vaults.single;
    final kept = await repo.createNote(id);
    await repo.save(kept.copyWith(title: 'Kept', folder: 'A'));
    final trashed = await repo.createNote(id);
    await repo.save(trashed.copyWith(title: 'Trashed', folder: 'A'));
    await repo.save(trashed.copyWith(deleted: true));
    await repo.createFolder(vault, 'Pusty');

    final data = await repo.prepareVaultExport(id);
    expect(data.notes.map((n) => n.title), isNot(contains('Trashed')));
    expect(data.notes.map((n) => n.title), contains('Kept'));
    expect(data.folders, contains('Pusty'));

    final plan = buildVaultExportPlan(data.notes, folders: data.folders);
    expect(plan.notes.map((n) => n.title), isNot(contains('Trashed')));
    expect(plan.folders, contains('Pusty'));
  });

  test('hidden notes stay out unless hidden is unlocked and includeHidden', () async {
    final id = repo.vaults.single.id;
    final visible = await repo.createNote(id);
    await repo.save(visible.copyWith(title: 'Visible'));

    await repo.setHiddenPassword('hidden password 123');
    final hidden = await repo.createNote(id);
    await repo.save(hidden.copyWith(title: 'Secret'));
    await repo.hideNote(repo.notes[id]![hidden.id]!);
    await repo.lockHidden();

    // includeHidden=false: hidden notes are not part of the export.
    final without = await repo.prepareVaultExport(id);
    expect(without.notes.map((n) => n.title), isNot(contains('Secret')));

    // Unlock hidden, includeHidden=true: hidden notes enter the plan.
    final ok = await repo.unlockHidden('hidden password 123');
    expect(ok, isTrue);
    final withHidden = await repo.prepareVaultExport(id, includeHidden: true);
    expect(withHidden.notes.map((n) => n.title), contains('Secret'));
    final plan = buildVaultExportPlan(withHidden.notes);
    expect(plan.hiddenCount, 1);
    expect(
      plan.notes.singleWhere((n) => n.hidden).relativeDir,
      '_hidden',
    );
  });

  test('missing image bytes do not abort the export', () async {
    final id = repo.vaults.single.id;
    const missing =
        'aaaaaaaa-0000-0000-0000-000000000001'; // never uploaded
    final note = await repo.createNote(id);
    await repo.save(note.copyWith(body: '![x](silique-image:$missing)'));

    final data = await repo.prepareVaultExport(id);
    // The reference is not resolved (no such image) but the export completes.
    expect(data.images, isEmpty);
    final plan = buildVaultExportPlan(data.notes, images: data.images);
    expect(plan.skippedImageCount, 1);
    expect(plan.notes.single.body, contains('silique-image:$missing'));
  });

  test('resolved images are collected and rewritten in the plan', () async {
    final id = repo.vaults.single.id;
    final note = await repo.createNote(id);
    final bytes = sampleBmp();
    final reference = await repo.addImage(id, note.id, bytes, 'image/bmp');
    await repo.save(note.copyWith(body: '![photo]($reference)'));

    final data = await repo.prepareVaultExport(id);
    expect(data.images, hasLength(1));
    final idOnly = reference.split(':').last;
    expect(data.images[idOnly], bytes);

    final plan = buildVaultExportPlan(data.notes, images: data.images);
    expect(plan.images.single.fileName, endsWith('.bmp'));
    expect(plan.notes.single.body, isNot(contains('silique-image:')));
  });
}