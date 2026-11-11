import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/ui/dialogs.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

/// Bounded pump: `runAsync` + `pump` with a clocked deadline, never
/// `pumpAndSettle` (the settings account tab keeps a progress indicator and
/// tab animations running in the background).
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  Duration step = const Duration(milliseconds: 25),
  int maxFrames = 400,
}) async {
  for (var i = 0; i < maxFrames; i++) {
    await tester.pump(step);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    if (done()) return;
  }
  fail('condition not reached within the bounded pump');
}

/// A [SiliqueApi] whose [request] is fully faked: no token-bucket throttle, no
/// real network, and every call is recorded.
class FakeApi extends SiliqueApi {
  FakeApi({required this.onRequest})
    : super(
        'https://example.invalid',
        client: MockClient((_) async => http.Response('{}', 200)),
      );

  Future<Json> Function(String method, String path, Json? body) onRequest;

  /// `"METHOD path"` for every request, in call order.
  final requests = <String>[];

  int inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<Json> request(String method, String path, {Json? body}) {
    requests.add('$method $path');
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    return Future<Json>.sync(() => onRequest(method, path, body)).whenComplete(
      () => inFlight--,
    );
  }

  int get approveCount => requests
      .where(
        (r) => r.startsWith('POST /v1/pairings/') && r.endsWith('/approve'),
      )
      .length;
}

/// Spies on the pairing lifecycle so the test can assert "exactly once".
class SpyNotebook extends Notebook {
  SpyNotebook({
    required super.storage,
    required super.keys,
    required super.crypto,
    super.trust,
  });

  int startPairingCalls = 0;
  int finishPairingCalls = 0;
  int syncCalls = 0;

  @override
  Future<void> startPairing() {
    startPairingCalls++;
    return super.startPairing();
  }

  @override
  Future<bool> finishPairing(Json pair) {
    finishPairingCalls++;
    return super.finishPairing(pair);
  }

  @override
  Future<void> sync() {
    syncCalls++;
    return super.sync();
  }
}

/// Builds a pairing row for this (requesting) device against a freshly created
/// approver identity. `approver['public']` is a real X25519 key so
/// `pairingDetails` can derive the code and the envelope can be sealed.
Future<Json> _ownPair(
  WidgetTester tester,
  SpyNotebook repo,
) async {
  final approver = (await tester.runAsync(() => repo.crypto.createIdentity()))!;
  return {
    'id': 'pair-1',
    'requesterId': repo.deviceId,
    'requesterKey': repo.deviceIdentity['public'],
    'approverId': 'approver-1',
    'approverKey': approver['public'],
  };
}

Future<(SpyNotebook, FakeApi)> _setup(WidgetTester tester) async {
  final dir = Directory.systemTemp.createTempSync('silique-pairing-poll-');
  final repo = SpyNotebook(
    storage: NativeStorage(dir.path),
    keys: MemoryKeys(),
    crypto: TestCrypto(),
  );
  await tester.runAsync(() => repo.initialize());
  repo.session = Session(
    server: 'https://example.invalid',
    token: 'test-only',
    userId: 'test-user',
    email: 'test@example.invalid',
  );
  final api = FakeApi(
    onRequest: (method, path, body) async {
      if (path == '/v1/devices') {
        return {
          'devices': [
            {'id': repo.deviceId, 'name': 'Ten komputer', 'revoked': 0},
          ],
        };
      }
      if (path == '/v1/pairings') {
        return {'pairings': <Object>[]};
      }
      if (path == '/v1/vaults') {
        return {'vaults': <Object>[], 'deletedVaults': <Object>[]};
      }
      return <String, dynamic>{};
    },
  );
  repo.api = api;
  return (repo, api);
}

Future<void> _mountAccount(
  WidgetTester tester,
  Notebook repo, {
  Duration pollInterval = const Duration(milliseconds: 20),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: Dialog(
            child: SettingsPanel(
              notebook: repo,
              onChanged: () {},
              pollInterval: pollInterval,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(find.byKey(const Key('settings-tab-account')));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets(
    'requesting device shows its pairing code automatically, without any tap',
    (tester) async {
      final (repo, api) = await _setup(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        repo.api?.close();
        await repo.storage.close();
      });
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final own = await _ownPair(tester, repo);
      api.onRequest = (method, path, body) async {
        if (path == '/v1/pairings') {
          return {'pairings': [own]};
        }
        if (path == '/v1/devices') {
          return {
            'devices': [
              {'id': repo.deviceId, 'name': 'Ten komputer', 'revoked': 0},
            ],
          };
        }
        if (path == '/v1/vaults') {
          return {'vaults': <Object>[], 'deletedVaults': <Object>[]};
        }
        return <String, dynamic>{};
      };

      // No tap on "Odśwież parowanie" or any button: mounting alone must make
      // the derived code appear on the account tab within the deadline.
      await _mountAccount(tester, repo);
      await _pumpUntil(
        tester,
        () =>
            find
                .text('Porównaj ten kod na obu urządzeniach:')
                .evaluate()
                .isNotEmpty,
      );

      expect(
        find.text('Porównaj ten kod na obu urządzeniach:'),
        findsOneWidget,
      );
      // The code itself (a mono SelectableText) is present too.
      expect(find.byType(SelectableText), findsWidgets);
    },
  );

  testWidgets(
    'finishPairing and sync each run exactly once and show the paired message',
    (tester) async {
      final (repo, api) = await _setup(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        repo.api?.close();
        await repo.storage.close();
      });
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final own = await _ownPair(tester, repo);
      api.onRequest = (method, path, body) async {
        if (path == '/v1/pairings') {
          return {'pairings': [own]};
        }
        if (path == '/v1/devices') {
          return {
            'devices': [
              {'id': repo.deviceId, 'name': 'Ten komputer', 'revoked': 0},
            ],
          };
        }
        if (path == '/v1/vaults') {
          return {'vaults': <Object>[], 'deletedVaults': <Object>[]};
        }
        return <String, dynamic>{};
      };

      await _mountAccount(tester, repo);

      // Approver offers: without an envelope the code appears (no finish yet).
      await _pumpUntil(
        tester,
        () =>
            find
                .text('Porównaj ten kod na obu urządzeniach:')
                .evaluate()
                .isNotEmpty,
      );
      expect(repo.finishPairingCalls, 0);

      // Human approval produces the envelope; the requesting device must then
      // finish + sync exactly once each and show the paired message.
      final details = (await tester.runAsync(() => repo.pairingDetails(own)))!;
      final envelope = await tester.runAsync(
        () => repo.crypto.seal(
          details.key,
          base64Encode(repo.crypto.randomKey()),
          details.context,
        ),
      );
      own['envelope'] = envelope;

      await _pumpUntil(
        tester,
        () =>
            find
                .text('Urządzenie sparowane. Notatki są odblokowane.')
                .evaluate()
                .isNotEmpty,
      );

      expect(repo.finishPairingCalls, 1);
      expect(repo.syncCalls, 1);
      expect(repo.accountKey, isNotNull);
    },
  );

  testWidgets(
    'no POST /v1/pairings/:id/approve ever leaves the poll, even after envelope',
    (tester) async {
      final (repo, api) = await _setup(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        repo.api?.close();
        await repo.storage.close();
      });
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final own = await _ownPair(tester, repo);
      api.onRequest = (method, path, body) async {
        if (path == '/v1/pairings') {
          return {'pairings': [own]};
        }
        if (path == '/v1/devices') {
          return {
            'devices': [
              {'id': repo.deviceId, 'name': 'Ten komputer', 'revoked': 0},
            ],
          };
        }
        if (path == '/v1/vaults') {
          return {'vaults': <Object>[], 'deletedVaults': <Object>[]};
        }
        return <String, dynamic>{};
      };

      await _mountAccount(tester, repo);

      await _pumpUntil(
        tester,
        () =>
            find
                .text('Porównaj ten kod na obu urządzeniach:')
                .evaluate()
                .isNotEmpty,
      );
      final details = (await tester.runAsync(() => repo.pairingDetails(own)))!;
      final envelope = await tester.runAsync(
        () => repo.crypto.seal(
          details.key,
          base64Encode(repo.crypto.randomKey()),
          details.context,
        ),
      );
      own['envelope'] = envelope;

      // Let the envelope path run to completion and keep polling a while.
      await _pumpUntil(tester, () => repo.accountKey != null);
      await _pumpUntil(
        tester,
        () => api.requests.where((r) => r == 'GET /v1/pairings').length >= 6,
        maxFrames: 600,
      );

      expect(api.approveCount, 0);
      expect(
        api.requests.where(
          (r) =>
              r.startsWith('POST /v1/pairings/') && r.endsWith('/approve'),
        ),
        isEmpty,
      );
    },
  );

  testWidgets(
    'disposing the panel stops polling — no further requests in 300 ms',
    (tester) async {
      final (repo, api) = await _setup(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        repo.api?.close();
        await repo.storage.close();
      });
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      api.onRequest = (method, path, body) async {
        if (path == '/v1/devices') {
          return {
            'devices': [
              {'id': repo.deviceId, 'name': 'Ten komputer', 'revoked': 0},
            ],
          };
        }
        if (path == '/v1/pairings') {
          return {'pairings': <Object>[]};
        }
        if (path == '/v1/vaults') {
          return {'vaults': <Object>[], 'deletedVaults': <Object>[]};
        }
        return <String, dynamic>{};
      };

      await _mountAccount(tester, repo);
      await _pumpUntil(
        tester,
        () => api.requests.where((r) => r == 'GET /v1/devices').isNotEmpty,
      );

      // Close the dialog: dispose() must cancel the timer.
      await tester.pumpWidget(const SizedBox());
      final before = api.requests.length;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(api.requests.length, before);
    },
  );

  testWidgets(
    'a slow API never runs two polls in parallel (avalanche guard)',
    (tester) async {
      final (repo, api) = await _setup(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        repo.api?.close();
        await repo.storage.close();
      });
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // Interval 20 ms; each response takes 5× longer (100 ms fake time).
      const interval = Duration(milliseconds: 20);
      const slow = Duration(milliseconds: 100);
      api.onRequest = (method, path, body) async {
        await Future<void>.delayed(slow);
        if (path == '/v1/devices') {
          return {
            'devices': [
              {'id': repo.deviceId, 'name': 'Ten komputer', 'revoked': 0},
            ],
          };
        }
        if (path == '/v1/pairings') {
          return {'pairings': <Object>[]};
        }
        if (path == '/v1/vaults') {
          return {'vaults': <Object>[], 'deletedVaults': <Object>[]};
        }
        return <String, dynamic>{};
      };

      await _mountAccount(tester, repo, pollInterval: interval);

      // Advance a 500 ms fake-time window: many timer ticks fire, but the
      // `_polling` guard must keep at most one request in flight at any moment.
      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
      }

      expect(api.requests.length, greaterThanOrEqualTo(1));
      expect(api.maxInFlight, lessThanOrEqualTo(1));

      // Dispose the tree (cancels the periodic timer) and flush the fake-clock
      // delays still in flight, so no timer outlives the test body — the
      // binding asserts on pending timers before tearDown runs.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets(
    'a silent poll never blocks the UI and keeps the status message',
    (tester) async {
      final (repo, api) = await _setup(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        repo.api?.close();
        await repo.storage.close();
      });
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() async {
        await repo.keys.write('nova.deviceName', 'Testowe urzadzenie');
      });

      // Drive a full pairing so a success message is on screen; the poll must
      // neither replace it nor take the UI busy while it keeps running.
      final own = await _ownPair(tester, repo);
      api.onRequest = (method, path, body) async {
        if (path == '/v1/devices') {
          return {
            'devices': [
              {'id': repo.deviceId, 'name': 'Ten komputer', 'revoked': 0},
            ],
          };
        }
        if (path == '/v1/pairings') return {'pairings': [own]};
        if (path == '/v1/vaults') {
          return {'vaults': <Object>[], 'deletedVaults': <Object>[]};
        }
        return <String, dynamic>{};
      };
      await _mountAccount(tester, repo);
      await _pumpUntil(
        tester,
        () => find
            .text('Porównaj ten kod na obu urządzeniach:')
            .evaluate()
            .isNotEmpty,
      );
      final details = (await tester.runAsync(() => repo.pairingDetails(own)))!;
      own['envelope'] = await tester.runAsync(
        () => repo.crypto.seal(
          details.key,
          base64Encode(repo.crypto.randomKey()),
          details.context,
        ),
      );
      await _pumpUntil(
        tester,
        () => find
            .textContaining('Notatki są odblokowane')
            .evaluate()
            .isNotEmpty,
      );

      final before = api.requests.length;
      await _pumpUntil(
        tester,
        () => api.requests.length >= before + 8,
        maxFrames: 600,
      );

      // The message survived every poll cycle, the manual refresh stays usable
      // (busy is false, never a spinner) and no error text was produced.
      expect(find.textContaining('Notatki są odblokowane'), findsOneWidget);
      final refresh = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Odśwież parowanie'),
      );
      expect(refresh.onPressed, isNotNull);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('Exception'), findsNothing);
    },
  );

  testWidgets('the poll surfaces an error only after three failed cycles', (
    tester,
  ) async {
    final (repo, api) = await _setup(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      repo.api?.close();
      await repo.storage.close();
    });
    await tester.binding.setSurfaceSize(const Size(1100, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    api.onRequest = (method, path, body) async {
      if (path == '/v1/pairings') throw Exception('poll-boom');
      if (path == '/v1/devices') {
        return {
          'devices': [
            {'id': repo.deviceId, 'name': 'Ten komputer', 'revoked': 0},
          ],
        };
      }
      if (path == '/v1/vaults') {
        return {'vaults': <Object>[], 'deletedVaults': <Object>[]};
      }
      return <String, dynamic>{};
    };

    int pairingsCalls() =>
        api.requests.where((r) => r == 'GET /v1/pairings').length;

    // A slow interval keeps the cycle count controllable: the bounded pump
    // steps 25 ms, so 200 ms per tick means one call per observation.
    await _mountAccount(
      tester,
      repo,
      pollInterval: const Duration(milliseconds: 200),
    );
    // One or two failed cycles: the error stays hidden (no flapping banner).
    await _pumpUntil(tester, () => pairingsCalls() >= 1);
    expect(find.textContaining('poll-boom'), findsNothing);
    await _pumpUntil(tester, () => pairingsCalls() >= 2);
    expect(find.textContaining('poll-boom'), findsNothing);
    // The third consecutive failure is surfaced.
    await _pumpUntil(tester, () => pairingsCalls() >= 3);
    await _pumpUntil(
      tester,
      () => find.textContaining('poll-boom').evaluate().isNotEmpty,
      maxFrames: 600,
    );
    expect(find.textContaining('poll-boom'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });
}
