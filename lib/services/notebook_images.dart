part of 'notebook.dart';

// Chunking keeps large photos out of the note revision DAG and below the
// existing encrypted HTTP payload limit. There is no per-image size cap.
const imageChunkBytes = 512 * 1024;
final imageReferencePattern = RegExp(r'silique-image:([a-f0-9-]{36})');

extension NotebookImages on Notebook {
  Future<_PreparedImage> _prepareImage(
    String vaultId,
    String noteId,
    Uint8List bytes,
    String mime,
  ) async {
    _requireLiveVault(vaultId);
    final key = unlocked[vaultId];
    if (key == null) {
      throw StateError(
        tr('Najpierw odblokuj vault.', 'Unlock the vault first.'),
      );
    }
    if (bytes.isEmpty ||
        ![
          'image/png',
          'image/jpeg',
          'image/gif',
          'image/webp',
          'image/bmp',
        ].contains(mime)) {
      throw FormatException(
        tr('Nieobsługiwany format zdjęcia.', 'Unsupported image format.'),
      );
    }
    final id = _uuid.v4();
    final count = (bytes.length / imageChunkBytes).ceil();
    final manifest = await crypto.seal(
      key,
      jsonEncode({
        'id': id,
        'noteId': noteId,
        'mime': mime,
        'bytes': bytes.length,
        'chunks': count,
        'sha256': base64Encode((await Sha256().hash(bytes)).bytes),
      }),
      'silique:1:image:$vaultId:$id:manifest',
    );
    final chunks = <String>[];
    for (var i = 0; i < count; i++) {
      final end = ((i + 1) * imageChunkBytes).clamp(0, bytes.length);
      chunks.add(
        await crypto.seal(
          key,
          base64Encode(Uint8List.sublistView(bytes, i * imageChunkBytes, end)),
          'silique:1:image:$vaultId:$id:$i',
        ),
      );
    }
    if (!identical(unlocked[vaultId], key)) {
      throw StateError(
        tr('Vault został zablokowany.', 'The vault has been locked.'),
      );
    }
    _requireLiveVault(vaultId);
    return _PreparedImage(noteId, id, manifest, chunks);
  }

  void _storePreparedImage(String vaultId, _PreparedImage image) {
    storage.putImageAsset(
      vaultId,
      image.noteId,
      image.id,
      image.manifest,
      uploaded: false,
    );
    for (var i = 0; i < image.chunks.length; i++) {
      storage.putImageChunk(vaultId, image.id, i, image.chunks[i]);
    }
  }

  Future<String> addImage(
    String vaultId,
    String noteId,
    Uint8List bytes,
    String mime, {
    bool Function()? isCurrent,
  }) => serialized(() async {
    if (isCurrent != null && !isCurrent()) {
      throw StateError('Image paste was revoked.');
    }
    final image = await _prepareImage(vaultId, noteId, bytes, mime);
    if (isCurrent != null && !isCurrent()) {
      throw StateError('Image paste was revoked.');
    }
    storage.atomic(() => _storePreparedImage(vaultId, image));
    return 'silique-image:${image.id}';
  });

  Future<Json> _imageManifest(
    String vaultId,
    String id,
    String envelope,
  ) async {
    final key = unlocked[vaultId];
    if (key == null) {
      throw StateError(tr('Vault jest zablokowany.', 'The vault is locked.'));
    }
    final manifest = jsonDecode(
      await crypto.open(key, envelope, 'silique:1:image:$vaultId:$id:manifest'),
    ) as Json;
    final size = manifest['bytes'], count = manifest['chunks'];
    if (manifest['id'] != id ||
        manifest['noteId'] is! String ||
        size is! int ||
        size <= 0 ||
        count is! int ||
        count != (size / imageChunkBytes).ceil() ||
        manifest['sha256'] is! String ||
        ![
          'image/png',
          'image/jpeg',
          'image/gif',
          'image/webp',
          'image/bmp',
        ].contains(manifest['mime'])) {
      throw FormatException(
        tr('Nieprawidłowy manifest zdjęcia.', 'Invalid image manifest.'),
      );
    }
    return manifest;
  }

  Future<Json> _ensureImage(String vaultId, String id) async {
    _requireLiveVault(vaultId);
    var local = storage.imageAsset(vaultId, id);
    final vault = vaults.firstWhere((v) => v.id == vaultId);
    final client = vault.syncEnabled && vault.owner == session?.owner
        ? api
        : null;
    if (local == null) {
      if (client == null) {
        throw StateError(
          tr(
            'Zdjęcie nie zostało jeszcze pobrane na to urządzenie.',
            'The image has not been downloaded to this device yet.',
          ),
        );
      }
      final remote = await client.request(
        'GET',
        '/v1/vaults/$vaultId/images/$id',
      );
      final envelope = remote['manifest'] as String;
      final manifest = await _imageManifest(vaultId, id, envelope);
      if (remote['noteId'] != manifest['noteId'] ||
          remote['chunkCount'] != manifest['chunks']) {
        throw FormatException(
          tr('Niezgodna tożsamość zdjęcia.', 'Image identity mismatch.'),
        );
      }
      storage.putImageAsset(
        vaultId,
        manifest['noteId'] as String,
        id,
        envelope,
        uploaded: true,
      );
      local = storage.imageAsset(vaultId, id)!;
    }
    final manifest = await _imageManifest(
      vaultId,
      id,
      local['manifest'] as String,
    );
    for (var i = 0; i < (manifest['chunks'] as int); i++) {
      if (storage.imageChunk(vaultId, id, i) != null) continue;
      if (client == null) {
        throw StateError(
          tr(
            'Zdjęcie nie zostało jeszcze w całości pobrane.',
            'The image has not finished downloading yet.',
          ),
        );
      }
      final remote = await client.request(
        'GET',
        '/v1/vaults/$vaultId/images/$id/chunks/$i',
      );
      final payload = remote['payload'] as String;
      final plain = base64Decode(
        await crypto.open(
          unlocked[vaultId]!,
          payload,
          'silique:1:image:$vaultId:$id:$i',
        ),
      );
      final expected = i == (manifest['chunks'] as int) - 1
          ? (manifest['bytes'] as int) - i * imageChunkBytes
          : imageChunkBytes;
      if (plain.length != expected) {
        throw FormatException(
          tr('Niepełny fragment zdjęcia.', 'Incomplete image chunk.'),
        );
      }
      storage.putImageChunk(vaultId, id, i, payload);
    }
    return manifest;
  }

  Future<Uint8List> imageBytes(String vaultId, String id) async {
    _requireLiveVault(vaultId);
    final manifest = await _ensureImage(vaultId, id);
    final key = unlocked[vaultId];
    if (key == null) {
      throw StateError(tr('Vault jest zablokowany.', 'The vault is locked.'));
    }
    final bytes = BytesBuilder(copy: false);
    for (var i = 0; i < (manifest['chunks'] as int); i++) {
      bytes.add(
        base64Decode(
          await crypto.open(
            key,
            storage.imageChunk(vaultId, id, i)!,
            'silique:1:image:$vaultId:$id:$i',
          ),
        ),
      );
    }
    final result = bytes.takeBytes();
    if (result.length != manifest['bytes'] ||
        base64Encode((await Sha256().hash(result)).bytes) !=
            manifest['sha256']) {
      throw FormatException(
        tr(
          'Weryfikacja integralności zdjęcia nie powiodła się.',
          'Image integrity verification failed.',
        ),
      );
    }
    if (!identical(unlocked[vaultId], key)) {
      throw StateError(
        tr('Vault został zablokowany.', 'The vault has been locked.'),
      );
    }
    _requireLiveVault(vaultId);
    return result;
  }

  Future<Note> noteWithEmbeddedImages(Note note) async {
    var body = note.body;
    final ids = imageReferencePattern
        .allMatches(body)
        .map((match) => match.group(1)!)
        .toSet();
    for (final id in ids) {
      final manifest = await _ensureImage(note.vaultId, id);
      final bytes = await imageBytes(note.vaultId, id);
      body = body.replaceAll(
        'silique-image:$id',
        'data:${manifest['mime']};base64,${base64Encode(bytes)}',
      );
    }
    return note.copyWith(body: body);
  }

  Future<void> _uploadImages(Vault vault) async {
    final pending = storage.pendingImages(vault.id);
    if (pending.isEmpty) return;
    final discovery = await api!.request('GET', '/.well-known/silique');
    if ((discovery['features'] as Json?)?['image_attachments'] != true) {
      throw StateError(
        tr(
          'Serwer wymaga aktualizacji do obsługi zdjęć. Zdjęcia i notatki pozostają zapisane lokalnie.',
          'The server needs an update to support images. Images and notes remain saved locally.',
        ),
      );
    }
    for (final asset in pending) {
      final id = asset['id'] as String;
      final manifest = await _imageManifest(
        vault.id,
        id,
        asset['manifest'] as String,
      );
      var purged = false;
      for (var i = 0; i < (manifest['chunks'] as int); i++) {
        final response = await api!.request(
          'PUT',
          '/v1/vaults/${vault.id}/images/$id/chunks/$i',
          body: {
            'noteId': asset['note_id'],
            'payload': storage.imageChunk(vault.id, id, i)!,
          },
        );
        if (response['purged'] == true) {
          purged = true;
          break;
        }
      }
      if (!purged) {
        await api!.request(
          'PUT',
          '/v1/vaults/${vault.id}/images/$id',
          body: {
            'noteId': asset['note_id'],
            'manifest': asset['manifest'],
            'chunkCount': manifest['chunks'],
          },
        );
      }
      storage.markImageUploaded(vault.id, id);
    }
  }

  Future<void> _cacheImages(Vault vault) async {
    final ids = <String>{
      for (final note in notes[vault.id]?.values ?? <Note>[])
        if (!note.deleted)
          ...imageReferencePattern
              .allMatches(note.body)
              .map((m) => m.group(1)!),
    };
    for (final id in ids) {
      await _ensureImage(vault.id, id);
    }
  }
}

class _PreparedImage {
  _PreparedImage(this.noteId, this.id, this.manifest, this.chunks);
  final String noteId, id, manifest;
  final List<String> chunks;
}
