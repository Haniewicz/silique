import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
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
import 'package:silique/ui/theme.dart' show muted, syncOff, syncOn;

import 'core_test.dart' show MemoryKeys, TestCrypto;
import 'hidden_notes_home_test.dart' show drainUntil;

const _server = 'http://127.0.0.1:18997';
const _syncKey = Key('sync-status');

Finder syncBadge() => find.byKey(_syncKey);

/// The icon inside the badge, so assertions stay scoped to the indicator even
/// though `Icons.cloud_outlined` also marks local vaults in the vault chooser.
Finder badgeIcon(IconData icon) =>
    find.descendant(of: syncBadge(), matching: find.byIcon(icon));

Finder badgeSpinner() => find.descendant(
  of: syncBadge(),
  matching: find.byType(CircularProgressIndicator),
);

/// Logical window size (mount pins devicePixelRatio to 1).
Size windowSize(WidgetTester tester) =>
    tester.view.physicalSize / tester.view.devicePixelRatio;

Future<Notebook> seed(WidgetTester tester, {int notes = 1}) async {
  late Notebook repo;
  late Directory dir;
  await tester.runAsync(() async {
    dir = Directory.systemTemp.createTempSync('silique-sync-badge-');
    repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Osobiste');
    for (var i = 0; i < notes; i++) {
      final note = await repo.createNote(repo.vaults.single.id);
      await repo.save(note.copyWith(title: 'Notatka $i', body: 'treść $i'));
    }
  });
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    var closed = false;
    final close = repo.close().then((_) => closed = true);
    await drainUntil(tester, () => closed);
    await close;
    await tester.runAsync(() async {
      dir.deleteSync(recursive: true);
    });
  });
  return repo;
}

Future<void> mount(WidgetTester tester, Notebook repo, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [notebookProvider.overrideWithValue(repo)],
      child: const SiliqueApp(),
    ),
  );
  await tester.pumpAndSettle();
}

/// Wires the vault for sync and a live session, but no API yet: the UI must
/// never start (and hang on) a network pass while mounting under fake async.
void enableSync(Notebook repo) {
  repo.session = Session(
    server: _server,
    token: 'test',
    userId: 'test-user',
    email: 'sync@example.com',
  );
  final vault = repo.vaults.single;
  vault.owner = repo.session!.owner;
  vault.syncEnabled = true;
  repo.storage.putVault(vault);
  repo.accountKey = repo.crypto.randomKey();
  // A real sync pass would have acknowledged every seeded revision.
  repo.storage.acknowledge(
    vault.id,
    repo.storage.pending(vault.id).map((r) => r.id).toList(),
  );
}

/// A mock server whose empty-but-valid responses let `repo.sync()` succeed.
/// [gate] delays the vault listing so a test can observe the syncing state.
SiliqueApi syncServer(
  Notebook repo,
  List<String> requests, {
  Completer<void>? gate,
}) {
  final vault = repo.vaults.single;
  return SiliqueApi(
    _server,
    token: 'test',
    client: MockClient((request) async {
      requests.add('${request.method} ${request.url.path}');
      final path = request.url.path;
      if (path == '/v1/vaults') {
        if (gate != null) await gate.future;
        return http.Response(
          jsonEncode({
            'vaults': [
              {
                'id': vault.id,
                'version': vault.version,
                'keyWrap': jsonEncode({'mode': 'local', 'wrapped': ''}),
                'metadata': '',
              },
            ],
            'deletedVaults': const [],
          }),
          200,
        );
      }
      if (path == '/v1/vaults/${vault.id}/changes') {
        return http.Response(
          jsonEncode({
            'purged': const [],
            'revisions': const [],
            'cursor': repo.storage.cursor(vault.id),
            'hasMore': false,
          }),
          200,
        );
      }
      return http.Response(jsonEncode({'error': 'missing'}), 404);
    }),
  );
}

/// Hovers the badge with a mouse so the Tooltip paints its description.
Future<void> hoverBadge(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(mouse.removePointer);
  await mouse.addPointer(location: const Offset(10, 10));
  await tester.pump();
  await mouse.moveTo(tester.getCenter(syncBadge()));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('no sync: muted cloud-outline alone in the bottom-right corner', (
    tester,
  ) async {
    final repo = await seed(tester, notes: 0);
    await mount(tester, repo, const Size(1380, 880));
    // No note is open, yet the indicator owns the bottom-right corner.
    expect(find.text('Przestrzeń na dobrą myśl'), findsOneWidget);
    expect(syncBadge(), findsOneWidget);
    // A local-only vault is idle — never a failed connection — so it shows the
    // muted outline, not the orange cloud-off.
    final icon = badgeIcon(Icons.cloud_outlined);
    expect(icon, findsOneWidget);
    expect(tester.widget<Icon>(icon).color, muted);
    expect(badgeIcon(Icons.cloud_off), findsNothing);
    // The readable state lives in the tooltip, never in painted text.
    expect(find.text('Lokalnie'), findsNothing);
    expect(find.byTooltip('Lokalnie'), findsOneWidget);
    final rect = tester.getRect(syncBadge());
    final size = windowSize(tester);
    expect(size.width - rect.right, lessThanOrEqualTo(20));
    expect(size.height - rect.bottom, lessThanOrEqualTo(20));
    expect(tester.takeException(), isNull);
  });

  testWidgets('open note: words, last change and sync share the corner', (
    tester,
  ) async {
    final repo = await seed(tester);
    await mount(tester, repo, const Size(1380, 880));
    // The first note is auto-selected, so the footer shows all indicators.
    expect(syncBadge(), findsOneWidget);
    final words = find.textContaining('słów');
    final change = find.textContaining('Ostatnia zmiana');
    expect(words, findsOneWidget);
    expect(change, findsOneWidget);
    final size = windowSize(tester);
    final sync = tester.getRect(syncBadge());
    final wordsRect = tester.getRect(words);
    final changeRect = tester.getRect(change);
    // Sync is the last item in the bottom-right corner; words and the last
    // change sit on the same row, to its left.
    expect(size.width - sync.right, lessThanOrEqualTo(30));
    expect(size.height - sync.bottom, lessThanOrEqualTo(20));
    expect(sync.left, greaterThan(changeRect.right));
    expect(changeRect.left, greaterThan(wordsRect.right));
    expect((sync.center.dy - wordsRect.center.dy).abs(), lessThan(8));
    expect((sync.center.dy - changeRect.center.dy).abs(), lessThan(8));
    expect(tester.takeException(), isNull);
  });

  testWidgets('synced: green cloud, hover tooltip, tap runs a manual sync', (
    tester,
  ) async {
    final repo = await seed(tester);
    enableSync(repo);
    await mount(tester, repo, const Size(1380, 880));
    // Before the first successful pass the vault is idle (muted outline).
    expect(badgeIcon(Icons.cloud_outlined), findsOneWidget);
    expect(find.byTooltip('Lokalnie'), findsOneWidget);

    final requests = <String>[];
    repo.api = syncServer(repo, requests);
    // Tapping the icon triggers the manual sync.
    await tester.tap(syncBadge());
    await tester.pump();
    await drainUntil(
      tester,
      () => find.byIcon(Icons.cloud_done_outlined).evaluate().isNotEmpty,
    );

    expect(requests, contains('GET /v1/vaults'));
    final icon = find.byIcon(Icons.cloud_done_outlined);
    expect(icon, findsOneWidget);
    expect(tester.widget<Icon>(icon).color, syncOn);
    expect(find.byIcon(Icons.cloud_off), findsNothing);
    // Icon-only presentation: the label is painted solely inside the tooltip.
    expect(find.text('Zsynchronizowano • E2EE'), findsNothing);
    expect(
      tester.widget<Tooltip>(syncBadge()).message,
      'Zsynchronizowano • E2EE',
    );
    await hoverBadge(tester);
    expect(find.text('Zsynchronizowano • E2EE'), findsOneWidget);
    expect(tester.takeException(), isNull);
    repo.api!.close();
  });

  testWidgets('syncing: small green spinner with the syncing tooltip', (
    tester,
  ) async {
    final repo = await seed(tester);
    enableSync(repo);
    await mount(tester, repo, const Size(1380, 880));
    final requests = <String>[];
    final gate = Completer<void>();
    repo.api = syncServer(repo, requests, gate: gate);

    await tester.tap(syncBadge());
    // Bounded pumps only: an active spinner never lets pumpAndSettle finish.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(requests, contains('GET /v1/vaults'));
    final spinner = find.byType(CircularProgressIndicator);
    expect(spinner, findsOneWidget);
    expect(tester.widget<CircularProgressIndicator>(spinner).color, syncOn);
    expect(find.byIcon(Icons.cloud_off), findsNothing);
    expect(find.text('Synchronizacja…'), findsNothing);
    expect(tester.widget<Tooltip>(syncBadge()).message, 'Synchronizacja…');

    gate.complete();
    await drainUntil(
      tester,
      () => find.byIcon(Icons.cloud_done_outlined).evaluate().isNotEmpty,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.cloud_done_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
    repo.api!.close();
  });

  testWidgets('failed sync unifies into the orange cloud-off icon', (
    tester,
  ) async {
    final repo = await seed(tester);
    enableSync(repo);
    await mount(tester, repo, const Size(1380, 880));
    repo.api = SiliqueApi(
      _server,
      token: 'test',
      client: MockClient((request) async {
        if (request.url.path == '/v1/events') {
          return http.Response(jsonEncode({'error': 'missing'}), 404);
        }
        return http.Response(jsonEncode({'error': 'offline'}), 503);
      }),
    );

    await tester.tap(syncBadge());
    await tester.pump();
    await drainUntil(
      tester,
      () => find
          .byTooltip('Offline • zmiany zachowane lokalnie')
          .evaluate()
          .isNotEmpty,
    );
    final icon = find.byIcon(Icons.cloud_off);
    expect(icon, findsOneWidget);
    expect(tester.widget<Icon>(icon).color, syncOff);
    expect(find.text('Offline • zmiany zachowane lokalnie'), findsNothing);
    expect(tester.takeException(), isNull);
    repo.api!.close();
  });

  testWidgets('phone list: corner icon clears the navigation and the FAB', (
    tester,
  ) async {
    final repo = await seed(tester);
    await mount(tester, repo, const Size(390, 844));
    expect(syncBadge(), findsOneWidget);
    final rect = tester.getRect(syncBadge());
    final size = windowSize(tester);
    // Right edge of the window, in the strip between the bottom navigation
    // and the floating action button.
    expect(size.width - rect.right, lessThanOrEqualTo(20));
    expect(size.height - rect.bottom, inInclusiveRange(50, 110));
    expect(
      rect.overlaps(tester.getRect(find.byType(FloatingActionButton))),
      isFalse,
    );
    // The bottom navigation keeps every item, unobstructed and tappable.
    for (final label in ['Notatki', 'Dziennik', 'Szukaj', 'Ustawienia']) {
      final item = find.text(label).last;
      expect(item, findsOneWidget, reason: 'bottom nav keeps $label');
      expect(rect.overlaps(tester.getRect(item)), isFalse);
      expect(rect.contains(tester.getCenter(item)), isFalse);
    }
    await tester.tap(find.text('Ustawienia').last);
    await tester.pumpAndSettle();
    expect(find.text('Konto i synchronizacja'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone editor: words, change and sync in the corner', (
    tester,
  ) async {
    final repo = await seed(tester);
    await mount(tester, repo, const Size(390, 844));
    final note = repo.notes[repo.vaults.single.id]!.values.first;
    await tester.tap(find.byKey(Key('note-card-${note.id}')));
    await tester.pumpAndSettle();
    expect(syncBadge(), findsOneWidget);
    expect(find.textContaining('słów'), findsOneWidget);
    final change = find.textContaining('Ostatnia zmiana');
    expect(change, findsOneWidget);
    final rect = tester.getRect(syncBadge());
    final size = windowSize(tester);
    expect(size.width - rect.right, lessThanOrEqualTo(30));
    expect(size.height - rect.bottom, lessThanOrEqualTo(20));
    expect(rect.left, greaterThan(tester.getRect(change).right));
    // The editor replaces the bottom navigation; no second indicator exists.
    expect(find.text('Ustawienia'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone drawer keeps the corner indicator in place', (
    tester,
  ) async {
    final repo = await seed(tester);
    await mount(tester, repo, const Size(390, 844));
    final before = tester.getRect(syncBadge());
    await tester.tap(find.byTooltip('Foldery i vaulty'));
    await tester.pumpAndSettle();
    expect(syncBadge(), findsOneWidget);
    expect(tester.getRect(syncBadge()), before);
    tester.state<ScaffoldState>(find.byType(Scaffold).first).closeDrawer();
    await tester.pumpAndSettle();
    expect(syncBadge(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
