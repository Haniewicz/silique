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

const _server = 'https://example.invalid';

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  int maxFrames = 120,
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

void main() {
  testWidgets(
    'owner mismatch disables the switch but shows the reason and rebind; rebind re-enables it',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('silique-rebind-ui-');
      final repo = Notebook(
        storage: NativeStorage(dir.path),
        keys: MemoryKeys(),
        crypto: TestCrypto(),
      );
      await tester.runAsync(() => repo.initialize());
      await tester.runAsync(() async {
        await repo.createVault('Osobiste');
        final vault = repo.vaults.single;
        vault.owner = 'https://old.example|old-user-1234';
        vault.syncEnabled = true;
        repo.storage.putVault(vault);
      });
      final vaultId = repo.vaults.single.id;
      repo.session = Session(
        server: _server,
        token: 'test',
        userId: 'current-user',
        email: 'a@example.invalid',
      );
      repo.accountKey = repo.crypto.randomKey();
      final requests = <String>[];
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: MockClient((request) async {
          requests.add('${request.method} ${request.url.path}');
          final path = request.url.path;
          if (path == '/v1/devices') {
            return http.Response(jsonEncode({'devices': <Object>[]}), 200);
          }
          if (path == '/v1/vaults') {
            return http.Response(
              jsonEncode({'vaults': <Object>[], 'deletedVaults': <Object>[]}),
              200,
            );
          }
          if (request.method == 'PUT' && path == '/v1/vaults/$vaultId') {
            return http.Response(jsonEncode({'version': 1}), 200);
          }
          if (path.endsWith('/changes')) {
            return http.Response(
              jsonEncode({
                'purged': <Object>[],
                'revisions': <Object>[],
                'cursor': 0,
                'hasMore': false,
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        repo.api?.close();
        await repo.storage.close();
        dir.deleteSync(recursive: true);
      });
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Dialog(
                child: SettingsPanel(
                  notebook: repo,
                  onChanged: () {},
                  pollInterval: const Duration(days: 1),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const Key('settings-tab-account')));
      await tester.pump(const Duration(milliseconds: 50));

      SwitchListTile tile(String name) =>
          tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, name));

      // The initial device refresh finishes first, so the rebind action is live.
      await _pumpUntil(tester, () => requests.contains('GET /v1/devices'));
      await _pumpUntil(
        tester,
        () => find.byKey(Key('rebind-vault-$vaultId')).evaluate().isNotEmpty,
      );

      // Switch is inactive (grey), but the reason and the rebind action are
      // both visible.
      expect(tile('Osobiste').onChanged, isNull);
      expect(find.textContaining('old.example'), findsOneWidget);
      expect(find.textContaining('old-user'), findsOneWidget);
      final rebind = find.byKey(Key('rebind-vault-$vaultId'));
      await tester.ensureVisible(rebind);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Podłącz do tego konta'), findsWidgets);

      await tester.tap(rebind);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('rebind-vault-confirm')));
      await _pumpUntil(
        tester,
        () => requests.contains('PUT /v1/vaults/$vaultId'),
      );
      await _pumpUntil(tester, () => repo.vaults.single.owner == repo.session!.owner);

      // After the rebind the switch is active again.
      expect(tile('Osobiste').onChanged, isNotNull);
      expect(find.byKey(Key('rebind-vault-$vaultId')), findsNothing);
    },
  );
}