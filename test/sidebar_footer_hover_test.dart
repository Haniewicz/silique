import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/ui/footer_floating_label.dart';
import 'package:silique/ui/theme.dart' show accent, kUiFontFamily, textStrong;

import 'hidden_notes_home_test.dart' show fixture, mount;

final Finder _pill = find.byKey(const Key('footer-floating-label-pill'));

double _windowWidth(WidgetTester tester) =>
    tester.view.physicalSize.width / tester.view.devicePixelRatio;

void main() {
  testWidgets(
    'footer actions hover like folder rows: rounded InkWell, no TextButton',
    (tester) async {
      final repo = await fixture(tester);
      await mount(tester, repo, desktop: true);
      final footer = find.byKey(const Key('sidebar-footer-actions'));
      expect(footer, findsOneWidget);
      expect(
        find.descendant(of: footer, matching: find.byType(TextButton)),
        findsNothing,
      );
      final wells = find.descendant(of: footer, matching: find.byType(InkWell));
      expect(wells, findsNWidgets(4));
      for (final element in wells.evaluate()) {
        final well = element.widget as InkWell;
        expect(well.borderRadius, BorderRadius.circular(6));
        expect(well.onTap, isNotNull);
      }
      // The stable navigation keys stay on the hidden, deleted, import and
      // settings actions.
      for (final key in [
        'deleted-folder-nav',
        'hidden-folder-nav',
        'import-folder-nav',
        'sidebar-settings-nav',
      ]) {
        expect(
          find.descendant(
            of: find.byKey(Key(key)),
            matching: find.byType(InkWell),
          ),
          findsOneWidget,
        );
      }

      // Selecting an action keeps the accent .12 surface with radius 6.
      await tester.tap(find.byKey(const Key('deleted-folder-nav')));
      await tester.pumpAndSettle();
      final surfaces = tester
          .widgetList<Material>(
            find.descendant(
              of: find.byKey(const Key('deleted-folder-nav')),
              matching: find.byType(Material),
            ),
          )
          .where(
            (material) =>
                material.color == accent.withValues(alpha: .12) &&
                material.borderRadius == BorderRadius.circular(6),
          );
      expect(surfaces, isNotEmpty);
      expect(find.byKey(const Key('hidden-folder-nav')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('footer buttons are icon-only with a floating label on hover', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final repo = await fixture(tester);
    await mount(tester, repo, desktop: true);
    final footer = find.byKey(const Key('sidebar-footer-actions'));
    expect(footer, findsOneWidget);

    // No visible text labels live inside the buttons themselves.
    expect(
      find.descendant(of: footer, matching: find.byType(Text)),
      findsNothing,
    );

    // Hovering the deleted action reveals exactly one floating label pill.
    final deleted = find.byKey(const Key('deleted-folder-nav'));
    expect(find.byType(FloatingFooterLabel), findsNWidgets(4));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: tester.getCenter(deleted));
    await gesture.moveTo(tester.getCenter(deleted));
    await tester.pumpAndSettle();
    expect(
      find.text('Usunięte'),
      findsOneWidget,
      reason: 'the floating label shows the localized action name on hover',
    );
    // The accessible name remains available to assistive tech.
    expect(find.bySemanticsLabel('Usunięte'), findsOneWidget);

    // Leaving hides the floating label again.
    await gesture.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(find.text('Usunięte'), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('edge footer pills stay fully inside a narrow desktop surface', (
    tester,
  ) async {
    final repo = await fixture(tester);
    await mount(tester, repo, desktop: true);
    // The desktop breakpoint is 1000 px; this is a narrow desktop surface. The
    // sidebar is 220 px wide, so the first and last footer actions sit within
    // half a pill of the window edge: a 120 px centered pill used to start at a
    // negative `left` and lose its left rounded cap off the window.
    tester.view.physicalSize = const Size(1100, 800);
    await tester.pumpAndSettle();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    final deleted = find.byKey(const Key('deleted-folder-nav'));
    final settings = find.byKey(const Key('sidebar-settings-nav'));

    await gesture.addPointer(location: tester.getCenter(deleted));
    await gesture.moveTo(tester.getCenter(deleted));
    await tester.pumpAndSettle();
    final first = tester.getRect(_pill);
    expect(first.left, greaterThanOrEqualTo(0));
    expect(first.right, lessThanOrEqualTo(_windowWidth(tester)));

    // A metrics change repositions the pill (the observer refreshes the overlay
    // entry after the layout) and never throws on a detached entry. The footer
    // moved vertically with the resize, so the pointer follows it.
    tester.view.physicalSize = const Size(1050, 760);
    await tester.pumpAndSettle();
    await gesture.moveTo(tester.getCenter(deleted));
    await tester.pumpAndSettle();
    final resized = tester.getRect(_pill);
    expect(resized.left, greaterThanOrEqualTo(0));
    expect(resized.right, lessThanOrEqualTo(_windowWidth(tester)));
    // The pill sits `_pillHeight + _anchorGap` above the footer row.
    expect(
      resized.top,
      moreOrLessEquals(
        tester.getRect(find.byKey(const Key('sidebar-footer-actions'))).top -
            24,
      ),
    );

    await gesture.moveTo(tester.getCenter(settings));
    await tester.pumpAndSettle();
    final last = tester.getRect(_pill);
    expect(last.left, greaterThanOrEqualTo(0));
    expect(last.right, lessThanOrEqualTo(_windowWidth(tester)));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pill follows a vertically resized window instead of keeping a stale top',
    (tester) async {
      final repo = await fixture(tester);
      await mount(tester, repo, desktop: true);
      const footerKey = Key('sidebar-footer-actions');
      final deleted = find.byKey(const Key('deleted-folder-nav'));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: tester.getCenter(deleted));
      await gesture.moveTo(tester.getCenter(deleted));
      await tester.pumpAndSettle();

      // Review case: hovering at 1440x1000 gives a pill just above the footer.
      final startPill = tester.getRect(_pill);
      final startFooter = tester.getRect(find.byKey(footerKey));
      expect(startPill.top, moreOrLessEquals(startFooter.top - 24));

      // Grow the window by 400 px: the footer moves down by 400 px. The entry
      // must be rebuilt after the new layout instead of keeping the old top.
      tester.view.physicalSize = const Size(1440, 1400);
      await tester.pumpAndSettle();
      await gesture.moveTo(tester.getCenter(deleted));
      await tester.pumpAndSettle();
      final grownPill = tester.getRect(_pill);
      final grownFooter = tester.getRect(find.byKey(footerKey));
      expect(grownPill.top, moreOrLessEquals(grownFooter.top - 24));
      expect(grownPill.top, greaterThan(startPill.top + 300));
      expect(
        grownPill.top,
        isNot(startPill.top),
        reason: 'the pill must not keep the pre-resize position',
      );

      // Shrink back to the desktop breakpoint: a repeat hover after the resize
      // still lands above the footer and inside the window.
      tester.view.physicalSize = const Size(1000, 700);
      await tester.pumpAndSettle();
      await gesture.moveTo(tester.getCenter(deleted));
      await tester.pumpAndSettle();
      final shrunkPill = tester.getRect(_pill);
      final shrunkFooter = tester.getRect(find.byKey(footerKey));
      expect(shrunkPill.top, moreOrLessEquals(shrunkFooter.top - 24));
      expect(shrunkPill.top, greaterThanOrEqualTo(0));
      expect(shrunkPill.bottom, lessThanOrEqualTo(700));
      expect(shrunkPill.left, greaterThanOrEqualTo(0));
      expect(shrunkPill.right, lessThanOrEqualTo(1000));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pill width follows the label instead of a fixed width', (
    tester,
  ) async {
    final repo = await fixture(tester);
    await mount(tester, repo, desktop: true);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    final deleted = find.byKey(const Key('deleted-folder-nav'));
    final settings = find.byKey(const Key('sidebar-settings-nav'));
    await gesture.addPointer(location: tester.getCenter(deleted));
    await gesture.moveTo(tester.getCenter(deleted));
    await tester.pumpAndSettle();

    // The old pill was a hard 120 px wide. "Usunięte" at 11 px is much narrower.
    final shortPill = tester.getRect(_pill);
    expect(shortPill.width, lessThan(120));
    expect(shortPill.height, 22);

    // The label is rendered in full: measured width plus padding, no ellipsis.
    final label = find.text('Usunięte');
    expect(label, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(label);
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(shortPill.width, greaterThan(paragraph.size.width));

    // The style is pinned to the pill look: no inherited decoration.
    final style = DefaultTextStyle.of(tester.element(label)).style;
    expect(style.fontSize, 11);
    expect(style.decoration, TextDecoration.none);

    // A longer label grows the pill: width is measured, not fixed.
    await gesture.moveTo(tester.getCenter(settings));
    await tester.pumpAndSettle();
    expect(find.text('Ustawienia'), findsOneWidget);
    expect(tester.getRect(_pill).width, greaterThan(shortPill.width));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pill label uses the UI type, not the MaterialApp text fallback',
    (tester) async {
      final repo = await fixture(tester);
      await mount(tester, repo, desktop: true);
      final deleted = find.byKey(const Key('deleted-folder-nav'));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: tester.getCenter(deleted));
      await gesture.moveTo(tester.getCenter(deleted));
      await tester.pumpAndSettle();

      final label = find.text('Usunięte');
      expect(label, findsOneWidget);
      // The pill is a bare Overlay entry with no Material above it: without an
      // explicit style it inherits MaterialApp's glaring fallback (monospace,
      // w900, yellow double underline) instead of the UI type.
      final effective = DefaultTextStyle.of(tester.element(label)).style;
      expect(effective.fontFamily, kUiFontFamily);
      expect(effective.fontFamily, 'Inter');
      expect(effective.fontWeight, FontWeight.w400);
      expect(effective.fontSize, 11);
      expect(effective.color, textStrong);
      expect(effective.decoration, TextDecoration.none);
      // Not the fallback style, in any of its features.
      expect(effective.fontFamily, isNot('monospace'));
      expect(effective.fontWeight, isNot(FontWeight.w900));
      expect(effective.decoration, isNot(TextDecoration.underline));
      expect(effective.decorationColor, isNot(const Color(0xFFFFFF00)));
      expect(effective.fontSize, isNot(48));

      // Positioning did not regress: the whole pill is still inside the window.
      final pill = tester.getRect(_pill);
      expect(pill.left, greaterThanOrEqualTo(0));
      expect(pill.right, lessThanOrEqualTo(_windowWidth(tester)));
      expect(tester.takeException(), isNull);
    },
  );
}
