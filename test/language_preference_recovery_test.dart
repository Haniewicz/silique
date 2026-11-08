import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/l10n/app_language.dart';

void main() {
  test('malformed UI preference cannot prevent opening the notebook', () async {
    final support = Directory.systemTemp.createTempSync(
      'silique-language-corrupt-',
    );
    final controller = AppLanguageController();
    try {
      File('${support.path}/interface-language')
          .writeAsBytesSync([255, 254, 255]);
      await controller.initialize(support);
      expect(controller.languageCode, 'en');
      expect(File('${support.path}/interface-language').readAsBytesSync(), [
        255,
        254,
        255,
      ]);
      await controller.setLanguage('pl');
      expect(
        File('${support.path}/interface-language').readAsStringSync(),
        'pl',
      );
    } finally {
      controller.dispose();
      support.deleteSync(recursive: true);
    }
  });
}
