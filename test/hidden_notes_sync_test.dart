import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:silique/services/api.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

class _LostPurgeAck extends http.BaseClient {
  final inner = http.Client();
  bool drop = true;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner.send(request);
    if (drop &&
        request.method == 'DELETE' &&
        request.url.path.contains('/notes/')) {
      await response.stream.drain<void>();
      drop = false;
      throw const SocketException('Simulated lost purge acknowledgement');
    }
    return response;
  }

  @override
  void close() => inner.close();
}

void main() {
  final server = Platform.environment['SILIQUE_TEST_SERVER'];
  test('hidden local move retires synced identity; stale device cannot resurrect it; reveal syncs a fresh identity', () async {
    final dirs = List.generate(
      2,
      (_) => Directory.systemTemp.createTempSync('hidden-sync-'),
    );
    final clients = [
      for (final d in dirs)
        Notebook(
          storage: NativeStorage(d.path),
          keys: MemoryKeys(),
          crypto: TestCrypto(),
        ),
    ];
    addTearDown(() async {
      for (final c in clients) {
        await c.close();
      }
      for (final d in dirs) {
        d.deleteSync(recursive: true);
      }
    });
    final a = clients.first, b = clients.last;
    await a.initialize();
    await b.initialize();
    final email = 'hidden-${DateTime.now().microsecondsSinceEpoch}@example.com';
    const password = 'disposable account password';
    final recovery = await a.connect(server!, email, password, register: true);
    await a.createVault('Sync hidden');
    final vault = a.vaults.single;
    await a.enableSync(vault);
    final original = await a.createNote(vault.id);
    await a.save(original.copyWith(title: 'Private', body: 'private body'));
    await a.sync();
    await b.connect(server, email, password, recoveryKey: recovery);
    await b.sync();
    expect(b.notes[vault.id]!.containsKey(original.id), isTrue);
    await a.setHiddenPassword('additional hidden password');
    final transport = _LostPurgeAck();
    a.api!.close();
    a.api = SiliqueApi(server, token: a.session!.token, client: transport);
    await expectLater(
      a.hideNote(a.notes[vault.id]![original.id]!),
      throwsA(isA<SocketException>()),
    );
    expect(
      a.storage.documents('hidden:${vault.id}'),
      hasLength(1),
      reason: 'Lost remote ACK must not discard the encrypted recovery copy',
    );
    await a.sync();
    expect(a.storage.pending(vault.id), isEmpty);
    // A stale offline edit arrives after the move and must not undo the purge.
    await b.save(
      b.notes[vault.id]![original.id]!.copyWith(body: 'stale offline text'),
    );
    await b.sync();
    await a.sync();
    expect(a.notes[vault.id]!.containsKey(original.id), isFalse);
    expect(b.notes[vault.id]!.containsKey(original.id), isFalse);
    expect((await a.hiddenNotes(vault.id)).single.body, 'private body');
    final restored = await a.unhideNote(vault.id, original.id);
    expect(
      restored.id,
      isNot(original.id),
      reason: 'The purged ID is permanently retired by the server',
    );
    expect(restored.createdAt, original.createdAt);
    await a.sync();
    await b.sync();
    expect(b.notes[vault.id]![restored.id]!.body, 'private body');
    expect(a.storage.documents('hidden:${vault.id}'), isEmpty);
  }, skip: server == null ? 'Requires disposable SILIQUE_TEST_SERVER' : false);
}
