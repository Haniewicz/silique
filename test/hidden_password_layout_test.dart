import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/ui/dialogs.dart';
import 'package:silique/ui/theme.dart';

void main() {
  for (final scenario in [
    (create: true, width: 320.0, height: 700.0, keyboard: 320.0, scale: 1.5),
    (create: false, width: 390.0, height: 844.0, keyboard: 400.0, scale: 1.5),
  ]) {
    testWidgets(
      'hidden password fields and validation remain reachable create=${scenario.create} scale=${scenario.scale}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(scenario.width, scenario.height);
        addTearDown(tester.view.reset);
        String? result;
        var closed = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: siliqueTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scenario.scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    result = await askHiddenPassword(
                      context,
                      create: scenario.create,
                    );
                    closed = true;
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final fields = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        );
        expect(fields, findsNWidgets(scenario.create ? 2 : 1));
        final editing = find.descendant(
          of: fields.first,
          matching: find.byType(EditableText),
        );
        final state = tester.state<EditableTextState>(editing);
        await tester.enterText(fields.first, 'test-layout-only');
        tester.view.viewInsets = FakeViewPadding(bottom: scenario.keyboard);
        await tester.pumpAndSettle();
        expect(tester.state<EditableTextState>(editing), same(state));
        expect(state.widget.controller.text, 'test-layout-only');
        expect(state.widget.obscureText, isTrue);
        final submit = find.widgetWithText(
          FilledButton,
          scenario.create ? 'Utwórz hasło' : 'Odblokuj',
        );
        if (scenario.create) {
          await tester.ensureVisible(fields.last);
          await tester.pumpAndSettle();
          await tester.enterText(fields.last, 'different-test-value');
          await tester.tap(submit);
          await tester.pumpAndSettle();
          expect(closed, isFalse);
          final error = find.text('Hasła nie są identyczne.');
          await tester.ensureVisible(error);
          await tester.pumpAndSettle();
          expect(error.hitTestable(), findsOneWidget);
          await tester.ensureVisible(fields.last);
          await tester.pumpAndSettle();
          expect(
            tester.getRect(fields.last).bottom,
            lessThanOrEqualTo(tester.getRect(submit).top),
          );
          await tester.enterText(fields.last, 'test-layout-only');
        } else {
          await tester.ensureVisible(fields.first);
          await tester.pumpAndSettle();
          expect(
            tester.getRect(fields.first).bottom,
            lessThanOrEqualTo(tester.getRect(submit).top),
          );
        }
        expect(
          tester.getRect(submit).bottom,
          lessThanOrEqualTo(scenario.height - scenario.keyboard),
        );
        expect(tester.takeException(), isNull);
        await tester.tap(submit);
        await tester.pumpAndSettle();
        expect(closed, isTrue);
        expect(result, 'test-layout-only');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'hidden password confirmation stays above actions with phone keyboard',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: siliqueTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    result = await askHiddenPassword(context, create: true),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final fields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(fields, findsNWidgets(2));
      await tester.enterText(fields.first, 'test-layout-only');
      tester.view.viewInsets = const FakeViewPadding(bottom: 400);
      await tester.pumpAndSettle();
      await tester.ensureVisible(fields.last);
      await tester.pumpAndSettle();
      final confirmation = tester.getRect(fields.last);
      final actions = tester.getRect(
        find.widgetWithText(FilledButton, 'Utwórz hasło'),
      );
      debugPrint('PASSWORD LAYOUT confirmation=$confirmation actions=$actions');
      expect(
        confirmation.bottom,
        lessThanOrEqualTo(actions.top),
        reason: 'The action row must never cover the confirmation field',
      );
      expect(actions.bottom, lessThanOrEqualTo(844 - 400));
      expect(tester.takeException(), isNull);
      await tester.enterText(fields.last, 'test-layout-only');
      await tester.tap(find.widgetWithText(FilledButton, 'Utwórz hasło'));
      await tester.pumpAndSettle();
      expect(result, 'test-layout-only');
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
