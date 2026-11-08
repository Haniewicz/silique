import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/services/api.dart';
import 'package:silique/ui/theme.dart' show muted, syncOff, syncOn;

import 'hidden_notes_home_test.dart' show drainUntil;
import 'sync_status_badge_test.dart'
    show
        badgeIcon,
        badgeSpinner,
        enableSync,
        mount,
        seed,
        syncBadge,
        syncServer;

const _server = 'http://127.0.0.1:18997';

void main() {
  testWidgets('editing a note shows a spinner, never the orange cloud', (
    tester,
  ) async {
    final repo = await seed(tester);
    enableSync(repo);
    await mount(tester, repo, const Size(1380, 880));
    // Idle before any edit: muted outline.
    expect(badgeIcon(Icons.cloud_outlined), findsOneWidget);

    // A local change is pending from the moment the editor changes, before the
    // debounced save and the subsequent sync can run.
    await tester.enterText(
      find.byKey(const Key('note-title'), skipOffstage: false),
      'Zmieniony tytuł',
    );
    await tester.pump();

    final spinner = badgeSpinner();
    expect(spinner, findsOneWidget);
    expect(tester.widget<CircularProgressIndicator>(spinner).color, syncOn);
    expect(badgeIcon(Icons.cloud_off), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a successful sync shows the green check', (tester) async {
    final repo = await seed(tester);
    enableSync(repo);
    await mount(tester, repo, const Size(1380, 880));
    final requests = <String>[];
    repo.api = syncServer(repo, requests);
    await tester.tap(syncBadge());
    await tester.pump();
    await drainUntil(
      tester,
      () => badgeIcon(Icons.cloud_done_outlined).evaluate().isNotEmpty,
    );
    final icon = badgeIcon(Icons.cloud_done_outlined);
    expect(icon, findsOneWidget);
    expect(tester.widget<Icon>(icon).color, syncOn);
    expect(badgeIcon(Icons.cloud_off), findsNothing);
    expect(badgeSpinner(), findsNothing);
    repo.api!.close();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed sync shows the orange cloud-off', (tester) async {
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
    final icon = badgeIcon(Icons.cloud_off);
    expect(icon, findsOneWidget);
    expect(tester.widget<Icon>(icon).color, syncOff);
    repo.api!.close();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a sync-enabled vault that never synced is idle, not failed', (
    tester,
  ) async {
    final repo = await seed(tester);
    enableSync(repo);
    await mount(tester, repo, const Size(1380, 880));
    final icon = badgeIcon(Icons.cloud_outlined);
    expect(icon, findsOneWidget);
    expect(tester.widget<Icon>(icon).color, muted);
    expect(badgeIcon(Icons.cloud_off), findsNothing);
    expect(badgeSpinner(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a local-only vault never shows the orange cloud-off', (
    tester,
  ) async {
    final repo = await seed(tester);
    await mount(tester, repo, const Size(1380, 880));
    final icon = badgeIcon(Icons.cloud_outlined);
    expect(icon, findsOneWidget);
    expect(tester.widget<Icon>(icon).color, muted);
    // Even an edit (which leaves a pending local change) must not paint the
    // orange cloud-off, because a local vault has no connection to lose.
    await tester.enterText(
      find.byKey(const Key('note-title'), skipOffstage: false),
      'Zmieniony lokalnie',
    );
    await tester.pump();
    expect(badgeIcon(Icons.cloud_outlined), findsOneWidget);
    expect(badgeIcon(Icons.cloud_off), findsNothing);
    expect(badgeSpinner(), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
