import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/ui/menus.dart';

/// Returns seven mock [ContextMenuButtonItem]s similar to the desktop
/// edit menu so geometry assertions are exercised against a realistic
/// vertical list.
List<ContextMenuButtonItem> _mockItems() {
  int tapCounter = 0;
  final labels = [
    'Cofnij',
    'Ponów',
    'Wytnij',
    'Kopiuj',
    'Wklej',
    'Usuń',
    'Zaznacz wszystko',
  ];
  return [
    for (final label in labels)
      ContextMenuButtonItem(
        label: label,
        onPressed: () => tapCounter++,
      ),
  ];
}

/// Wraps [child] in a [MediaQuery] that does NOT zero out [viewInsets].
/// [Scaffold.body] strips viewInsets.bottom by default, so we use a raw
/// [Material] here — the production toolbar renders in an overlay that
/// sees real viewInsets.
Widget _wrapWithInsets({
  required Widget child,
  required Size size,
  EdgeInsets viewInsets = EdgeInsets.zero,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: size, viewInsets: viewInsets),
      child: Material(child: child),
    ),
  );
}

void main() {
  const double margin = 8.0;

  testWidgets(
    '(a) selection at very bottom: every row inside card and inside viewport (margin 8)',
    (tester) async {
      const viewportHeight = 800.0;
      const viewportWidth = 600.0;
      final items = _mockItems();
      final anchorY = viewportHeight - 10.0;
      await tester.pumpWidget(
        _wrapWithInsets(
          size: const Size(viewportWidth, viewportHeight),
          child: SiliqueSelectionToolbar(
            anchors: TextSelectionToolbarAnchors(
              primaryAnchor: Offset(150, anchorY),
            ),
            buttonItems: items,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final card = tester.getRect(find.byType(SiliqueMenuSurface));
      expect(card.top, greaterThanOrEqualTo(margin),
          reason: 'card top $card must clear the top margin');
      expect(card.bottom, lessThanOrEqualTo(viewportHeight - margin),
          reason: 'card bottom $card must clear the bottom margin');
      expect(card.left, greaterThanOrEqualTo(margin));
      expect(card.right, lessThanOrEqualTo(viewportWidth - margin));

      final rows = find.byType(SiliqueMenuRow);
      expect(rows, findsNWidgets(7));
      for (final element in rows.evaluate()) {
        final render = element.renderObject! as RenderBox;
        final row = render.localToGlobal(Offset.zero) & render.size;
        expect(card.contains(row.topLeft) && card.contains(row.bottomRight),
            isTrue,
            reason: 'row $row must be entirely inside card $card');
        expect(row.top >= margin && row.bottom <= viewportHeight - margin,
            isTrue,
            reason: 'row $row must be entirely inside viewport with margin');
      }
    },
    variant: TargetPlatformVariant({TargetPlatform.linux, TargetPlatform.windows}),
  );

  testWidgets(
    '(b) selection at bottom with keyboard insets: card fully visible, '
    'never overlaps keyboard area',
    (tester) async {
      const viewportHeight = 800.0;
      const viewportWidth = 600.0;
      const keyboardHeight = 300.0;
      final items = _mockItems();
      final anchorY = viewportHeight - 10.0;
      await tester.pumpWidget(
        _wrapWithInsets(
          size: const Size(viewportWidth, viewportHeight),
          viewInsets: const EdgeInsets.only(bottom: keyboardHeight),
          child: SiliqueSelectionToolbar(
            anchors: TextSelectionToolbarAnchors(
              primaryAnchor: Offset(150, anchorY),
            ),
            buttonItems: items,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final card = tester.getRect(find.byType(SiliqueMenuSurface));
      final visibleBottom = viewportHeight - keyboardHeight;
      expect(card.bottom, lessThanOrEqualTo(visibleBottom - margin),
          reason: 'card bottom ${card.bottom} must not overlap keyboard '
              '(visible area ends at $visibleBottom, margin $margin)');
      expect(card.top, greaterThanOrEqualTo(margin));

      final rows = find.byType(SiliqueMenuRow);
      expect(rows, findsNWidgets(7));
      for (final element in rows.evaluate()) {
        final render = element.renderObject! as RenderBox;
        final row = render.localToGlobal(Offset.zero) & render.size;
        expect(card.contains(row.topLeft) && card.contains(row.bottomRight),
            isTrue);
        expect(row.bottom, lessThanOrEqualTo(visibleBottom - margin),
            reason: 'row bottom ${row.bottom} must not overlap keyboard '
                '(visible area ends at $visibleBottom)');
      }
    },
    variant: TargetPlatformVariant({TargetPlatform.linux, TargetPlatform.windows}),
  );

  testWidgets(
    '(c) short viewport (500 px) + all 7 items: card shortened, scrollable, '
    'zero rows outside card; last row reachable by drag',
    (tester) async {
      const viewportHeight = 500.0;
      const viewportWidth = 600.0;
      final items = _mockItems();
      final anchorY = viewportHeight / 2;
      await tester.pumpWidget(
        _wrapWithInsets(
          size: const Size(viewportWidth, viewportHeight),
          child: SiliqueSelectionToolbar(
            anchors: TextSelectionToolbarAnchors(
              primaryAnchor: Offset(150, anchorY),
            ),
            buttonItems: items,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final card = tester.getRect(find.byType(SiliqueMenuSurface));
      expect(card.top, greaterThanOrEqualTo(margin));
      expect(card.bottom, lessThanOrEqualTo(viewportHeight - margin));

      final cardHeight = card.bottom - card.top;
      final availableHeight = viewportHeight - margin * 2;
      expect(cardHeight, lessThanOrEqualTo(availableHeight));

      final rows = find.byType(SiliqueMenuRow);
      expect(rows, findsNWidgets(7));
      for (final element in rows.evaluate()) {
        final render = element.renderObject! as RenderBox;
        final row = render.localToGlobal(Offset.zero) & render.size;
        expect(card.contains(row.topLeft) && card.contains(row.bottomRight),
            isTrue,
            reason: 'row $row must be entirely inside card $card');
      }

      // The last row must be reachable through scrolling.
      final lastRow = rows.at(6);
      await tester.ensureVisible(lastRow);
      await tester.pumpAndSettle();
      final lastRender =
          lastRow.evaluate().single.renderObject! as RenderBox;
      final lastRect =
          lastRender.localToGlobal(Offset.zero) & lastRender.size;
      expect(lastRect.bottom, lessThanOrEqualTo(viewportHeight - margin),
          reason: 'last row must be visible after scroll');

      // Also do a scroll drag on the scrollable area.
      final scrollable = find.byType(Scrollable);
      expect(scrollable, findsOneWidget);
      await tester.drag(scrollable, const Offset(0, -100));
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant({TargetPlatform.linux, TargetPlatform.windows}),
  );

  testWidgets(
    '(d) vertical bound assert MUST account for insets: '
    'without insets the card would overflow into the keyboard area',
    (tester) async {
      const viewportHeight = 800.0;
      const viewportWidth = 600.0;
      const keyboardHeight = 300.0;
      final items = _mockItems();
      final anchorY = viewportHeight - 50.0;
      await tester.pumpWidget(
        _wrapWithInsets(
          size: const Size(viewportWidth, viewportHeight),
          viewInsets: const EdgeInsets.only(bottom: keyboardHeight),
          child: SiliqueSelectionToolbar(
            anchors: TextSelectionToolbarAnchors(
              primaryAnchor: Offset(150, anchorY),
            ),
            buttonItems: items,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final visibleBottom = viewportHeight - keyboardHeight;
      final card = tester.getRect(find.byType(SiliqueMenuSurface));
      expect(card.bottom, lessThanOrEqualTo(visibleBottom - margin),
          reason: 'With keyboard insets of $keyboardHeight px, '
              'the card must not extend past the visible viewport '
              '(ends at $visibleBottom). An implementation ignoring '
              'viewInsets.bottom would fail this assertion.');
    },
    variant: TargetPlatformVariant({TargetPlatform.linux, TargetPlatform.windows}),
  );
}