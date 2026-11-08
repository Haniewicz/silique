import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/models.dart';

import 'mobile_editor_layout_test.dart' show openPhone;

void main() {
  testWidgets(
    'phone labels creation and edit timestamps separately and editing preserves creation',
    (tester) async {
      final repo = await openPhone(tester);
      final note = repo.notes.values.single.values.single;
      final created = DateTime(2020, 1, 2, 12);
      final edited = DateTime(2022, 3, 4, 13);
      await tester.runAsync(
        () => repo.save(
          Note.fromJson({
            ...note.toJson(),
            'createdAt': created.toIso8601String(),
            'updatedAt': edited.toIso8601String(),
          }),
        ),
      );
      await tester.tap(find.byKey(const Key('editor-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stable heading'));
      await tester.pumpAndSettle();
      expect(find.text('Utworzono: 02.01.2020 12:00'), findsOneWidget);
      expect(find.text('Ostatnia edycja: 04.03.2022 13:00'), findsOneWidget);
      final field = find.byKey(const ValueKey('livemd-document-field'));
      await tester.enterText(field, 'Updated text');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      expect(repo.notes[note.vaultId]![note.id]!.createdAt, created);
      expect(repo.notes[note.vaultId]![note.id]!.updatedAt, isNot(edited));
      await tester.tap(find.byKey(const Key('editor-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stable heading'));
      await tester.pumpAndSettle();
      expect(find.text('Utworzono: 02.01.2020 12:00'), findsOneWidget);
      expect(find.text('Ostatnia edycja: 04.03.2022 13:00'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
