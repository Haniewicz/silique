import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/l10n/app_language.dart';
import 'package:silique/main.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;
import 'hidden_notes_home_test.dart' show drainUntil;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a Polish vault keeps Szablony when the language switches to English',
    () async {
      final previous = appLanguage.languageCode;
      addTearDown(() => appLanguage.setLanguage(previous));
      final dir = Directory.systemTemp.createTempSync('system-folders-lang-');
      final repo = Notebook(
        storage: NativeStorage(dir.path),
        keys: MemoryKeys(),
        crypto: TestCrypto(),
      );
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await appLanguage.setLanguage('pl');
      await repo.initialize();
      await repo.createVault('Vault');
      final vault = repo.vaults.single;
      expect(repo.foldersOf(vault.id), contains('Szablony'));

      // Switching to English must not seed a duplicate `Templates`.
      await appLanguage.setLanguage('en');
      await repo.ensureTemplatesFolder(vault);
      expect(repo.foldersOf(vault.id), contains('Szablony'));
      expect(repo.foldersOf(vault.id), isNot(contains('Templates')));
    },
  );

  testWidgets('English aliases render localized names and the journal icon', (
    tester,
  ) async {
    final previous = appLanguage.languageCode;
    addTearDown(() => appLanguage.setLanguage(previous));
    late Notebook repo;
    late Directory dir;
    await tester.runAsync(() async {
      dir = Directory.systemTemp.createTempSync('system-folders-lang-');
      repo = Notebook(
        storage: NativeStorage(dir.path),
        keys: MemoryKeys(),
        crypto: TestCrypto(),
      );
      await appLanguage.setLanguage('en');
      await repo.initialize();
      await repo.createVault('Vault');
      final vault = repo.vaults.single;
      // Templates is seeded in English; add a Journal folder explicitly and
      // an ordinary user subfolder that happens to share the English spelling.
      await repo.createFolder(vault, 'Journal');
      await repo.createFolder(vault, 'Projekty/Templates');
      final note = await repo.createNote(vault.id);
      await repo.save(note.copyWith(title: 'Note'));
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      var closed = false;
      final close = repo.close().then((_) => closed = true);
      await drainUntil(tester, () => closed);
      await close;
      await tester.runAsync(() async => dir.deleteSync(recursive: true));
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // Polish UI localizes the stored `Templates` alias to `Szablony`.
    await tester.runAsync(() => appLanguage.setLanguage('pl'));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [notebookProvider.overrideWithValue(repo)],
        child: const SiliqueApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Szablony'), findsOneWidget);
    // An ordinary `Projekty/Templates` folder is not a system root, so its
    // leaf keeps the user's own spelling instead of being localized.
    expect(find.text('Templates'), findsOneWidget);
    expect(
      find.byKey(const Key('folder-icon-Projekty/Templates')),
      findsOneWidget,
    );

    // The `Journal` folder keeps the calendar icon under its English alias.
    final journalIcon = find.byKey(const Key('folder-icon-Journal'));
    expect(journalIcon, findsOneWidget);
    expect(
      tester.widget<Icon>(journalIcon).icon,
      Icons.calendar_month_outlined,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
