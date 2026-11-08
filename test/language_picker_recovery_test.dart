import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/l10n/app_language.dart';
import 'package:silique/ui/language_picker.dart';

void main() {
  testWidgets(
    'picker distinguishes saved native-refresh failure and retries without losing language',
    (tester) async {
      final previous = debugNativeLanguageWriter;
      debugNativeLanguageWriter = (_) async =>
          throw PlatformException(code: 'language_unavailable');
      try {
        await tester.runAsync(() => appLanguage.setLanguage('en'));
        await tester.pumpWidget(
          const SiliqueMaterialApp(home: Scaffold(body: LanguagePicker())),
        );
        expect(find.byKey(const Key('language-native-retry')), findsOneWidget);
        expect(
          find.text('Could not save the language. Please try again.'),
          findsNothing,
        );
        var calls = 0;
        debugNativeLanguageWriter = (code) async {
          expect(code, 'en');
          calls++;
        };
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const Key('language-native-retry')));
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(appLanguage.nativeSyncPending, isFalse);
        expect(appLanguage.languageCode, 'en');
        expect(find.byKey(const Key('language-native-retry')), findsNothing);
      } finally {
        debugNativeLanguageWriter = previous;
        await tester.runAsync(() => appLanguage.retryNativeSynchronization());
      }
    },
  );

  testWidgets(
    'failed-save error follows current language while selected value is preserved',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('picker-save-error-');
      try {
        await tester.runAsync(() => appLanguage.initialize(root));
        final blocker = Directory('${root.path}/interface-language.pending')
          ..createSync();
        await tester.pumpWidget(
          const SiliqueMaterialApp(home: Scaffold(body: LanguagePicker())),
        );
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const Key('language-pl')));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await tester.pumpAndSettle();
        expect(appLanguage.languageCode, 'en');
        expect(
          find.text('Could not save the language. Please try again.'),
          findsOneWidget,
        );
        blocker.deleteSync();
        await tester.runAsync(() => appLanguage.setLanguage('pl'));
        await tester.pumpAndSettle();
        expect(
          find.text('Nie udało się zapisać języka. Spróbuj ponownie.'),
          findsOneWidget,
        );
        expect(
          find.text('Could not save the language. Please try again.'),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        root.deleteSync(recursive: true);
      }
    },
  );
}
