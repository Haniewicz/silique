import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/core/models.dart';
import 'package:silique/core/server_trust.dart';
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/ui/dialogs.dart';
import 'package:silique/ui/server_trust_dialogs.dart';
import 'package:silique/ui/theme.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

const _server = 'https://192.168.100.24';
const _spki = 'MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWZ4eXoxMjM0';

/// Bounded pump: `runAsync` + `pump` with a clocked deadline, never
/// `pumpAndSettle` (the settings account tab keeps a progress indicator and
/// tab animations running in the background).
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  int maxFrames = 80,
}) async {
  for (var i = 0; i < maxFrames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    if (done()) return;
  }
  fail('condition not reached within the bounded pump');
}

/// A [SiliqueApi] whose `/v1/devices` request throws [UntrustedServerCertificate]
/// whenever the store has no confirmed pin for the server, and answers with a
/// device list once a pin exists — modelling the real `badCertificateCallback`
/// decision. Every other request is answered with an empty payload.
/// [devicesCalls] counts exactly how many `GET /v1/devices` requests were made.
SiliqueApi _failingApi({
  required ServerTrust trust,
  required List<String> devicesCalls,
}) {
  final key = serverKeyOf(Uri.parse(_server));
  bool hasPin() {
    final store = trust.store;
    if (store is! SynchronousServerTrustStore) return false;
    final record = store.readSync(key);
    return record != null && record['spki'] != null;
  }

  return SiliqueApi(
    _server,
    token: 'test-only',
    trust: trust,
    client: MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/v1/devices') {
        devicesCalls.add('GET /v1/devices');
        if (!hasPin()) {
          throw UntrustedServerCertificate(
            spki: _spki,
            subject: 'CN=192.168.100.24',
            notAfter: DateTime(2035),
          );
        }
        return http.Response(
          jsonEncode({
            'devices': [
              {'id': 'this-device', 'name': 'Ten komputer', 'revoked': 0},
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (request.method == 'GET' && request.url.path == '/v1/pairings') {
        return http.Response(
          jsonEncode({'pairings': <Object>[]}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{}', 200);
    }),
  );
}

Future<void> _mountAccount(
  WidgetTester tester,
  Notebook repo, {
  bool toAccountTab = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: siliqueTheme(),
      home: Scaffold(
        body: Center(
          child: Dialog(
            insetPadding: const EdgeInsets.all(16),
            child: SettingsPanel(
              notebook: repo,
              onChanged: () {},
              // This test asserts exact device-request counts for the trust
              // flow; the automatic polling is covered by pairing_poll_test.
              pollInterval: const Duration(days: 1),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  if (toAccountTab) {
    await tester.tap(find.byKey(const Key('settings-tab-account')));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets(
    'account tab surfaces a trust button instead of the raw exception',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('silique-trust-');
      final store = InMemoryTrustStore();
      final trust = ServerTrust(store: store);
      final repo = Notebook(
        storage: NativeStorage(dir.path),
        keys: MemoryKeys(),
        crypto: TestCrypto(),
        trust: trust,
      );
      await tester.runAsync(() => repo.initialize());
      repo.session = Session(
        server: _server,
        token: 'test-only',
        userId: 'test-user',
        email: 'test@example.invalid',
      );
      final devicesCalls = <String>[];
      repo.api = _failingApi(trust: trust, devicesCalls: devicesCalls);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        repo.api?.close();
        await repo.storage.close();
        dir.deleteSync(recursive: true);
      });
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await _mountAccount(tester, repo);

      // The automatic refresh hits the untrusted certificate: the inline trust
      // block appears with the trust button, and the raw exception text never
      // reaches the tree.
      await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('account-trust-server')).evaluate().isNotEmpty,
      );
      expect(find.byKey(const Key('account-trust-server')), findsOneWidget);
      expect(find.textContaining('UntrustedServerCertificate('), findsNothing);
      // The fingerprint is hex, grouped by four, never the base64 pin.
      final fingerprint = tester.widget<SelectableText>(
        find.byKey(const Key('account-trust-spki')),
      );
      expect(fingerprint.data, spkiDisplay(_spki));
      expect(fingerprint.data, isNot(contains('MDEy')));
      expect(devicesCalls, hasLength(1));

      // The failed refresh has finished (the trust button is enabled again).
      await _pumpUntil(tester, () => devicesCalls.length == 1);

      // Tapping the block persists the pin and retries exactly once. The block
      // sits below the fold inside the tab's scroll view, so it must be scrolled
      // into view first — tapping an off-screen finder silently misses and the
      // retry assertion below would time out.
      final trustButton = find.byKey(const Key('account-trust-server'));
      await tester.ensureVisible(trustButton);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(trustButton);
      await _pumpUntil(
        tester,
        () =>
            store.readSync('https://192.168.100.24')?['spki'] == _spki &&
            devicesCalls.length == 2,
      );

      expect(store.readSync('https://192.168.100.24')?['spki'], _spki);
      expect(devicesCalls, hasLength(2)); // exactly one retry — never a loop
      // After trust the block is gone (no pin missing).
      expect(find.byKey(const Key('account-trust-server')), findsNothing);
    },
  );

  testWidgets(
    'a matching stored pin shows neither the trust button nor any dialog',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('silique-trust-ok-');
      final store = InMemoryTrustStore();
      // Pre-seed a matching pin for the server.
      await tester.runAsync(
        () => store.write('https://192.168.100.24', {
          'spki': _spki,
          'subject': 'CN=192.168.100.24',
          'savedAt': '2026-01-01T00:00:00.000Z',
          'notAfter': '2035-01-01T00:00:00.000Z',
        }),
      );
      final trust = ServerTrust(store: store);
      final repo = Notebook(
        storage: NativeStorage(dir.path),
        keys: MemoryKeys(),
        crypto: TestCrypto(),
        trust: trust,
      );
      await tester.runAsync(() => repo.initialize());
      repo.session = Session(
        server: _server,
        token: 'test-only',
        userId: 'test-user',
        email: 'test@example.invalid',
      );
      final devicesCalls = <String>[];
      repo.api = _failingApi(trust: trust, devicesCalls: devicesCalls);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        repo.api?.close();
        await repo.storage.close();
        dir.deleteSync(recursive: true);
      });
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await _mountAccount(tester, repo);

      // The refresh succeeds immediately: devices load, no trust button, and
      // no trust dialog of any kind.
      await _pumpUntil(tester, () => devicesCalls.isNotEmpty);
      expect(devicesCalls, hasLength(1));
      expect(find.byKey(const Key('account-trust-server')), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
