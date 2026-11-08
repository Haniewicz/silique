// Synthetic fixtures only; never invoke app.main or use the runner's notebook.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:silique/l10n/app_language.dart';

import '../test/editor_desktop_context_menu_owner_test.dart' as menus;
import '../test/editor_desktop_home_menu_owner_test.dart' as home;
import '../test/editor_desktop_link_selection_owner_test.dart' as links;
import '../test/folder_reorder_storage_regression_test.dart' as folders;
import '../test/folder_reorder_ui_regression_test.dart' as folder_ui;
import '../test/sidebar_footer_owner_test.dart' as footer;
import '../test/vault_import_test.dart' as imports;
import '../test/vault_import_ui_test.dart' as import_ui;
import '../test/keychain_gate_prompt_regression_test.dart' as credentials;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (!const bool.fromEnvironment('SILIQUE_ISOLATED_TEST') ||
      !(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    test(
      'requires isolated desktop',
      () => fail('Use a disposable desktop with SILIQUE_ISOLATED_TEST=true'),
    );
    return;
  }
  setUp(() => appLanguage.setLanguage('pl'));
  group('menus', menus.main);
  group('home', home.main);
  group('links', links.main);
  group('folders', folders.main);
  group('folder UI', folder_ui.main);
  group('footer', footer.main);
  group('import domain', imports.main);
  group('import UI', import_ui.main);
  // The host `flutter test` phase runs credentials.main(), including the real
  // POSIX child-process regression. Register only the scope contracts here:
  // the unchanged macOS App Sandbox deliberately rejects launching Python.
  // The separate macos_keychain_scope_owner_test.dart still exercises Keychain.
  group('credentials', credentials.registerCredentialScopeTests);
}
