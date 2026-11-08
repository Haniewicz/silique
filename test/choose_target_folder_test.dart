import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/ui/dialogs.dart';
import 'package:silique/ui/theme.dart';

void main() {
  Future<void> openPicker(
    WidgetTester tester,
    ValueChanged<String?> onResult, {
    List<String> folders = const ['Prywatne', 'Projekty/Mercaro', 'Projekty'],
    String initial = '',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: siliqueTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => onResult(
                await chooseTargetFolder(
                  context,
                  folders: folders,
                  initial: initial,
                ),
              ),
              child: const Text('Open picker'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
  }

  testWidgets('root is first and selected by default, even from a folder', (
    tester,
  ) async {
    String? result;
    await openPicker(tester, (value) => result = value, initial: 'Projekty');
    final rows = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect((rows.first.title as Text).data, 'Wszystkie notatki');
    final root = tester.widget<ListTile>(
      find.byKey(const Key('folder-target-root')),
    );
    expect(root.selected, true);
    expect(root.selectedColor, accent);
    expect(root.selectedTileColor, accent.withValues(alpha: .13));
    expect(find.byKey(const Key('folder-target-field')), findsNothing);
    await tester.tap(find.byKey(const Key('folder-target-confirm')));
    await tester.pumpAndSettle();
    expect(result, '');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('selecting a nested folder waits for confirmation', (
    tester,
  ) async {
    String? result;
    await openPicker(tester, (value) => result = value);
    final rows = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect(rows.map((row) => (row.title as Text).data), [
      'Wszystkie notatki',
      'Projekty',
      'Mercaro',
      'Prywatne',
    ]);
    final parent = tester.widget<ListTile>(
      find.byKey(const Key('folder-target-Projekty')),
    );
    final child = tester.widget<ListTile>(
      find.byKey(const Key('folder-target-Projekty/Mercaro')),
    );
    expect(
      (child.contentPadding as EdgeInsets).left,
      greaterThan((parent.contentPadding as EdgeInsets).left),
    );
    await tester.tap(find.byKey(const Key('folder-target-Projekty/Mercaro')));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.text('Przenieś do folderu'), findsOneWidget);
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const Key('folder-target-Projekty/Mercaro')),
          )
          .selected,
      true,
    );
    expect(
      tester
          .widget<ListTile>(find.byKey(const Key('folder-target-root')))
          .selected,
      false,
    );
    await tester.tap(find.byKey(const Key('folder-target-confirm')));
    await tester.pumpAndSettle();
    expect(result, 'Projekty/Mercaro');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('searches nested folders by name without losing selection', (
    tester,
  ) async {
    String? result;
    await openPicker(
      tester,
      (value) => result = value,
      folders: ['Projekty', 'Projekty/Mercaro', 'Archiwum', 'Archiwum/Mercaro'],
    );
    await tester.tap(find.byKey(const Key('folder-target-Projekty/Mercaro')));
    await tester.enterText(
      find.byKey(const Key('folder-target-search')),
      'merc',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('folder-target-Projekty')), findsNothing);
    expect(
      find.byKey(const Key('folder-target-Projekty/Mercaro')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('folder-target-Archiwum/Mercaro')),
      findsOneWidget,
    );
    expect(
      (tester
                  .widget<ListTile>(
                    find.byKey(const Key('folder-target-Archiwum/Mercaro')),
                  )
                  .subtitle
              as Text)
          .data,
      'Archiwum',
    );
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const Key('folder-target-Projekty/Mercaro')),
          )
          .selected,
      true,
    );
    expect(result, isNull);
    await tester.enterText(
      find.byKey(const Key('folder-target-search')),
      'nie-ma',
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('folder-target-Projekty/Mercaro')),
      findsNothing,
    );
    expect(find.text('Wybrano: Projekty/Mercaro'), findsOneWidget);
    await tester.tap(find.byKey(const Key('folder-target-confirm')));
    await tester.pumpAndSettle();
    expect(result, 'Projekty/Mercaro');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('cancel after selecting a folder returns null', (tester) async {
    final results = <String?>[];
    await openPicker(tester, results.add);
    await tester.tap(find.byKey(const Key('folder-target-Prywatne')));
    await tester.pumpAndSettle();
    expect(results, isEmpty);
    await tester.tap(find.text('Anuluj'));
    await tester.pumpAndSettle();
    expect(results, [null]);
    await tester.pump(const Duration(seconds: 1));
  });
}
