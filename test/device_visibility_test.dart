import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

void main() {
  test('refreshDevices excludes devices whose access was revoked', () async {
    final dir = Directory.systemTemp.createTempSync('silique-device-list-');
    final storage = NativeStorage(dir.path);
    final api = SiliqueApi(
      'https://example.invalid',
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/devices');
        return http.Response(
          jsonEncode({
            'devices': [
              {'id': 'active-device', 'name': 'Active', 'revoked': 0},
              {'id': 'revoked-device', 'name': 'Revoked', 'revoked': 1},
            ],
          }),
          200,
        );
      }),
    );
    addTearDown(() async {
      api.close();
      await storage.close();
      dir.deleteSync(recursive: true);
    });
    final repo = Notebook(
      storage: storage,
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    )..api = api;
    await repo.refreshDevices();
    expect(repo.devices!.map((device) => device['id']).toList(), [
      'active-device',
    ]);
  });
}
