import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/ui/menus.dart';
import 'package:silique/ui/theme.dart';

void main() {
  testWidgets(
    'secret selection toolbar keeps Cut and Copy disabled',
    (tester) async {
      final controller = TextEditingController(text: 'synthetic secret');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: siliqueTheme(),
          home: Scaffold(
            body: TextField(
              controller: controller,
              obscureText: true,
              contextMenuBuilder: siliqueTextContextMenu,
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: controller.text.length,
      );
      await tester.pump();
      final state = tester.state<EditableTextState>(find.byType(EditableText));
      // The framework withholds Cut/Copy entirely for obscured fields.
      expect(
        state.contextMenuButtonItems.map((item) => item.type),
        isNot(contains(ContextMenuButtonType.cut)),
      );
      expect(
        state.contextMenuButtonItems.map((item) => item.type),
        isNot(contains(ContextMenuButtonType.copy)),
      );
      final menu = siliqueTextContextMenu(
        state.context,
        state,
      ) as SiliqueSelectionToolbar;
      // Since 0.2.35 5/8 every platform renders the same full seven-item
      // menu, so a secret field shows Cut/Copy as disabled rows instead of
      // omitting them; they must stay non-invocable.
      expect(menu.buttonItems, hasLength(7));
      final cut = menu.buttonItems.singleWhere(
        (item) => item.type == ContextMenuButtonType.cut,
      );
      final copy = menu.buttonItems.singleWhere(
        (item) => item.type == ContextMenuButtonType.copy,
      );
      expect(cut.onPressed, isNull);
      expect(copy.onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'keyboard traversal skips disabled actions and activates a menu row',
    (tester) async {
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: siliqueTheme(),
          home: Scaffold(
            body: PopupMenuButton<String>(
              itemBuilder: (_) => const [
                SiliquePopupItem(
                  value: 'disabled',
                  enabled: false,
                  child: Text('Disabled action'),
                ),
                SiliquePopupItem(value: 'active', child: Text('Active action')),
              ],
              onSelected: (value) => selected = value,
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selected, 'active');
    },
  );

  testWidgets(
    'nullable choice commits null, escape and outside cancel, disabled stays closed',
    (tester) async {
      final values = <Duration?>[];
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: siliqueTheme(),
          home: Scaffold(
            body: Column(
              children: [
                TextButton(
                  focusNode: focus,
                  onPressed: () {},
                  child: const Text('Focus origin'),
                ),
                SiliqueChoice<Duration?>(
                  value: const Duration(minutes: 5),
                  decoration: const InputDecoration(labelText: 'Duration'),
                  items: const [
                    SiliqueChoiceItem(
                      value: Duration(minutes: 5),
                      icon: Icons.timer_outlined,
                      child: Text('Five minutes'),
                    ),
                    SiliqueChoiceItem(
                      value: null,
                      icon: Icons.logout_outlined,
                      child: Text('On exit'),
                    ),
                  ],
                  onChanged: values.add,
                ),
                const SiliqueChoice<String>(
                  value: 'x',
                  decoration: InputDecoration(labelText: 'Busy choice'),
                  items: [
                    SiliqueChoiceItem(value: 'x', child: Text('Disabled')),
                  ],
                  onChanged: null,
                ),
              ],
            ),
          ),
        ),
      );
      focus.requestFocus();
      await tester.pump();
      await tester.tap(find.byType(SiliqueChoice<Duration?>));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(SiliqueMenuRow, 'Five minutes'),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(values, isEmpty);
      expect(find.byType(SiliqueMenuRow), findsNothing);
      expect(focus.hasFocus, true);
      await tester.tap(find.byType(SiliqueChoice<Duration?>));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(750, 550));
      await tester.pumpAndSettle();
      expect(values, isEmpty);
      await tester.tap(find.byType(SiliqueChoice<Duration?>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('On exit'));
      await tester.pumpAndSettle();
      expect(values, [null]);
      await tester.tap(find.byType(SiliqueChoice<String>));
      await tester.pumpAndSettle();
      expect(find.byType(SiliqueMenuRow), findsNothing);
      expect(
        tester
            .widget<InputDecorator>(
              find.descendant(
                of: find.byType(SiliqueChoice<String>),
                matching: find.byType(InputDecorator),
              ),
            )
            .decoration
            .enabled,
        false,
      );
    },
  );

  testWidgets(
    'rounded rows retain large-label scrolling and disabled/destructive semantics',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 480));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var activated = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: siliqueTheme(),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 480),
              textScaler: TextScaler.linear(2),
            ),
            child: Scaffold(
              body: PopupMenuButton<String>(
                itemBuilder: (_) => [
                  for (var i = 0; i < 12; i++)
                    SiliquePopupItem(
                      value: '$i',
                      child: Text('Long destination folder name $i'),
                    ),
                  SiliquePopupItem(
                    value: 'no',
                    enabled: false,
                    child: const Text('Not allowed'),
                  ),
                  SiliquePopupItem(
                    value: 'purge',
                    child: const Text('Delete permanently'),
                  ),
                ],
                onSelected: (_) => activated = true,
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final disabled = find.widgetWithText(SiliqueMenuRow, 'Not allowed');
      await tester.scrollUntilVisible(
        disabled,
        250,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(disabled);
      await tester.pump();
      expect(activated, false);
      final ink = tester.widget<InkWell>(
        find.descendant(of: disabled, matching: find.byType(InkWell)),
      );
      expect(ink.borderRadius, BorderRadius.circular(10));
      expect(ink.onTap, isNull);
      final destructive = tester.widget<SiliqueMenuRow>(
        find.widgetWithText(SiliqueMenuRow, 'Delete permanently'),
      );
      expect(destructive.destructive, true);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'synthetic menu family render with real Inter and MaterialIcons',
    (tester) async {
      final oldShadows = debugDisableShadows;
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = oldShadows);
      await tester.binding.setSurfaceSize(const Size(1100, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() async {
        final inter = FontLoader('Inter')
          ..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await inter.load();
        await icons.load();
      });
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: siliqueTheme(),
          home: RepaintBoundary(
            key: key,
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'SILIQUE  /  Menu family',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Text(
                      'Synthetic test data · app-owned surfaces only',
                      style: TextStyle(color: muted),
                    ),
                    const SizedBox(height: 28),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 320,
                          child: SiliqueMenuSurface(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SiliqueMenuRow(
                                  icon: Icons.create_new_folder_outlined,
                                  onTap: () {},
                                  child: const Text('Nowy podfolder'),
                                ),
                                SiliqueMenuRow(
                                  icon: Icons.note_add_outlined,
                                  onTap: () {},
                                  child: const Text('Nowa notatka'),
                                ),
                                const Divider(height: 20, color: menuBorder),
                                SiliqueMenuRow(
                                  icon: Icons.edit_outlined,
                                  onTap: () {},
                                  child: const Text('Zmień nazwę'),
                                ),
                                SiliqueMenuRow(
                                  icon: Icons.drive_file_move_outline,
                                  onTap: () {},
                                  child: const Text('Przenieś folder'),
                                ),
                                const Divider(height: 20, color: menuBorder),
                                SiliqueMenuRow(
                                  icon: Icons.delete_outline,
                                  onTap: () {},
                                  child: const Text('Przenieś folder do kosza'),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 24),
                        SizedBox(
                          width: 320,
                          child: SiliqueMenuSurface(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SiliqueMenuRow(
                                  icon: Icons.home_outlined,
                                  onTap: () {},
                                  child: const Text('Wszystkie notatki'),
                                ),
                                const Divider(height: 20, color: menuBorder),
                                SiliqueMenuRow(
                                  icon: Icons.folder_outlined,
                                  selected: true,
                                  onTap: () {},
                                  child: const Text('Projekty'),
                                ),
                                SiliqueMenuRow(
                                  icon: Icons.folder_outlined,
                                  subtitle: const Text('Projekty / Design'),
                                  onTap: () {},
                                  child: const Text('Notatki ze spotkania'),
                                ),
                                const SiliqueMenuRow(
                                  icon: Icons.folder_outlined,
                                  enabled: false,
                                  child: Text('Folder źródłowy'),
                                ),
                                const Divider(height: 20, color: menuBorder),
                                SiliqueMenuRow(
                                  icon: Icons.create_new_folder_outlined,
                                  onTap: () {},
                                  child: const Text('Utwórz nowy folder…'),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 24),
                        Expanded(
                          child: SiliqueMenuSurface(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SiliqueMenuRow(
                                  icon: Icons.content_cut,
                                  onTap: () {},
                                  child: const Text('Wytnij'),
                                ),
                                SiliqueMenuRow(
                                  icon: Icons.copy_outlined,
                                  onTap: () {},
                                  child: const Text('Kopiuj'),
                                ),
                                SiliqueMenuRow(
                                  icon: Icons.content_paste_outlined,
                                  onTap: () {},
                                  child: const Text('Wklej'),
                                ),
                                SiliqueMenuRow(
                                  icon: Icons.select_all,
                                  onTap: () {},
                                  child: const Text('Zaznacz wszystko'),
                                ),
                                const Divider(height: 20, color: menuBorder),
                                SiliqueMenuRow(
                                  icon: Icons.delete_forever_outlined,
                                  destructive: true,
                                  onTap: () {},
                                  child: const Text('Usuń bezpowrotnie'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('Nowy podfolder')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final output = Platform.environment['SILIQUE_MENU_CAPTURE'];
      if (output != null) {
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1.5);
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          await File(output).writeAsBytes(bytes.buffer.asUint8List());
          image.dispose();
        });
      }
      await mouse.removePointer();
      debugDisableShadows = oldShadows;
    },
  );
}
