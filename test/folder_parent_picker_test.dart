import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/ui/dialogs.dart';
import 'package:silique/ui/theme.dart';

void main() {
  testWidgets(
    'folder picker remains scrollable on a narrow phone with keyboard and large text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: siliqueTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.6),
              viewInsets: const EdgeInsets.only(bottom: 220),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => chooseTargetFolder(
                  context,
                  folders: List.generate(30, (index) => 'Folder $index'),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.enterText(
        find.byKey(const Key('folder-target-search')),
        '29',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('folder-target-Folder 29')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('folder-target-Folder 29')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ListTile>(find.byKey(const Key('folder-target-Folder 29')))
            .selected,
        true,
      );
      expect(
        tester.getBottomLeft(find.byKey(const Key('folder-target-confirm'))).dy,
        lessThanOrEqualTo(380),
      );
      await tester.tap(find.text('Anuluj'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'folder parent disables destinations that exceed descendant depth',
    (tester) async {
      final parent = List.generate(11, (index) => 'Level$index').join('/');
      await tester.pumpWidget(
        MaterialApp(
          theme: siliqueTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => chooseTargetFolder(
                  context,
                  sourceFolder: 'Source',
                  folders: ['Source', 'Source/Child', parent],
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('folder-target-search')),
        'Level10',
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<ListTile>(find.byKey(Key('folder-target-$parent'))).onTap,
        isNull,
      );
      await tester.tap(find.text('Anuluj'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'folder parent rejects self, descendants, unchanged and case collisions',
    (tester) async {
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: siliqueTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await chooseTargetFolder(
                    context,
                    sourceFolder: 'A/Child',
                    folders: [
                      'A',
                      'A/Child',
                      'A/Child/Deep',
                      'B',
                      'B/child',
                      'C',
                    ],
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      for (final path in ['A', 'A/Child', 'A/Child/Deep', 'B']) {
        expect(
          tester.widget<ListTile>(find.byKey(Key('folder-target-$path'))).onTap,
          isNull,
          reason: path,
        );
      }
      await tester.enterText(
        find.byKey(const Key('folder-target-search')),
        'C',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('folder-target-C')));
      await tester.pumpAndSettle();
      expect(result, isNull);
      await tester.tap(find.byKey(const Key('folder-target-confirm')));
      await tester.pumpAndSettle();
      expect(result, 'C');
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
