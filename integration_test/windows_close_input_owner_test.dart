// Distinct native entry point; do not add registrations to desktop_storage_test.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:silique/l10n/app_language.dart';

import '../test/windows_close_checkpoint_test.dart' as checkpoint;
import '../test/windows_close_checkpoint_probe_test.dart' as checkpoint_control;
import '../test/windows_polish_shortcuts_test.dart' as shortcuts;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows ||
      !const bool.fromEnvironment('SILIQUE_ISOLATED_TEST')) {
    test(
      'requires disposable Windows runner',
      () => fail('Use isolated Windows with SILIQUE_ISOLATED_TEST=true'),
    );
    return;
  }
  setUp(() => appLanguage.setLanguage('pl'));
  // SQLite is native here. Key events are modeled Flutter events: this is not
  // evidence of a physical Polish keyboard or OS text composition.
  group('checkpoint', checkpoint.main);
  group('checkpoint control', checkpoint_control.main);
  group('shortcuts', shortcuts.main);
}
