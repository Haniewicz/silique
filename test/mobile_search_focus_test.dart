import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mobile_editor_layout_test.dart' show openPhone;

void main() {
  testWidgets(
    'phone search retains its input connection through keyboard metric changes',
    (tester) async {
      await openPhone(tester);
      await tester.tap(find.byKey(const Key('editor-back')));
      await tester.pumpAndSettle();
      final search = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.hintText == 'Szukaj w nazwach i treści…',
      );
      await tester.tap(search);
      await tester.pump();
      final editable = find.descendant(
        of: search,
        matching: find.byType(EditableText),
      );
      final state = tester.state<EditableTextState>(editable);
      expect(state.widget.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(
        tester.state<EditableTextState>(editable),
        same(state),
        reason: 'Hiding the phone header must not recreate search EditableText',
      );
      expect(state.widget.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.enterText(search, 'Stable');
      await tester.pumpAndSettle();
      expect(find.text('Stable heading'), findsOneWidget);
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      expect(tester.state<EditableTextState>(editable), same(state));
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
