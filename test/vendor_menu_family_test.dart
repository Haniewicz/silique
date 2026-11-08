import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';
import 'package:silique/ui/menus.dart';
import 'package:silique/ui/theme.dart';

class _SyntheticClipboard implements LiveMarkdownClipboard {
  var reads = 0;
  @override
  Future<LiveMarkdownClipboardSnapshot> read() async {
    reads++;
    return LiveMarkdownClipboardSnapshot(text: 'PASTED');
  }
}

void main() {
  testWidgets(
    'vendor menu paste keeps the originating table cell without build-time reads',
    (tester) async {
      final controller = LiveMarkdownController(
        text: '| Header | Other |\n| --- | --- |\n| Cell | Value |\n',
      );
      final clipboard = _SyntheticClipboard();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: siliqueTheme(),
          home: Scaffold(
            body: MarkdownMenuPresentation(
              selectionToolbarBuilder: siliqueSelectionToolbar,
              menuEntryBuilder: (context, value, label, icon, enabled) =>
                  SiliquePopupItem<Object>(
                    value: value,
                    icon: icon,
                    enabled: enabled,
                    child: Text(label),
                  ),
              child: LiveMarkdownEditor(
                controller: controller,
                pasteConfiguration: LiveMarkdownPasteConfiguration(
                  clipboard: clipboard,
                  onImportMedia: (_) async =>
                      throw StateError('text fixture has no media'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('table-cell-0-0-0')),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(clipboard.reads, 0);
      expect(find.widgetWithText(SiliqueMenuRow, 'Paste'), findsOneWidget);
      await tester.tap(find.text('Paste'));
      await tester.pumpAndSettle();
      expect(clipboard.reads, 1);
      expect(controller.text, contains('HeaderPASTED'));
      expect(controller.text, contains('| Cell | Value |'));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'vendor table uses host rows and preserves header/last-column guards',
    (tester) async {
      final controller = LiveMarkdownController(
        text: '| Header |\n| --- |\n| Cell |\n',
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: siliqueTheme(),
          home: Scaffold(
            body: MarkdownMenuPresentation(
              selectionToolbarBuilder: siliqueSelectionToolbar,
              menuEntryBuilder: (context, value, label, icon, enabled) =>
                  SiliquePopupItem<Object>(
                    value: value,
                    icon: icon,
                    enabled: enabled,
                    child: Text(label),
                  ),
              child: LiveMarkdownEditor(controller: controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('table-cell-0-0-0')),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(SiliqueMenuRow, 'Insert row above'),
        findsOneWidget,
      );
      final row = tester.widget<SiliqueMenuRow>(
        find.widgetWithText(SiliqueMenuRow, 'Delete row'),
      );
      final column = tester.widget<SiliqueMenuRow>(
        find.widgetWithText(SiliqueMenuRow, 'Delete column'),
      );
      expect(row.enabled, false);
      expect(column.enabled, false);
      await tester.tap(find.text('Insert row below'));
      await tester.pumpAndSettle();
      expect(
        controller.text
            .split('\n')
            .where((line) => line.startsWith('|'))
            .length,
        4,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
