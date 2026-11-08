import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/l10n/app_language.dart';
import 'package:silique/ui/dialogs.dart';

import 'context_menu_language_test.dart' show mountHome, openNoteMenu;

Future<void> switchLanguage(WidgetTester tester, String code) async {
  await tester.runAsync(() => appLanguage.setLanguage(code));
  await tester.pumpAndSettle();
}

Future<void> mountDialog(
  WidgetTester tester,
  void Function(BuildContext) open,
) async {
  final previous = appLanguage.languageCode;
  addTearDown(() => appLanguage.setLanguage(previous));
  await switchLanguage(tester, 'en');
  await tester.pumpWidget(
    SiliqueMaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => open(context),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

class OpenDialogSnapshot {
  OpenDialogSnapshot(WidgetTester tester)
    : route = ModalRoute.of(tester.element(find.byType(AlertDialog))),
      fields = tester.widgetList<TextField>(find.byType(TextField)).toList(),
      states = tester.stateList<State>(find.byType(TextField)).toList();
  final ModalRoute<dynamic>? route;
  final List<TextField> fields;
  final List<State> states;

  void expectPreserved(WidgetTester tester, List<String> values) {
    expect(
      ModalRoute.of(tester.element(find.byType(AlertDialog))),
      same(route),
    );
    final current = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    final currentStates = tester
        .stateList<State>(find.byType(TextField))
        .toList();
    expect(current.length, fields.length);
    for (var i = 0; i < fields.length; i++) {
      expect(current[i].controller, same(fields[i].controller));
      expect(currentStates[i], same(states[i]));
      expect(current[i].controller!.text, values[i]);
    }
  }
}

Future<void> closeDialog(WidgetTester tester) async {
  await tester.tap(find.text(tr('Anuluj', 'Cancel')));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  testWidgets(
    'open confirmation relocalizes title and message without changing note',
    (tester) async {
      final repo = await mountHome(tester);
      final before = repo.notes[repo.vaults.single.id]!.values.single.toJson();
      await openNoteMenu(tester, repo);
      await tester.tap(find.text('Move to hidden notes'));
      await tester.pumpAndSettle();
      expect(find.text('Move to hidden notes?'), findsOneWidget);
      final route = ModalRoute.of(tester.element(find.byType(AlertDialog)));
      final englishMessage = tester
          .widget<Text>(
            find
                .descendant(
                  of: find.byType(AlertDialog),
                  matching: find.byType(Text),
                )
                .at(1),
          )
          .data!;
      expect(englishMessage, contains('Hidden notes'));
      await switchLanguage(tester, 'pl');
      expect(find.text('Przenieść do ukrytych?'), findsOneWidget);
      expect(find.text('Move to hidden notes?'), findsNothing);
      expect(find.text(englishMessage), findsNothing);
      expect(
        find.textContaining('Ukryte notatki są dodatkowo szyfrowane'),
        findsOneWidget,
      );
      expect(
        ModalRoute.of(tester.element(find.byType(AlertDialog))),
        same(route),
      );
      expect(repo.notes[repo.vaults.single.id]!.values.single.toJson(), before);
      await switchLanguage(tester, 'en');
      expect(find.text('Move to hidden notes?'), findsOneWidget);
      expect(find.text(englishMessage), findsOneWidget);
      expect(
        ModalRoute.of(tester.element(find.byType(AlertDialog))),
        same(route),
      );
      await closeDialog(tester);
      expect(repo.notes[repo.vaults.single.id]!.values.single.toJson(), before);
    },
  );

  testWidgets(
    'home folder dialog title relocalizes without replacing entered name',
    (tester) async {
      await mountHome(tester);
      await tester.tap(find.byTooltip('New folder'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('folder-name')),
        'New folder',
      );
      final dialogTitle = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('New folder'),
      );
      expect(dialogTitle, findsWidgets);
      final field = find.byKey(const Key('folder-name'));
      final controller = tester.widget<TextField>(field).controller;
      final route = ModalRoute.of(tester.element(find.byType(AlertDialog)));
      await switchLanguage(tester, 'pl');
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Nowy folder'),
        ),
        findsOneWidget,
      );
      expect(controller!.text, 'New folder');
      expect(tester.widget<TextField>(field).controller, same(controller));
      expect(
        ModalRoute.of(tester.element(find.byType(AlertDialog))),
        same(route),
      );
      await switchLanguage(tester, 'en');
      expect(dialogTitle, findsWidgets);
      expect(controller.text, 'New folder');
      await closeDialog(tester);
    },
  );

  testWidgets('open tag hint relocalizes while preserving raw tag input', (
    tester,
  ) async {
    await mountHome(tester);
    await tester.tap(find.byTooltip('Edit tags'));
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, '#praca #Save');
    final controller = tester.widget<TextField>(field).controller;
    final route = ModalRoute.of(tester.element(find.byType(AlertDialog)));
    expect(
      tester.widget<TextField>(field).decoration!.hintText,
      '#planning #work',
    );
    await switchLanguage(tester, 'pl');
    expect(
      tester.widget<TextField>(field).decoration!.hintText,
      '#planowanie #praca',
    );
    expect(tester.widget<TextField>(field).controller, same(controller));
    expect(controller!.text, '#praca #Save');
    expect(
      ModalRoute.of(tester.element(find.byType(AlertDialog))),
      same(route),
    );
    await switchLanguage(tester, 'en');
    expect(
      tester.widget<TextField>(field).decoration!.hintText,
      '#planning #work',
    );
    expect(controller.text, '#praca #Save');
    await closeDialog(tester);
  });

  testWidgets('open rename title relocalizes while typed note text stays raw', (
    tester,
  ) async {
    final repo = await mountHome(tester);
    await openNoteMenu(tester, repo);
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);
    final field = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, 'Nowa notatka');
    final route = ModalRoute.of(tester.element(find.byType(AlertDialog)));
    final controller = tester.widget<TextField>(field).controller;
    final state = tester.state(field);
    await switchLanguage(tester, 'pl');
    expect(find.text('Zmień nazwę'), findsOneWidget);
    expect(find.text('Rename'), findsNothing);
    expect(tester.widget<TextField>(field).controller, same(controller));
    expect(tester.state(field), same(state));
    expect(controller!.text, 'Nowa notatka');
    expect(
      ModalRoute.of(tester.element(find.byType(AlertDialog))),
      same(route),
    );
    await switchLanguage(tester, 'en');
    expect(find.text('Rename'), findsOneWidget);
    expect(controller.text, 'Nowa notatka');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    expect(
      repo.notes[repo.vaults.single.id]!.values.single.title,
      'Nowa notatka',
    );
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets(
    'folder validation relocalizes without retyping or replacing field',
    (tester) async {
      await mountDialog(tester, (context) {
        askFolderName(
          context,
          parent: 'Projekty',
          existing: ['Projekty/Existing'],
        );
      });
      final field = find.byKey(const Key('folder-name'));
      final snapshot = OpenDialogSnapshot(tester);
      for (final example in [
        ('', 'Enter a folder name.', 'Podaj nazwę folderu.'),
        (
          'a/b',
          'A subfolder name cannot contain /.',
          'Nazwa podfolderu nie zawiera znaku /.',
        ),
        (
          'Existing',
          'A folder with this name already exists.',
          'Folder o tej nazwie już istnieje.',
        ),
      ]) {
        await tester.enterText(field, example.$1);
        await tester.tap(find.byKey(const Key('folder-create')));
        await tester.pumpAndSettle();
        expect(find.text(example.$2), findsOneWidget);
        await switchLanguage(tester, 'pl');
        expect(find.text(example.$3), findsOneWidget);
        expect(find.text(example.$2), findsNothing);
        snapshot.expectPreserved(tester, [example.$1]);
        expect(find.text('W folderze: Projekty'), findsOneWidget);
        await switchLanguage(tester, 'en');
        expect(find.text(example.$2), findsOneWidget);
        expect(find.text(example.$3), findsNothing);
        snapshot.expectPreserved(tester, [example.$1]);
      }
      await closeDialog(tester);
    },
  );

  testWidgets(
    'vault validation relocalizes while preserving password and route',
    (tester) async {
      await mountDialog(tester, (context) {
        askVault(context);
      });
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Nowy vault');
      await tester.enterText(find.byType(TextField).last, 'raw-short');
      await tester.tap(find.text('Create vault'));
      await tester.pumpAndSettle();
      const en = 'Enter a name and a password of at least 12 characters.';
      const pl = 'Podaj nazwę i hasło o długości min. 12 znaków.';
      expect(find.text(en), findsOneWidget);
      final snapshot = OpenDialogSnapshot(tester);
      await switchLanguage(tester, 'pl');
      expect(find.text(pl), findsOneWidget);
      expect(find.text(en), findsNothing);
      snapshot.expectPreserved(tester, ['Nowy vault', 'raw-short']);
      await switchLanguage(tester, 'en');
      expect(find.text(en), findsOneWidget);
      expect(find.text(pl), findsNothing);
      snapshot.expectPreserved(tester, ['Nowy vault', 'raw-short']);
      await closeDialog(tester);
    },
  );
}
