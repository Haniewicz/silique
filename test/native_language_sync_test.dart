import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/l10n/app_language.dart';

void main() {
  test(
    'native resource failure cannot block startup or undo a saved choice',
    () async {
      final support = Directory.systemTemp.createTempSync(
        'silique-native-language-',
      );
      final previous = debugNativeLanguageWriter;
      final controller = AppLanguageController();
      try {
        debugNativeLanguageWriter = (_) async =>
            throw PlatformException(code: 'language_unavailable');
        await controller.initialize(support);
        expect(controller.languageCode, 'en');
        await controller.setLanguage('pl');
        expect(controller.languageCode, 'pl');
        expect(
          File('${support.path}/interface-language').readAsStringSync(),
          'pl',
        );
        expect(controller.nativeSyncPending, isTrue);
        final calls = <String>[];
        debugNativeLanguageWriter = (code) async {
          calls.add(code);
        };
        await controller.retryNativeSynchronization();
        expect(controller.nativeSyncPending, isFalse);
        expect(calls, ['pl']);
        expect(
          File('${support.path}/interface-language').readAsStringSync(),
          'pl',
        );
        final first = controller.setLanguage('en');
        final second = controller.setLanguage('pl');
        await Future.wait([first, second]);
        expect(controller.languageCode, 'pl');
        expect(calls, ['pl', 'en', 'pl']);
        expect(
          File('${support.path}/interface-language').readAsStringSync(),
          'pl',
        );
      } finally {
        debugNativeLanguageWriter = previous;
        controller.dispose();
        support.deleteSync(recursive: true);
      }
    },
  );
}
