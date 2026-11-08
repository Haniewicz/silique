import 'dart:io' show HttpDate;

import 'package:silique/services/sync_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/services/api.dart';

void main() {
  testWidgets(
    'server cooldown prevents sync callbacks and longpoll reconnects, and stop cancels retries',
    (tester) async {
      var requests = 0, syncs = 0;
      final api = SiliqueApi(
        'http://127.0.0.1',
        client: MockClient((r) async {
          requests++;
          return http.Response('{}', 429, headers: {'retry-after': '60'});
        }),
      );
      // A manual sync establishes the same shared cooldown used by the listener.
      await expectLater(
        api.request('GET', '/v1/vaults'),
        throwsA(isA<ApiException>()),
      );
      final scheduler = SyncCoordinator(
        api: () => api,
        synchronize: () async {
          syncs++;
          return true;
        },
      );
      scheduler.start();
      await tester.pump();
      for (var i = 0; i < 50; i++) {
        scheduler.request();
        scheduler.localChanged();
        await tester.pump(const Duration(seconds: 1));
      }
      expect(requests, 1);
      expect(syncs, 0);
      scheduler.stop();
      await tester.pump(const Duration(minutes: 2));
      expect(requests, 1);
      expect(syncs, 0);
      api.close();
    },
  );

  test(
    'event 429 fences ordinary requests and delta-seconds expires',
    () async {
      var requests = 0;
      final api = SiliqueApi(
        'http://127.0.0.1',
        client: MockClient((r) async {
          requests++;
          return requests == 1
              ? http.Response('{}', 429, headers: {'retry-after': '1'})
              : http.Response('{}', 200);
        }),
      );
      addTearDown(api.close);
      await expectLater(
        api.waitForChanges('v0'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.retryAfter,
            'retry delay',
            isNotNull,
          ),
        ),
      );
      await expectLater(
        api.request('GET', '/v1/vaults'),
        throwsA(isA<ApiException>()),
      );
      expect(requests, 1);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await api.request('GET', '/v1/vaults');
      expect(requests, 2);
    },
  );

  test(
    'HTTP-date and malformed Retry-After retain conservative cooldowns',
    () async {
      for (final value in [
        HttpDate.format(DateTime.now().add(const Duration(seconds: 90))),
        'malformed',
      ]) {
        final api = SiliqueApi(
          'http://127.0.0.1',
          client: MockClient(
            (r) async =>
                http.Response('{}', 429, headers: {'retry-after': value}),
          ),
        );
        addTearDown(api.close);
        await expectLater(
          api.request('GET', '/v1/vaults'),
          throwsA(isA<ApiException>()),
        );
        expect(api.retryAfter, greaterThan(const Duration(seconds: 58)));
      }
    },
  );

  test(
    '429 cooldown fences concurrent manual requests and event reconnects',
    () async {
      var requests = 0;
      final api = SiliqueApi(
        'http://127.0.0.1',
        client: MockClient((r) async {
          requests++;
          return http.Response(
            '{"error":"slow down"}',
            429,
            headers: {'retry-after': '60'},
          );
        }),
      );
      addTearDown(api.close);
      await expectLater(
        api.request('GET', '/v1/vaults'),
        throwsA(isA<ApiException>()),
      );
      await Future.wait(
        List.generate(30, (i) async {
          await expectLater(
            i.isEven
                ? api.request('GET', '/v1/vaults')
                : api.waitForChanges('v0'),
            throwsA(isA<ApiException>()),
          );
        }),
      );
      expect(
        requests,
        1,
        reason: 'Retry-After must fence every entry point before HTTP',
      );
    },
  );
}
