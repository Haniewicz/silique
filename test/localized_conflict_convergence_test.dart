import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:silique/core/models.dart';
import 'package:silique/l10n/strings.dart';
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

// Both real pushes must finish before either changes response is captured.
// Then reconcile one buffered real response at a time: the process-global UI
// language cannot race, while neither client can see the other's resolution.
class _SnapshotPair {
  int arrivals = 0;
  final pushed = Completer<void>();
  final captured = [Completer<void>(), Completer<void>()];
  final release = [Completer<void>(), Completer<void>()];
  final pages = <int, Json>{};

  Future<void> arrive() async {
    if (++arrivals == 2) pushed.complete();
    await pushed.future.timeout(const Duration(seconds: 10));
  }
}

class _WireClient extends http.BaseClient {
  _WireClient(this.index);
  final int index;
  final inner = http.Client();
  _SnapshotPair? snapshot;
  int batches = 0, rateLimits = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/batches')) batches++;
    final pair = request.url.path.endsWith('/changes') ? snapshot : null;
    if (pair != null) await pair.arrive();
    final response = await inner.send(request);
    if (response.statusCode == 429) rateLimits++;
    if (pair == null) return response;
    final bytes = await response.stream.toBytes();
    pair.pages[index] = jsonDecode(utf8.decode(bytes)) as Json;
    pair.captured[index].complete();
    await pair.release[index].future.timeout(const Duration(seconds: 10));
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      headers: response.headers,
    );
  }

  @override
  void close() => inner.close();
}

void main() {
  final server = Platform.environment['SILIQUE_TEST_SERVER'];
  for (final hidden in [false, true]) {
    final path = hidden ? 'hidden' : 'ordinary';
    test(
      '$path PL/EN conflict copies have identical legacy content and converge',
      () async {
        final oldLanguage = currentLanguageCode;
        final dirs = List.generate(
          2,
          (_) => Directory.systemTemp.createTempSync('locale-conflict-'),
        );
        final clients = [
          for (final dir in dirs)
            Notebook(
              storage: NativeStorage(dir.path),
              keys: MemoryKeys(),
              crypto: TestCrypto(),
            ),
        ];
        final wire = List.generate(2, (i) => _WireClient(i));
        addTearDown(() async {
          currentLanguageCode = oldLanguage;
          for (final client in clients) {
            await client.close();
          }
          for (final transport in wire) {
            transport.close();
          }
          for (final dir in dirs) {
            dir.deleteSync(recursive: true);
          }
        });
        final a = clients[0], b = clients[1];
        currentLanguageCode = 'pl';
        await a.initialize();
        await b.initialize();
        const password = 'disposable locale account password';
        const hiddenPassword = 'disposable hidden password';
        final recovery = await a.connect(
          server!,
          'locale-$path-${DateTime.now().microsecondsSinceEpoch}@example.com',
          password,
          register: true,
        );
        await a.createVault('Locale convergence');
        final vault = a.vaults.single;
        await a.enableSync(vault);
        if (hidden) await a.setHiddenPassword(hiddenPassword);
        Future<Note> create() =>
            hidden ? a.createHiddenNote(vault.id) : a.createNote(vault.id);
        Future<List<Note>> visible(Notebook client) async => hidden
            ? await client.hiddenNotes(vault.id)
            : client.notes[vault.id]!.values.toList();
        final fresh = await create();
        final original = fresh.copyWith(
          title: 'Authored title (conflict copy)',
          body: 'base',
          folder: 'Authored folder',
        );
        await a.save(original);
        // Existing legacy-looking text is user data, not a display marker.
        final existing = (await create()).copyWith(
          title: 'Existing (kopia konfliktowa)',
          body: 'Existing body must remain verbatim',
        );
        await a.save(existing);
        await a.sync();
        await b.connect(
          server,
          a.session!.email,
          password,
          recoveryKey: recovery,
        );
        await b.sync();
        if (hidden) expect(await b.unlockHidden(hiddenPassword), isTrue);
        for (var i = 0; i < clients.length; i++) {
          currentLanguageCode = i == 0 ? 'pl' : 'en';
          final source = (await visible(clients[i]))
              .singleWhere((n) => n.id == original.id);
          await clients[i].save(
            source.copyWith(
              body: i == 0 ? 'LEFT\n\nuser body' : 'RIGHT\n\nuser body',
            ),
          );
        }
        // Retain all known revisions byte-for-byte through reconciliation.
        final known = <String, Json>{
          for (final client in clients)
            for (final r in client.storage.revisions(vault.id))
              r.id: r.toWire(),
        };
        for (var i = 0; i < clients.length; i++) {
          clients[i].api!.close();
          clients[i].api = SiliqueApi(
            server,
            token: clients[i].session!.token,
            client: wire[i],
          );
        }
        final pair = _SnapshotPair();
        for (final transport in wire) {
          transport.snapshot = pair;
        }
        final syncs = [a.sync(), b.sync()];
        try {
          await Future.wait(pair.captured.map((c) => c.future))
              .timeout(const Duration(seconds: 15));
          expect(
            pair.pages[0],
            pair.pages[1],
            reason: 'Same real remote revisions',
          );
          expect(pair.pages[0]!['hasMore'], isFalse);
          for (var i = 0; i < clients.length; i++) {
            currentLanguageCode = i == 0 ? 'pl' : 'en';
            pair.release[i].complete();
            await syncs[i];
          }
        } finally {
          for (final gate in pair.release) {
            if (!gate.isCompleted) gate.complete();
          }
          for (final transport in wire) {
            transport.snapshot = null;
          }
          await Future.wait(syncs);
        }
        final first = (await visible(a)).singleWhere((n) => n.conflict);
        final second = (await visible(b)).singleWhere((n) => n.conflict);
        expect(first.id, second.id, reason: 'Existing deterministic copy ID');
        expect(
          first.toJson(),
          second.toJson(),
          reason: 'Same conflict revisions must produce identical PL/EN stored content',
        );
        expect(first.title, '${original.title} (kopia konfliktowa)');
        expect(first.folder, original.folder);
        expect(first.createdAt, original.createdAt);
        expect(first.hidden, hidden);
        expect({
          'LEFT\n\nuser body',
          'RIGHT\n\nuser body',
        }, contains(first.body));
        final copyContent = first.toJson();
        Future<void> round() async {
          for (var i = 0; i < clients.length; i++) {
            currentLanguageCode = i == 0 ? 'pl' : 'en';
            await clients[i].sync();
          }
        }

        for (var i = 0; i < 4; i++) {
          await round();
        }
        final before = wire.fold<int>(0, (n, c) => n + c.batches);
        final revisionCounts = clients
            .map((c) => c.storage.revisions(vault.id).length)
            .toList();
        // Swap locale snapshots as well: existing titles must never be rewritten.
        currentLanguageCode = 'en';
        await a.sync();
        currentLanguageCode = 'pl';
        await b.sync();
        await round();
        expect(wire.fold<int>(0, (n, c) => n + c.batches), before);
        expect(
          clients.map((c) => c.storage.revisions(vault.id).length).toList(),
          revisionCounts,
          reason: 'No merge-of-merge revisions after convergence',
        );
        final documents = <Map<String, Json>>[];
        for (final client in clients) {
          final notes = await visible(client);
          expect(notes, hasLength(3), reason: 'No recursive conflict copies');
          expect(notes.where((n) => n.conflict), hasLength(1));
          expect(notes.singleWhere((n) => n.conflict).toJson(), copyContent);
          expect(
            notes.singleWhere((n) => n.id == original.id).title,
            original.title,
          );
          expect(
            notes.singleWhere((n) => n.id == existing.id).toJson(),
            existing.toJson(),
          );
          expect(
            notes.where((n) => n.id != existing.id).map((n) => n.body).toSet(),
            {'LEFT\n\nuser body', 'RIGHT\n\nuser body'},
          );
          expect(client.storage.pending(vault.id), isEmpty);
          expect(client.storage.batch(vault.id), isNull);
          if (hidden) expect(client.notes[vault.id], isEmpty);
          final stored = {
            for (final r in client.storage.revisions(vault.id))
              r.id: r.toWire(),
          };
          for (final entry in known.entries) {
            expect(
              stored[entry.key],
              entry.value,
              reason: 'Immutable original ciphertext/IDs/parents',
            );
          }
          documents.add({for (final n in notes) n.id: n.toJson()});
        }
        expect(documents[0], documents[1]);
        expect(wire.every((c) => c.rateLimits == 0), isTrue);
        // ignore: avoid_print
        print(
          'LOCALE $path: identical legacy copy, 3 notes/client, '
          'lastTwoRoundsBatches=0, empty outboxes, HTTP429=0',
        );
      },
      skip: server == null ? 'Set disposable SILIQUE_TEST_SERVER' : false,
    );
  }
}
