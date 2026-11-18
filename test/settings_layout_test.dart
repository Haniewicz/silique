import 'dart:io';

import 'package:flutter/material.dart';
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

Future<void> _mount(WidgetTester tester, Notebook repo, Size size) async {
  tester.view.physicalSize = size;
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
            child: SettingsPanel(notebook: repo, onChanged: () {}),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('desktop settings are a wide two-column panel, not a tab strip', (
    tester,
  ) async {
    final repo = await _notebook(tester, 'silique-settings-layout-desktop-');
    await _mount(tester, repo, const Size(1100, 900));

    expect(find.byType(TabBar), findsNothing);
    // The dialog fills the roomy width instead of shrink-wrapping a header.
    expect(tester.getSize(find.byType(SettingsPanel)).width, greaterThan(700));
    // Every section is a sidebar entry, and switching shows its content.
    expect(find.byKey(const Key('settings-tab-appearance')), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-tab-appearance')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const Key('appearance-default-note-color'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    // No drill-down chrome on desktop.
    expect(find.byKey(const Key('settings-back-to-list')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mobile settings list a section, drill in and come back', (
    tester,
  ) async {
    final repo = await _notebook(tester, 'silique-settings-layout-mobile-');
    await _mount(tester, repo, const Size(420, 860));

    expect(find.byType(TabBar), findsNothing);
    // The phone starts on the section list (no content pane, no sidebar).
    expect(find.byKey(const Key('settings-tab-storage')), findsOneWidget);
    expect(find.byKey(const Key('settings-back-to-list')), findsNothing);
    expect(
      find.byKey(const Key('language-picker'), skipOffstage: false),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('settings-tab-storage')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-back-to-list')), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-back-to-list')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-back-to-list')), findsNothing);
    expect(find.byKey(const Key('settings-tab-general')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('settings hover uses the same token as folder rows', (
    tester,
  ) async {
    final theme = siliqueTheme();
    expect(theme.hoverColor, hover);
    // No ripples: rows paint the shared hover surface instead of a splash, the
    // same way the folder rows already did.
    expect(identical(theme.splashFactory, NoSplash.splashFactory), isTrue);
    expect(hoverRadius, 6);
    expect(hover.a, lessThan(0.2), reason: 'hover must stay a subtle overlay');
  });
}
