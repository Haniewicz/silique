import 'dart:async';

import 'package:silique/l10n/app_language.dart';

/// Historical UI fixtures assert Polish text. Production still starts in English;
/// bilingual regression tests explicitly exercise both languages and defaults.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  debugNativeLanguageWriter = (_) async {};
  await appLanguage.setLanguage('pl');
  await testMain();
}
