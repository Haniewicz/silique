import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/services/api.dart';

void main() {
  testWidgets('wall-clock adjustments cannot mint HTTP admission tokens', (
    tester,
  ) async {
    var sends = 0;
    var wallOffset = Duration.zero;
    final api = SiliqueApi(
      'http://127.0.0.1',
      now: () => tester.binding.clock.now().add(wallOffset),
      elapsed: () => tester.binding.clock.now().difference(DateTime(2000)),
      client: MockClient((r) async {
        sends++;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(api.close);
    final pending = <Future<void>>[];
    for (var burst = 0; burst < 21; burst++) {
      wallOffset += const Duration(milliseconds: 4200);
      for (var i = 0; i < 12; i++) {
        pending.add(
          api
              .request('GET', '/clock-jump')
              .then<void>(
                (_) {},
                onError: (Object error) {
                  expect(error, isA<http.ClientException>());
                },
              ),
        );
      }
      await tester.pump();
    }
    expect(
      sends,
      12,
      reason: 'Wall-clock jumps must not replenish a real-time HTTP budget',
    );
    wallOffset = const Duration(days: -7);
    await tester.pump(const Duration(milliseconds: 349));
    expect(
      sends,
      12,
      reason: 'Backward wall changes cannot stall or refill admission',
    );
    await tester.pump(const Duration(milliseconds: 1));
    expect(sends, 13, reason: 'Only elapsed time grants the next token');
    await tester.pump(const Duration(seconds: 90));
    await Future.wait(pending);
    expect(
      sends,
      252,
      reason: 'All queued work drains despite clock adjustments',
    );
    api.close();
  });

  testWidgets(
    'ordinary HTTP and event reconnects share a finite admission budget',
    (tester) async {
      var sends = 0;
      final api = SiliqueApi(
        'http://127.0.0.1',
        now: tester.binding.clock.now,
        elapsed: () => tester.binding.clock.now().difference(DateTime(2000)),
        client: MockClient((r) async {
          sends++;
          return http.Response('{"cursor":"v0"}', 200);
        }),
      );
      addTearDown(api.close);
      var finished = false;
      final completion =
          Future.wait([
            for (var i = 0; i < 300; i++) api.request('GET', '/v1/vaults'),
            api.waitForChanges(null),
          ]).then<void>((_) {
            finished = true;
          });
      await tester.pump();
      expect(sends, 12, reason: 'No unbounded initial HTTP burst');
      await tester.pump(const Duration(seconds: 60));
      expect(
        sends,
        lessThanOrEqualTo(185),
        reason: '12 burst + at most one admission per 350ms, below the default 240/min',
      );
      expect(sends, greaterThanOrEqualTo(180));
      expect(finished, isFalse);
      await tester.pump(const Duration(seconds: 60));
      await completion;
      expect(
        sends,
        301,
        reason: 'Admission must eventually drain, not drop requests',
      );
      expect(finished, isTrue);
      api.close();
      final stopped = sends;
      await tester.pump(const Duration(minutes: 2));
      expect(sends, stopped);
    },
  );

  testWidgets(
    'continuing arrivals cannot overtake older ordinary or event waiters',
    (tester) async {
      final sent = <String>[];
      final api = SiliqueApi(
        'http://127.0.0.1',
        now: tester.binding.clock.now,
        elapsed: () => tester.binding.clock.now().difference(DateTime(2000)),
        client: MockClient((r) async {
          sent.add(r.url.path);
          return http.Response('{"cursor":"v0"}', 200);
        }),
      );
      addTearDown(api.close);
      await Future.wait(
        List.generate(12, (_) => api.request('GET', '/warmup')),
      );
      sent.clear();
      final pending = <Future<Object?>>[
        api.request('GET', '/early-a'),
        api.waitForChanges(null),
        api.request('GET', '/early-b'),
      ];
      for (var i = 0; i < 5; i++) {
        pending.add(api.request('GET', '/late-$i'));
        await tester.pump(const Duration(milliseconds: 350));
      }
      await tester.pump(const Duration(seconds: 3));
      await Future.wait(pending);
      expect(sent, [
        '/early-a',
        '/v1/events',
        '/early-b',
        for (var i = 0; i < 5; i++) '/late-$i',
      ]);
      api.close();
    },
  );

  testWidgets(
    'close rejects queued ordinary and event requests without sending them',
    (tester) async {
      var sends = 0;
      final api = SiliqueApi(
        'http://127.0.0.1',
        now: tester.binding.clock.now,
        elapsed: () => tester.binding.clock.now().difference(DateTime(2000)),
        client: MockClient((r) async {
          sends++;
          return http.Response('{}', 200);
        }),
      );
      addTearDown(api.close);
      await Future.wait(
        List.generate(12, (_) => api.request('GET', '/v1/vaults')),
      );
      final errors = <Object>[];
      final queued = Future.wait([
        for (final work in <Future<Object?>>[
          for (var i = 0; i < 20; i++) api.request('GET', '/v1/vaults'),
          api.waitForChanges(null),
        ])
          work.then<void>(
            (_) => fail('A closed client must not send queued work'),
            onError: (Object error) {
              errors.add(error);
            },
          ),
      ]);
      await tester.pump();
      api.close();
      await tester.pump();
      await queued;
      expect(errors, hasLength(21));
      expect(errors, everyElement(isA<http.ClientException>()));
      await tester.pump(const Duration(minutes: 2));
      expect(sends, 12);
    },
  );

  testWidgets(
    'a late 429 fences requests already waiting for admission until expiry',
    (tester) async {
      var sends = 0;
      final api = SiliqueApi(
        'http://127.0.0.1',
        now: tester.binding.clock.now,
        elapsed: () => tester.binding.clock.now().difference(DateTime(2000)),
        client: MockClient((r) async {
          sends++;
          return sends == 12
              ? http.Response('{}', 429, headers: {'retry-after': '60'})
              : http.Response('{}', 200);
        }),
      );
      addTearDown(api.close);
      final errors = <Object>[];
      final queued = Future.wait(
        List.generate(
          42,
          (_) => api
              .request('GET', '/v1/vaults')
              .then<void>(
                (_) {},
                onError: (Object error) {
                  errors.add(error);
                },
              ),
        ),
      );
      await tester.pump();
      expect(sends, 12);
      await tester.pump(const Duration(seconds: 15));
      await queued;
      expect(
        sends,
        12,
        reason: 'All queued calls must recheck the shared cooldown before HTTP',
      );
      expect(errors, hasLength(31));
      expect(
        errors,
        everyElement(
          isA<ApiException>().having((e) => e.status, 'status', 429),
        ),
      );
      await tester.pump(const Duration(seconds: 46));
      await api.request('GET', '/v1/vaults');
      expect(
        sends,
        13,
        reason: 'Local fencing must not extend the original Retry-After',
      );
      api.close();
    },
  );

  testWidgets(
    'cancelling an event queued behind ordinary traffic prevents its HTTP send',
    (tester) async {
      var events = 0;
      final afterEvent = <String>[];
      final api = SiliqueApi(
        'http://127.0.0.1',
        now: tester.binding.clock.now,
        elapsed: () => tester.binding.clock.now().difference(DateTime(2000)),
        client: MockClient((r) async {
          if (r.url.path == '/v1/events') events++;
          if (r.url.path.startsWith('/queued-')) afterEvent.add(r.url.path);
          return http.Response('{"cursor":"v0"}', 200);
        }),
      );
      addTearDown(api.close);
      await Future.wait(
        List.generate(12, (_) => api.request('GET', '/v1/vaults')),
      );
      Object? error;
      var finished = false;
      final pending = api
          .waitForChanges(null)
          .then<void>(
            (_) {
              finished = true;
            },
            onError: (Object caught) {
              error = caught;
              finished = true;
            },
          );
      final ordinary = Future.wait([
        api.request('GET', '/queued-a'),
        api.request('GET', '/queued-b'),
      ]);
      await tester.pump();
      api.cancelChangeWait();
      await tester.pump();
      expect(
        finished,
        isTrue,
        reason: 'Cancellation must not wait for another HTTP token',
      );
      expect(error, isA<http.RequestAbortedException>());
      await pending;
      await tester.pump(const Duration(seconds: 1));
      expect(events, 0);
      await ordinary;
      expect(afterEvent, ['/queued-a', '/queued-b']);
    },
  );
}
