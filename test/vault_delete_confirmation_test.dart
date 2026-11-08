import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/models.dart';
import 'package:silique/ui/theme.dart';
import 'package:silique/ui/vault_delete_dialog.dart';

void main() {
  for (final phone in [false, true]) {
    testWidgets(
      'explicit delete confirmation scopes remote deletion and resists Enter double submit Escape while busy phone=$phone',
      (tester) async {
        await tester.binding.setSurfaceSize(
          phone ? const Size(360, 780) : const Size(1000, 850),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        tester.view.viewInsets = phone
            ? const FakeViewPadding(bottom: 260)
            : const FakeViewPadding();
        addTearDown(tester.view.resetViewInsets);
        final vault = Vault(
          id: '11111111-1111-4111-8111-111111111111',
          name: 'Projekty – syntetyczne',
          mode: 'account',
          keyWrap: '',
          localWrap: '',
          metadata: '',
          owner: 'https://synthetic.invalid|test-owner',
        );
        final pending = Completer<void>();
        var calls = 0;

        await tester.runAsync(() async {
          await (FontLoader(
            'Inter',
          )..addFont(rootBundle.load('assets/fonts/Inter.ttf'))).load();
          await (FontLoader('MaterialIcons')
                ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
              .load();
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: siliqueTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(phone ? 1.6 : 1)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => deleteVaultDialog(context, vault, (_) {
                    calls++;
                    return pending.future;
                  }),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Zgodne urządzenia usuną swoje kopie'),
          findsOneWidget,
        );
        final field = find.byKey(const ValueKey('vault-delete-name'));
        await tester.ensureVisible(field);
        await tester.enterText(field, vault.name.toLowerCase());
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(calls, 0);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('vault-delete-confirm')),
              )
              .onPressed,
          isNull,
        );
        await tester.enterText(field, vault.name);
        await tester.pump();
        expect(
          tester.getRect(field).bottom,
          lessThanOrEqualTo(
            tester
                .getRect(find.byKey(const ValueKey('vault-delete-confirm')))
                .top,
          ),
        );

        await tester.tap(find.byKey(const ValueKey('vault-delete-confirm')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('vault-delete-confirm')));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump(const Duration(milliseconds: 200));
        expect(calls, 1);
        expect(find.byType(VaultDeleteDialog), findsOneWidget);
        pending.complete();
        await tester.pumpAndSettle();
        expect(find.byType(VaultDeleteDialog), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('synthetic destructive confirmation screenshot', (tester) async {
    await tester.binding.setSurfaceSize(const Size(780, 880));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await (FontLoader(
        'Inter',
      )..addFont(rootBundle.load('assets/fonts/Inter.ttf'))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    final key = GlobalKey();
    final vault = Vault(
      id: '11111111-1111-4111-8111-111111111111',
      name: 'Projekty – syntetyczne',
      mode: 'account',
      keyWrap: '',
      localWrap: '',
      metadata: '',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: siliqueTheme(),
        home: RepaintBoundary(
          key: key,
          child: Scaffold(
            body: Center(
              child: VaultDeleteDialog(vault: vault, remove: (_) async {}),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final output = Platform.environment['SILIQUE_DELETE_CAPTURE'];
    if (output != null) {
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(output).writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    expect(tester.takeException(), isNull);
  });
}
