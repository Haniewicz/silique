import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/l10n/app_language.dart';
import 'package:silique/main.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/ui/theme.dart' show muted;

import 'core_test.dart' show MemoryKeys, TestCrypto;
import 'hidden_notes_home_test.dart' show drainUntil;

/// Desktop-sized home over a fresh SQLite vault with an ordinary folder and a
/// journal folder. [restart] swaps in a fresh [Notebook] over the same storage,
/// the durability convention from folder_reorder_ui_regression_test.dart.
class _ColorsHome {
  _ColorsHome(this.root, this.keys);

  final Directory root;
  final MemoryKeys keys;
  late Notebook repo;

  Notebook make() => Notebook(
    storage: NativeStorage(root.path),
    keys: keys,
    crypto: TestCrypto(),
  );

  Future<void> create() async {
    repo = make();
    await repo.initialize();
    await repo.createVault('Colors');
    await repo.createFolder(repo.vaults.single, 'Alpha');
    await repo.createFolder(repo.vaults.single, 'Dziennik');
  }

  Future<void> restart() async {
    await repo.close();
    repo = make();
    await repo.initialize();
  }
}

void main() {
  Future<_ColorsHome> home(WidgetTester tester, String prefix) async {
    final fixture = _ColorsHome(
      Directory.systemTemp.createTempSync(prefix),
      MemoryKeys(),
    );
    await tester.runAsync(fixture.create);
    await tester.binding.setSurfaceSize(const Size(1380, 900));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      var closed = false;
      final close = fixture.repo.close().then((_) => closed = true);
      await drainUntil(tester, () => closed);
      await close;
      await tester.runAsync(
        () async => fixture.root.deleteSync(recursive: true),
      );
      await tester.binding.setSurfaceSize(null);
    });
    return fixture;
  }

  Future<void> mount(WidgetTester tester, _ColorsHome fixture) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [notebookProvider.overrideWithValue(fixture.repo)],
        child: const SiliqueApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Color? iconColor(WidgetTester tester, String path) =>
      tester.widget<Icon>(find.byKey(Key('folder-icon-$path'))).color;

  Future<void> openFolderPicker(WidgetTester tester, String path) async {
    await tester.tap(find.byKey(Key('folder-menu-$path')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kolor folderu'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('color-picker-sv')), findsOneWidget);
  }

  Future<void> apply(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('color-picker-apply')));
    await tester.pump();
  }

  testWidgets(
    'a color picked in the visual picker tints the row icon, survives restart '
    'and "no color" restores the default',
    (tester) async {
      final fixture = await home(tester, 'silique-folder-colors-ui-');
      await mount(tester, fixture);
      final vaultId = fixture.repo.vaults.single.id;
      expect(iconColor(tester, 'Alpha'), const Color(0xff8fa6de));
      expect(
        iconColor(tester, 'Dziennik'),
        muted,
        reason: 'the journal glyph keeps its muted default until colored',
      );

      // Pick the center of the SV field (a full-alpha ARGB value) and apply.
      await openFolderPicker(tester, 'Alpha');
      await tester.tap(find.byKey(const Key('color-picker-sv')));
      await tester.pump();
      await apply(tester);
      await drainUntil(
        tester,
        () => iconColor(tester, 'Alpha') != const Color(0xff8fa6de),
      );
      final picked = iconColor(tester, 'Alpha')!;
      expect(fixture.repo.folderColorsOf(vaultId).containsKey('Alpha'), isTrue);
      expect(tester.takeException(), isNull);

      // Widget restart over the same SQLite: the accent is durable metadata.
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(fixture.restart);
      await mount(tester, fixture);
      expect(iconColor(tester, 'Alpha'), picked);

      // "no color" clears the entry and restores the default glyph.
      await openFolderPicker(tester, 'Alpha');
      await tester.tap(find.byKey(const Key('color-picker-none')));
      await tester.pump();
      await apply(tester);
      await drainUntil(
        tester,
        () => iconColor(tester, 'Alpha') == const Color(0xff8fa6de),
      );
      expect(fixture.repo.folderColorsOf(vaultId), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the folder menu offers the bilingual color entry with the palette icon',
    (tester) async {
      final fixture = await home(tester, 'silique-folder-colors-menu-');
      final previous = appLanguage.languageCode;
      addTearDown(() => appLanguage.setLanguage(previous));
      await mount(tester, fixture);

      await tester.tap(find.byKey(const Key('folder-menu-Alpha')));
      await tester.pumpAndSettle();
      expect(find.text('Kolor folderu'), findsOneWidget);
      expect(find.byIcon(Icons.palette_outlined), findsOneWidget);

      await tester.runAsync(() => appLanguage.setLanguage('en'));
      await tester.pumpAndSettle();
      expect(find.text('Folder color'), findsOneWidget);

      // Dismiss the menu through its route barrier before unmounting.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('the hidden section offers no folder color entry', (
    tester,
  ) async {
    final fixture = await home(tester, 'silique-folder-colors-hidden-');
    await tester.runAsync(() async {
      await fixture.repo.setHiddenPassword('hidden password 12345');
      final hidden = await fixture.repo.createHiddenNote(
        fixture.repo.vaults.single.id,
      );
      await fixture.repo.save(hidden.copyWith(title: 'Prywatna'));
    });
    await mount(tester, fixture);
    await tester.tap(find.byKey(const Key('hidden-folder-nav')));
    await drainUntil(tester, () => find.text('Prywatna').evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    await tester.runAsync(() => fixture.repo.setHiddenAutoLock(null));

    await tester.tap(find.byKey(const Key('folder-menu-Alpha')));
    await tester.pumpAndSettle();
    expect(
      find.text('Zmień nazwę'),
      findsOneWidget,
      reason: 'the ordinary folder menu itself stays reachable',
    );
    expect(find.text('Kolor folderu'), findsNothing);
    expect(find.text('Folder color'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a locked vault renders no folder rows, so the color menu is unavailable',
    (tester) async {
      final fixture = await home(tester, 'silique-folder-colors-locked-');
      await mount(tester, fixture);
      expect(find.byKey(const Key('folder-menu-Alpha')), findsOneWidget);

      fixture.repo.lock(fixture.repo.vaults.single.id);
      await tester.pumpWidget(const SizedBox());
      await mount(tester, fixture);
      expect(find.byKey(const Key('folder-menu-Alpha')), findsNothing);
      expect(find.byKey(const Key('folder-icon-Alpha')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
