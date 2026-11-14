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
  int maxFrames = 240,
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
    'owner mismatch keeps the switch live and re-binds on the next sync without a dialog',
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

      // The initial device refresh finishes first.
      await _pumpUntil(tester, () => requests.contains('GET /v1/devices'));

      // Ownership is provenance, not a gate: the switch stays live and the
      // tile explains the automatic re-bind without a blocking dialog/button.
      expect(tile('Osobiste').onChanged, isNotNull);
      expect(find.textContaining('innego konta'), findsOneWidget);
      expect(find.byKey(Key('rebind-vault-$vaultId')), findsNothing);

      // Toggling off disables sync locally; toggling back on re-binds the
      // vault to the current account in place (PUT), no confirmation dialog.
      // The tile can sit below the fold, so scroll it into view before every
      // tap; a missed hit test would otherwise look like a product defect.
      Future<void> toggle() async {
        final finder = find.widgetWithText(SwitchListTile, 'Osobiste');
        await tester.ensureVisible(finder);
        await tester.pump();
        await tester.tap(finder);
        await tester.pump(const Duration(milliseconds: 100));
      }

      await toggle();
      expect(
        repo.vaults.single.syncEnabled,
        isFalse,
        reason: 'first tap disables sync',
      );
      await toggle();
      await _pumpUntil(tester, () => requests.contains('PUT /v1/vaults/$vaultId'));
      await _pumpUntil(
        tester,
        () => repo.vaults.single.owner == repo.session!.owner,
      );
      expect(repo.vaults.single.syncEnabled, isTrue);
    },
  );
}