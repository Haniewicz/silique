import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/ui/dialogs.dart';

void main() {
  testWidgets(
    'hidden password dialog validates confirmation and disposes sensitive controllers on cancel',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => askHiddenPassword(context, create: true),
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
      final first = tester.widget<TextField>(fields.first).controller!;
      await tester.enterText(fields.first, 'not-a-real-secret');
      await tester.enterText(fields.last, 'different-secret');
      await tester.tap(find.text('Utwórz hasło'));
      await tester.pumpAndSettle();
      expect(find.text('Hasła nie są identyczne.'), findsOneWidget);
      expect(first.text, 'not-a-real-secret');
      await tester.tap(find.text('Anuluj'));
      await tester.pumpAndSettle();
      expect(
        () => first.addListener(() {}),
        throwsFlutterError,
        reason: 'Sensitive controllers must not outlive their route',
      );
    },
  );
}
