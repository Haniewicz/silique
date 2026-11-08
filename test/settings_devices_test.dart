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

void main() {
  testWidgets(
    'confirmed revocation immediately removes the device from settings',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync(
        'silique-settings-devices-',
      );
      final repo = Notebook(
        storage: NativeStorage(dir.path),
        keys: MemoryKeys(),
        crypto: TestCrypto(),
      );
      await tester.runAsync(() => repo.initialize());
      var revoked = false;
      repo.session = Session(
        server: 'https://example.invalid',
        token: 'test-only',
        userId: 'test-user',
        email: 'test@example.invalid',
      );
      repo.api = SiliqueApi(
        'https://example.invalid',
        client: MockClient((request) async {
          if (request.method == 'DELETE') {
            expect(request.url.path, '/v1/devices/other-device-123');
            revoked = true;
            return http.Response('{}', 200);
          }
          expect(request.url.path, '/v1/devices');
          return http.Response(
            jsonEncode({
              'devices': [
                {'id': repo.deviceId, 'name': 'Ten komputer', 'revoked': 0},
                {
                  'id': 'other-device-123',
                  'name': 'Laptop do cofnięcia',
                  'revoked': revoked ? 1 : 0,
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(() async {
        repo.api?.close();
        await repo.storage.close();
        dir.deleteSync(recursive: true);
      });
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() => repo.refreshDevices());
      expect(repo.devices, hasLength(2));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Dialog(
                child: SettingsPanel(notebook: repo, onChanged: () {}),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
      // The device list lives on the account & sync tab.
      await tester.tap(find.byKey(const Key('settings-tab-account')));
      await tester.pumpAndSettle();
      expect(find.text('Laptop do cofnięcia'), findsOneWidget);
      final revoke = find.byTooltip('Cofnij dostęp').last;
      await tester.ensureVisible(revoke);
      await tester.tap(revoke);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Cofnij dostęp').last);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
      expect(revoked, isTrue);
      expect(find.text('Laptop do cofnięcia'), findsNothing);
      expect(repo.devices!.map((device) => device['id']), [repo.deviceId]);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
