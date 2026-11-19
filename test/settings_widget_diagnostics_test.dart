import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/ui/dialogs.dart';
import 'package:silique/ui/theme.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

Future<Notebook> _notebook(WidgetTester tester, String prefix) async {
  late Notebook repo;
  late Directory dir;
  await tester.runAsync(() async {
    dir = Directory.systemTemp.createTempSync(prefix);
    repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
  });
  addTearDown(() async {
    await repo.close();
    dir.deleteSync(recursive: true);
  });
  return repo;
}

Future<void> _mount(
  WidgetTester tester,
  Notebook repo, {
  Future<String> Function()? widgetDiagnostics,
}) async {
  tester.view.physicalSize = const Size(1100, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
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
              widgetDiagnostics: widgetDiagnostics,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('widget diagnostics row shows the native log and copies it', (
    tester,
  ) async {
    final repo = await _notebook(tester, 'silique-widget-diagnostics-');
    var loads = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') return null;
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await _mount(
      tester,
      repo,
      widgetDiagnostics: () async {
        loads++;
        return 'read_ok notes=2\npoll remaining=3\nrender widget=7 state=notes=2';
      },
    );
    final tile = find.byKey(
      const Key('widget-diagnostics-tile'),
      skipOffstage: false,
    );
    expect(tile, findsOneWidget);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(loads, 1);
    final log = tester.widget<SelectableText>(
      find.byKey(const Key('widget-diagnostics-text')),
    );
    expect(log.data, contains('read_ok notes=2'));
    expect(log.data, contains('render widget=7'));
    await tester.tap(find.byKey(const Key('widget-diagnostics-copy')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('widget-diagnostics-text')),
      findsOneWidget,
      reason: 'Copying must not close the diagnostics dialog',
    );
    await tester.tap(find.byKey(const Key('widget-diagnostics-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('widget-diagnostics-text')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('diagnostics row is hidden without a native widget channel', (
    tester,
  ) async {
    final repo = await _notebook(tester, 'silique-widget-diagnostics-off-');
    await _mount(tester, repo);
    expect(
      find.byKey(const Key('widget-diagnostics-tile'), skipOffstage: false),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
