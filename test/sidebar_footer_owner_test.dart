import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/l10n/app_language.dart';
import 'package:silique/storage/vault_import.dart';
import 'package:silique/ui/vault_import_dialog.dart';

import 'hidden_notes_home_test.dart' show fixture, mount, drainUntil;

void main() {
  test('single selected file enforces type/byte limits and cancellation without neighbour access', () async {
    final root = Directory.systemTemp.createTempSync('silique-file-limits-');
    addTearDown(() {
      debugMarkdownImportPicker = null;
      root.deleteSync(recursive: true);
    });
    debugMarkdownImportPicker = () async => null;
    expect(await pickMarkdownImportSource(), isNull);
    // Match native picker paths: cross_file splits names on the host separator.
    final oversized = File('${root.path}${Platform.pathSeparator}Large.md')
      ..writeAsStringSync('a' * 1000001);
    expect(XFile(oversized.path).name, 'Large.md');
    await expectLater(
      scanVaultImport(MarkdownFileImportSource(XFile(oversized.path))),
      throwsFormatException,
    );
    final invalid = File('${root.path}${Platform.pathSeparator}Image.png')
      ..writeAsStringSync('not markdown');
    expect(XFile(invalid.path).name, 'Image.png');
    await expectLater(
      scanVaultImport(MarkdownFileImportSource(XFile(invalid.path))),
      throwsFormatException,
    );
    final exact = File('${root.path}${Platform.pathSeparator}Exact.txt')
      ..writeAsStringSync('x' * 1000000);
    expect(XFile(exact.path).name, 'Exact.txt');
    final plan = await scanVaultImport(
      MarkdownFileImportSource(XFile(exact.path)),
    );
    expect(plan.notes.single.body.length, 1000000);
    expect(plan.files, {'Exact.txt'});
    await expectLater(
      plan.source.read('../Image.png', limit: 1000000),
      throwsFormatException,
    );
  });
  testWidgets(
    'phone drawer keeps horizontal footer and dismisses into unified import at enlarged text',
    (tester) async {
      final repo = await fixture(tester);
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await mount(tester, repo);
      await tester.tap(find.byTooltip('Foldery i vaulty'));
      await tester.pumpAndSettle();
      final footer = find.byKey(const Key('sidebar-footer-actions'));
      expect(footer, findsOneWidget);
      final labels = ['Usunięte', 'Ukryte', 'Importuj'].map(find.text).toList();
      expect(tester.getTopLeft(labels[0]).dy, tester.getTopLeft(labels[1]).dy);
      expect(tester.getTopLeft(labels[1]).dy, tester.getTopLeft(labels[2]).dy);
      expect(tester.takeException(), isNull);
      await tester.tap(labels[2]);
      await tester.pumpAndSettle();
      expect(find.byType(VaultImportDialog), findsOneWidget);
      expect(find.byKey(const Key('choose-import-file')), findsOneWidget);
      await tester.tap(find.text('Anuluj'));
      await tester.pumpAndSettle();
      expect(footer, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unified file import previews then preserves exact text without importing neighbours',
    (tester) async {
      final repo = await fixture(tester);
      final source = Directory.systemTemp.createTempSync(
        'silique-single-import-',
      );
      const body = '# Żółć 😀\n![missing](photo.png)\n[[Neighbour]]\n';
      File('${source.path}${Platform.pathSeparator}Selected.MD')
          .writeAsStringSync(body);
      File('${source.path}${Platform.pathSeparator}Neighbour.md')
          .writeAsStringSync('must not import');
      debugMarkdownImportPicker = () async =>
          XFile('${source.path}${Platform.pathSeparator}Selected.MD');
      addTearDown(() {
        debugMarkdownImportPicker = null;
        source.deleteSync(recursive: true);
      });
      expect(
        XFile('${source.path}${Platform.pathSeparator}Selected.MD').name,
        'Selected.MD',
      );
      await mount(tester, repo, desktop: true);
      await tester.tap(find.text('Importuj'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('choose-import-file')));
      await drainUntil(
        tester,
        () =>
            find.byKey(const Key('vault-import-summary')).evaluate().isNotEmpty,
      );
      expect(find.text('Notatki: 1 • Foldery: 0'), findsOneWidget);
      expect(repo.notes[repo.vaults.single.id]!.length, 1);
      await tester.tap(find.byKey(const Key('confirm-vault-import')));
      await drainUntil(
        tester,
        () => find.byType(VaultImportDialog).evaluate().isEmpty,
      );
      final imported = repo.notes[repo.vaults.single.id]!.values.singleWhere(
        (n) => n.title == 'Selected',
      );
      expect(imported.body, body);
      expect(repo.notes[repo.vaults.single.id]!.length, 2);
      expect(
        File('${source.path}${Platform.pathSeparator}Selected.MD')
            .readAsStringSync(),
        body,
      );
      expect(
        File('${source.path}${Platform.pathSeparator}Neighbour.md')
            .readAsStringSync(),
        'must not import',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('one import entry offers a Markdown file and a whole folder', (
    tester,
  ) async {
    final repo = await fixture(tester);
    await mount(tester, repo, desktop: true);
    await tester.tap(find.text('Importuj'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('choose-import-file')), findsOneWidget);
    expect(find.byKey(const Key('choose-import-vault')), findsOneWidget);
    await tester.tap(find.text('Anuluj'));
    await tester.pumpAndSettle();
    expect(repo.notes[repo.vaults.single.id]!.length, 1);
  });
  for (final language in ['pl', 'en']) {
    testWidgets(
      'footer actions share a horizontal row above vault badge $language',
      (tester) async {
        final repo = await fixture(tester);
        await tester.runAsync(() => appLanguage.setLanguage(language));
        await mount(tester, repo, desktop: true);
        final deleted = find.text(language == 'pl' ? 'Usunięte' : 'Deleted');
        final hidden = find.text(language == 'pl' ? 'Ukryte' : 'Hidden');
        final import = find.text(language == 'pl' ? 'Importuj' : 'Import');
        expect(deleted, findsOneWidget);
        expect(hidden, findsOneWidget);
        expect(import, findsOneWidget);
        final a = tester.getRect(deleted),
            b = tester.getRect(hidden),
            c = tester.getRect(import);
        // Labels may wrap with large/Ahem fonts; their first line stays aligned.
        expect(a.top, closeTo(b.top, 1));
        expect(b.top, closeTo(c.top, 1));
        expect(a.right, lessThan(b.left));
        expect(b.right, lessThan(c.left));
        expect(
          c.bottom,
          lessThan(
            tester
                .getRect(
                  find.byTooltip(
                    language == 'pl'
                        ? 'Ustawienia synchronizacji'
                        : 'Sync settings',
                  ),
                )
                .top,
          ),
        );
        expect(find.text('Importuj Markdown'), findsNothing);
        expect(find.text('Import vault from folder'), findsNothing);
        await tester.tap(deleted);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('hidden-folder-nav')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await tester.runAsync(() => appLanguage.setLanguage('pl'));
      },
    );
  }
}
