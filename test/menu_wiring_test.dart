import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all owned action and choice routes use the common renderer', () {
    for (final path in [
      'lib/ui/home.dart',
      'lib/ui/dialogs.dart',
      'lib/ui/vault_import_dialog.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('DropdownButton')), reason: path);
      expect(source, isNot(contains('PopupMenuItem(')), reason: path);
    }
  });
  test(
    'all ordinary app text fields explicitly use common selection menus',
    () {
      for (final file in Directory('lib/ui').listSync().whereType<File>().where(
        (file) => file.path.endsWith('.dart'),
      )) {
        final source = file.readAsStringSync();
        final fields = RegExp(r'(?<![\w])(?:TextField|SelectableText)\(')
            .allMatches(source)
            .length;
        final hooks = RegExp('contextMenuBuilder:').allMatches(source).length;
        expect(hooks, greaterThanOrEqualTo(fields), reason: file.path);
      }
    },
  );
}
