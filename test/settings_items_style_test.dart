import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/models.dart' show Vault;
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/ui/dialogs.dart';
import 'package:silique/ui/theme.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

/// Creates a fresh SQLite-backed notebook with one unlocked vault (so the
/// appearance color rows are interactive) and a hidden-notes password set (so
/// the Storage section's switch row exists).
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
    await repo.createVault('Items', password: 'folder password 12345');
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

/// The radius a settings row must use — the dedicated settings token, which the
/// task pins at ~8 and must not reuse the folder-row `hoverRadius` (6).
void _expectRounded(RoundedRectangleBorder shape, String reason) {
  expect(
    shape.borderRadius,
    BorderRadius.circular(settingsItemRadius),
    reason: reason,
  );
  expect(settingsItemRadius, greaterThanOrEqualTo(8), reason: reason);
}

void main() {
  testWidgets(
    'settings rows use rounded hover, left padding and vertical gaps',
    (tester) async {
      final (repo, vault) = await _notebook(
        tester,
        'silique-settings-items-desktop-',
      );
      await _mount(tester, repo, const Size(1100, 900), vault: vault);

      // Appearance holds two adjacent tap-able rows, ideal for the gap check.
      await tester.tap(find.byKey(const Key('settings-tab-appearance')));
      await tester.pumpAndSettle();

      final note = tester.widget<ListTile>(
        find.byKey(const Key('appearance-default-note-color')),
      );
      final folder = tester.widget<ListTile>(
        find.byKey(const Key('appearance-default-folder-color')),
      );

      for (final (tile, name) in [
        (note, 'default note color'),
        (folder, 'default folder color'),
      ]) {
        expect(tile.shape, isA<RoundedRectangleBorder>(), reason: name);
        _expectRounded(tile.shape! as RoundedRectangleBorder, name);
        // The old rows used `contentPadding: EdgeInsets.zero`; the left inset
        // must now be non-zero (and mirrored on the right).
        final padding = tile.contentPadding!.resolve(TextDirection.ltr);
        expect(padding.left, greaterThan(0), reason: '$name left padding');
        expect(padding.right, greaterThan(0), reason: '$name right padding');
      }

      // The two rows are laid out one after another: their vertical distance is
      // the shared row gap, not zero (flush) and not a section spacer.
      final noteRect = tester.getRect(
        find.byKey(const Key('appearance-default-note-color')),
      );
      final folderRect = tester.getRect(
        find.byKey(const Key('appearance-default-folder-color')),
      );
      final gap = folderRect.top - noteRect.bottom;
      expect(gap, greaterThan(0), reason: 'rows must be separated vertically');
      expect(gap, lessThan(20), reason: 'row gap should stay small (~4px)');

      // Switch rows share the same shape and non-zero left padding.
      final compact = tester.widget<SwitchListTile>(
        find.byKey(const Key('compact-mode-toggle'), skipOffstage: false),
      );
      _expectRounded(compact.shape! as RoundedRectangleBorder, 'compact mode');
      expect(
        compact.contentPadding!.resolve(TextDirection.ltr).left,
        greaterThan(0),
        reason: 'compact-mode left padding',
      );

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('mobile drill-down rows keep rounded hover and left padding', (
    tester,
  ) async {
    final (repo, vault) = await _notebook(
      tester,
      'silique-settings-items-mobile-',
    );
    await _mount(tester, repo, const Size(420, 860), vault: vault);

    await tester.tap(find.byKey(const Key('settings-tab-general')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-back-to-list')), findsOneWidget);

    final templates = tester.widget<SwitchListTile>(
      find.byKey(const Key('templates-folder-hidden-toggle')),
    );
    _expectRounded(templates.shape! as RoundedRectangleBorder, 'templates');
    expect(
      templates.contentPadding!.resolve(TextDirection.ltr).left,
      greaterThan(0),
      reason: 'templates left padding',
    );

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
