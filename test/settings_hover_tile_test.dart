import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/models.dart' show Vault;
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/ui/dialogs.dart';
import 'package:silique/ui/theme.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

/// Creates a fresh SQLite-backed notebook over a temp directory with one
/// unlocked vault and a hidden-notes password set (so the Storage section's
/// switch rows exist), with a teardown that closes and removes it.
Future<(Notebook, Vault)> _notebook(WidgetTester tester, String prefix) async {
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
    await repo.createVault('Hover', password: 'folder password 12345');
    await repo.setHiddenPassword('test hidden password');
  });
  addTearDown(() async {
    await repo.close();
    dir.deleteSync(recursive: true);
  });
  return (repo, repo.vaults.single);
}

Future<void> _mount(
  WidgetTester tester,
  Notebook repo,
  Size size, {
  Vault? vault,
}) async {
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
            child: SettingsPanel(
              notebook: repo,
              vault: vault,
              onChanged: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openSection(WidgetTester tester, String key) async {
  final tab = find.byKey(Key(key));
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

/// The hover surface must be the shared rounded rectangle, not a square
/// rectangle: `ListTile` feeds `shape ?? tileTheme.shape` into its InkWell
/// `customBorder`, so a missing `shape` paints square hover corners.
void _expectRoundedHover(ShapeBorder? shape, String reason) {
  expect(shape, isA<RoundedRectangleBorder>(), reason: reason);
  final border = shape! as RoundedRectangleBorder;
  expect(
    border.borderRadius,
    BorderRadius.circular(hoverRadius),
    reason: reason,
  );
}

/// Every interactive row in the Settings panel (either layout) must carry the
/// shared hover shape. Widgets are found offstage too: the panel keeps all six
/// sections mounted inside an [IndexedStack].
void _expectRoundedHoverRows(WidgetTester tester) {
  final panel = find.byType(SettingsPanel);
  for (final key in const [
    Key('templates-folder-hidden-toggle'),
    Key('compact-mode-toggle'),
    Key('hidden-lock-background'),
    Key('appearance-default-note-color'),
    Key('appearance-default-folder-color'),
  ]) {
    expect(
      find.byKey(key, skipOffstage: false),
      findsOneWidget,
      reason: '$key must be built by the settings panel',
    );
  }

  final switches = tester
      .widgetList<SwitchListTile>(
        find.descendant(
          of: panel,
          matching: find.byType(SwitchListTile),
          skipOffstage: false,
        ),
      )
      .toList();
  expect(switches, isNotEmpty);
  for (final tile in switches) {
    _expectRoundedHover(tile.shape, 'SwitchListTile ${tile.key}');
  }

  final tapRows = tester
      .widgetList<ListTile>(
        find.descendant(
          of: panel,
          matching: find.byType(ListTile),
          skipOffstage: false,
        ),
      )
      .where((tile) => tile.onTap != null)
      .toList();
  expect(tapRows, isNotEmpty);
  for (final tile in tapRows) {
    _expectRoundedHover(tile.shape, 'ListTile ${tile.key}');
  }
}

void main() {
  testWidgets('desktop Settings rows hover on a rounded surface', (
    tester,
  ) async {
    final (repo, vault) = await _notebook(
      tester,
      'silique-settings-hover-desktop-',
    );
    await _mount(tester, repo, const Size(1100, 900), vault: vault);

    // General is open by default: the templates folder toggle is the row the
    // owner's screenshot showed with a square hover background.
    await _openSection(tester, 'settings-tab-general');
    final templates = find.byKey(const Key('templates-folder-hidden-toggle'));
    expect(templates, findsOneWidget);
    _expectRoundedHover(
      tester.widget<SwitchListTile>(templates).shape,
      'templates folder toggle',
    );
    final templatesWell = tester.widget<InkWell>(
      find.descendant(of: templates, matching: find.byType(InkWell)).first,
    );
    _expectRoundedHover(templatesWell.customBorder, 'templates row InkWell');

    // The Appearance color rows are plain tap-able ListTiles.
    await _openSection(tester, 'settings-tab-appearance');
    for (final key in const [
      Key('appearance-default-note-color'),
      Key('appearance-default-folder-color'),
    ]) {
      final row = tester.widget<ListTile>(find.byKey(key));
      expect(row.onTap, isNotNull, reason: '$key is an interactive row');
      _expectRoundedHover(row.shape, 'ListTile $key');
    }

    _expectRoundedHoverRows(tester);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mobile Settings rows hover on the same rounded surface', (
    tester,
  ) async {
    final (repo, vault) = await _notebook(
      tester,
      'silique-settings-hover-mobile-',
    );
    await _mount(tester, repo, const Size(420, 860), vault: vault);

    // The phone starts on the section list; drill into a section so the shared
    // IndexedStack mounts every row.
    expect(find.byKey(const Key('settings-tab-general')), findsOneWidget);
    await _openSection(tester, 'settings-tab-general');
    expect(find.byKey(const Key('settings-back-to-list')), findsOneWidget);

    _expectRoundedHoverRows(tester);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
