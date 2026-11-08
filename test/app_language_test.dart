import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/l10n/app_language.dart';
import 'package:silique/ui/language_picker.dart';
import 'package:silique/ui/location_setup.dart';
import 'package:silique/storage/native_files.dart';

void main() {
  setUp(() async => appLanguage.setLanguage('en'));
  tearDown(() async => appLanguage.setLanguage('pl'));

  test('new controller defaults to English independently of device locale', () {
    final controller = AppLanguageController();
    expect(controller.languageCode, 'en');
    expect(controller.locale, const Locale('en'));
    controller.dispose();
  });

  testWidgets('fresh setup uses English and offers language selection', (
    tester,
  ) async {
    var opened = false;
    await tester.pumpWidget(
      LocationSetupScreen(
        onChosen: (_) async {
          opened = true;
        },
      ),
    );
    expect(find.text('Where should your vaults be stored?'), findsOneWidget);
    expect(find.byKey(const Key('language-picker')), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('language-pl')));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.text('Gdzie mają być Twoje vaulty?'), findsOneWidget);
    expect(opened, isFalse);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('language-en')));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.text('Where should your vaults be stored?'), findsOneWidget);
  });

  for (final recovering in [false, true]) {
    testWidgets(
      'picker cancellation follows language changes (recovery: $recovering)',
      (tester) async {
        await tester.runAsync(() => appLanguage.setLanguage('pl'));
        var picks = 0;
        var opened = false;
        debugDirectoryPicker = () async {
          picks++;
          return null;
        };
        addTearDown(() => debugDirectoryPicker = null);
        await tester.pumpWidget(
          LocationSetupScreen(
            recovering: recovering,
            onChosen: (_) async => opened = true,
          ),
        );
        await tester.ensureVisible(find.byKey(const Key('choose-location')));
        await tester.tap(find.byKey(const Key('choose-location')));
        await tester.pumpAndSettle();
        final polish = recovering
            ? 'Nie wybrano katalogu. Twoje dane pozostają nietknięte.'
            : 'Nie wybrano katalogu. Vaulty nie zostały utworzone — wybierz miejsce zapisu.';
        final english = recovering
            ? 'No folder selected. Your data remains untouched.'
            : 'No folder selected. No vaults have been created — choose a storage location.';
        expect(find.text(polish), findsOneWidget);
        await tester.ensureVisible(find.byKey(const Key('language-en')));
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const Key('language-en')));
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pumpAndSettle();
        expect(find.text(english), findsOneWidget);
        expect(find.text(polish), findsNothing);
        expect(picks, 1);
        expect(opened, isFalse);
      },
    );
  }

  testWidgets('unusable picker choice follows language changes', (
    tester,
  ) async {
    await tester.runAsync(() => appLanguage.setLanguage('pl'));
    debugDirectoryPicker = () async =>
        const StorageChoice(path: null, writable: false);
    addTearDown(() => debugDirectoryPicker = null);
    var opened = false;
    await tester.pumpWidget(
      LocationSetupScreen(onChosen: (_) async => opened = true),
    );
    await tester.ensureVisible(find.byKey(const Key('choose-location')));
    await tester.tap(find.byKey(const Key('choose-location')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Ten katalog nie może przechowywać notatek. Wybierz folder w pamięci urządzenia, np. Dokumenty.',
      ),
      findsOneWidget,
    );
    await tester.runAsync(() => appLanguage.setLanguage('en'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'This folder cannot store notes. Choose a folder on this device, such as Documents.',
      ),
      findsOneWidget,
    );
    expect(opened, isFalse);
  });

  testWidgets('external picker error remains verbatim after language change', (
    tester,
  ) async {
    await tester.runAsync(() => appLanguage.setLanguage('pl'));
    const diagnostic = 'Provider diagnostic: Nie wybrano katalogu / E42';
    debugDirectoryPicker = () async => throw const FormatException(diagnostic);
    addTearDown(() => debugDirectoryPicker = null);
    await tester.pumpWidget(LocationSetupScreen(onChosen: (_) async {}));
    await tester.ensureVisible(find.byKey(const Key('choose-location')));
    await tester.tap(find.byKey(const Key('choose-location')));
    await tester.pumpAndSettle();
    expect(find.text('FormatException: $diagnostic'), findsOneWidget);
    await tester.runAsync(() => appLanguage.setLanguage('en'));
    await tester.pumpAndSettle();
    expect(find.text('FormatException: $diagnostic'), findsOneWidget);
  });

  testWidgets(
    'language changes preserve editor identity, input and selection',
    (tester) async {
      final text = TextEditingController(text: 'Moja notatka — my note');
      final focus = FocusNode();
      await tester.pumpWidget(
        SiliqueMaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const LanguagePicker(),
                TextField(controller: text, focusNode: focus),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'Unchanged user text');
      text.selection = const TextSelection(baseOffset: 2, extentOffset: 8);
      final field = tester.state(find.byType(EditableText));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('language-pl')));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(EditableText)), same(field));
      expect(text.text, 'Unchanged user text');
      expect(
        text.selection,
        const TextSelection(baseOffset: 2, extentOffset: 8),
      );
      expect(find.text('Język'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      text.dispose();
      focus.dispose();
    },
  );

  test('preference survives restart and switches both ways without touching vaults', () async {
    final support = Directory.systemTemp.createTempSync('silique-language-');
    final sentinel = File('${support.path}/vault-sentinel')
      ..writeAsStringSync('unchanged');
    try {
      final controller = AppLanguageController();
      await controller.initialize(support);
      expect(controller.languageCode, 'en');
      expect(File('${support.path}/interface-language').existsSync(), isFalse);
      await controller.setLanguage('pl');
      controller.dispose();
      final reopened = AppLanguageController();
      await reopened.initialize(support);
      expect(reopened.languageCode, 'pl');
      await reopened.setLanguage('en');
      reopened.dispose();
      final restarted = AppLanguageController();
      await restarted.initialize(support);
      expect(restarted.languageCode, 'en');
      expect(sentinel.readAsStringSync(), 'unchanged');
      expect(support.listSync().length, 2);
      restarted.dispose();
    } finally {
      support.deleteSync(recursive: true);
    }
  });

  test('invalid saved language falls back to English and rejected changes do not overwrite it', () async {
    final support = Directory.systemTemp.createTempSync(
      'silique-language-invalid-',
    );
    try {
      final saved = File('${support.path}/interface-language')
        ..writeAsStringSync('unsupported');
      final controller = AppLanguageController();
      await controller.initialize(support);
      expect(controller.languageCode, 'en');
      await expectLater(controller.setLanguage('de'), throwsArgumentError);
      expect(saved.readAsStringSync(), 'unsupported');
      await controller.setLanguage('pl');
      expect(saved.readAsStringSync(), 'pl');
      controller.dispose();
    } finally {
      support.deleteSync(recursive: true);
    }
  });

  test(
    'failed save retains active language and a later save can retry',
    () async {
      final support = Directory.systemTemp.createTempSync(
        'silique-language-retry-',
      );
      try {
        final controller = AppLanguageController();
        await controller.initialize(support);
        final blocker = Directory('${support.path}/interface-language.pending')
          ..createSync();
        await expectLater(
          controller.setLanguage('pl'),
          throwsA(isA<FileSystemException>()),
        );
        expect(controller.languageCode, 'en');
        blocker.deleteSync();
        await controller.setLanguage('pl');
        expect(controller.languageCode, 'pl');
        controller.dispose();
      } finally {
        support.deleteSync(recursive: true);
      }
    },
  );
}
