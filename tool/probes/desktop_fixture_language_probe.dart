// Host-side probe for the native integration entry's own fixture setup.
// Run only the selected platform-independent legacy message tests:
// flutter test tool/probes/desktop_fixture_language_probe.dart \
//   --plain-name 'Windows write failures explain per-app protection'
import 'package:silique/l10n/strings.dart';

import '../../integration_test/desktop_storage_test.dart' as native;

void main() {
  // Do not inherit the outer unit-runner's historical Polish configuration.
  currentLanguageCode = 'en';
  native.main();
}
