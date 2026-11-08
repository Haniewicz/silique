import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/l10n/app_language.dart';
import 'package:silique/ui/dialogs.dart';
import 'package:silique/core/credential_mode.dart';
import 'package:silique/storage/native_files.dart';

import 'credential_mode_ui_test.dart' show ModeKeys, mountSettings;

void main() {
  testWidgets(
    'Settings language picker updates the open panel and keeps fields',
    (tester) async {
      final previous = appLanguage.languageCode;
      addTearDown(() => appLanguage.setLanguage(previous));
      await tester.runAsync(() => appLanguage.setLanguage('en'));
      final root = Directory.systemTemp.createTempSync(
        'silique-language-dialog-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      debugStorageAccess = (_) {};
      addTearDown(() => debugStorageAccess = null);
      await mountSettings(
        tester,
        root,
        ModeKeys(CredentialMode.local),
        tab: 'settings-tab-general',
      );
      expect(find.text('Settings'), findsOneWidget);
      expect(find.byKey(const Key('language-picker')), findsOneWidget);
      // The server fields live on the account & sync tab; the language picker
      // stays on the general tab, so the switch crosses tab boundaries.
      Future<void> openTab(String key) async {
        await tester.ensureVisible(find.byKey(Key(key)));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key(key)));
        await tester.pumpAndSettle();
      }

      await openTab('settings-tab-account');
      await tester.enterText(
        find.byType(TextField).first,
        'https://my-server.example',
      );
      final fields = find.byType(TextField);
      final controllers = tester
          .widgetList<TextField>(fields)
          .map((field) => field.controller)
          .toList();
      final fieldStates = tester.stateList<State>(fields).toList();
      void expectFieldsPreserved() {
        final currentFields = tester.widgetList<TextField>(fields).toList();
        final currentStates = tester.stateList<State>(fields).toList();
        expect(currentFields.length, controllers.length);
        for (var i = 0; i < controllers.length; i++) {
          expect(currentFields[i].controller, same(controllers[i]));
          expect(currentStates[i], same(fieldStates[i]));
        }
        expect(controllers.first!.text, 'https://my-server.example');
      }

      await openTab('settings-tab-general');
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('language-pl')));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(appLanguage.languageCode, 'pl');
      expect(find.text('Ustawienia'), findsOneWidget);
      expect(find.text('Settings'), findsNothing);
      await openTab('settings-tab-account');
      expect(
        tester.widget<TextField>(fields.first).decoration!.labelText,
        'Adres serwera',
      );
      expectFieldsPreserved();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'https://my-server.example',
      );
      await openTab('settings-tab-general');
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('language-en')));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Ustawienia'), findsNothing);
      await openTab('settings-tab-account');
      expect(
        tester.widget<TextField>(fields.first).decoration!.labelText,
        'Server address',
      );
      expectFieldsPreserved();
    },
  );

  testWidgets(
    'Settings success message follows language without repeating action',
    (tester) async {
      final previous = appLanguage.languageCode;
      addTearDown(() => appLanguage.setLanguage(previous));
      await tester.runAsync(() => appLanguage.setLanguage('pl'));
      final root = Directory.systemTemp.createTempSync(
        'settings-success-language-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      debugStorageAccess = (_) {};
      addTearDown(() => debugStorageAccess = null);
      await mountSettings(tester, root, ModeKeys(CredentialMode.local));
      await tester.ensureVisible(
        find.byKey(const Key('hidden-create-password')),
      );
      await tester.tap(find.byKey(const Key('hidden-create-password')));
      await tester.pumpAndSettle();
      final dialogFields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(dialogFields.first, 'test-password');
      await tester.enterText(dialogFields.last, 'test-password');
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Utwórz hasło'),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(find.text('Hasło ukrytych notatek ustawione.'), findsOneWidget);
      await tester.runAsync(() => appLanguage.setLanguage('en'));
      await tester.pumpAndSettle();
      expect(find.text('Hidden notes password set.'), findsOneWidget);
      expect(find.text('Hasło ukrytych notatek ustawione.'), findsNothing);
      await tester.runAsync(() => appLanguage.setLanguage('pl'));
      await tester.pumpAndSettle();
      expect(find.text('Hasło ukrytych notatek ustawione.'), findsOneWidget);
      expect(find.text('Hidden notes password set.'), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('hidden-lock')));
      await tester.tap(find.byKey(const Key('hidden-lock')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'open password dialog follows language changes without losing input',
    (tester) async {
      final previous = appLanguage.languageCode;
      addTearDown(() => appLanguage.setLanguage(previous));
      await tester.runAsync(() => appLanguage.setLanguage('en'));
      await tester.pumpWidget(
        SiliqueMaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => askHiddenPassword(context, create: true),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Hidden notes password'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      await tester.tap(find.text('Create password'));
      await tester.pumpAndSettle();
      expect(
        find.text('The password must have at least 8 characters.'),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField).first, 'private-value');
      await tester.enterText(find.byType(TextField).last, 'different-value');
      final fields = find.byType(TextField);
      final controllers = tester
          .widgetList<TextField>(fields)
          .map((field) => field.controller)
          .toList();
      final fieldStates = tester.stateList<State>(fields).toList();
      void expectFieldsPreserved() {
        final currentFields = tester.widgetList<TextField>(fields).toList();
        final currentStates = tester.stateList<State>(fields).toList();
        expect(currentFields.length, controllers.length);
        for (var i = 0; i < controllers.length; i++) {
          expect(currentFields[i].controller, same(controllers[i]));
          expect(currentStates[i], same(fieldStates[i]));
        }
        expect(controllers.first!.text, 'private-value');
        expect(controllers.last!.text, 'different-value');
      }

      await tester.runAsync(() => appLanguage.setLanguage('pl'));
      await tester.pumpAndSettle();
      expect(find.text('Hasło ukrytych notatek'), findsOneWidget);
      expect(find.text('Anuluj'), findsOneWidget);
      expect(
        find.text('Hasło musi mieć co najmniej 8 znaków.'),
        findsOneWidget,
      );
      expect(
        find.text('The password must have at least 8 characters.'),
        findsNothing,
      );
      expectFieldsPreserved();

      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'private-value',
      );

      await tester.runAsync(() => appLanguage.setLanguage('en'));
      await tester.pumpAndSettle();
      expect(find.text('Hidden notes password'), findsOneWidget);
      expect(
        find.text('The password must have at least 8 characters.'),
        findsOneWidget,
      );
      expect(find.text('Hasło musi mieć co najmniej 8 znaków.'), findsNothing);
      expectFieldsPreserved();

      await tester.tap(find.text('Create password'));
      await tester.pumpAndSettle();
      expect(find.text('The passwords do not match.'), findsOneWidget);
      await tester.runAsync(() => appLanguage.setLanguage('pl'));
      await tester.pumpAndSettle();
      expect(find.text('Hasła nie są identyczne.'), findsOneWidget);
      expect(find.text('The passwords do not match.'), findsNothing);
      expectFieldsPreserved();
      await tester.runAsync(() => appLanguage.setLanguage('en'));
      await tester.pumpAndSettle();
      expect(find.text('The passwords do not match.'), findsOneWidget);
      expect(find.text('Hasła nie są identyczne.'), findsNothing);
      expectFieldsPreserved();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    },
  );
}
