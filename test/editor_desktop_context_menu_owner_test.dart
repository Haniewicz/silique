import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';
import 'package:silique/ui/menus.dart';
import 'package:silique/l10n/app_language.dart';

import 'fixtures/image_fixtures.dart';

class _OwnerImageClipboard implements LiveMarkdownClipboard {
  int reads = 0;
  @override
  Future<LiveMarkdownClipboardSnapshot> read() async {
    reads++;
    final bytes = sampleBmp(width: 4, height: 4);
    return LiveMarkdownClipboardSnapshot(
      media: [
        LiveMarkdownPasteMedia(
          mimeType: 'image/bmp',
          size: bytes.length,
          openRead: () => Stream.value(bytes),
        ),
      ],
    );
  }
}

void main() {
  testWidgets(
    'desktop image-only paste remains available without toolbar clipboard reads',
    (tester) async {
      final document = LiveMarkdownController(text: 'alpha');
      final editing = TextEditingController(text: 'alpha');
      void syncSource() => editing.value = document.value;
      document.addListener(syncSource);
      final clipboard = _OwnerImageClipboard();
      var imports = 0;
      String? receivedMime;
      List<int>? receivedBytes;
      LiveMarkdownPasteResult? outcome;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MarkdownMenuPresentation(
              selectionToolbarBuilder: siliqueSelectionToolbar,
              menuEntryBuilder: (context, value, label, icon, enabled) =>
                  PopupMenuItem(value: value, child: Text(label)),
              child: MarkdownPasteScope(
                controller: document,
                configuration: LiveMarkdownPasteConfiguration(
                  clipboard: clipboard,
                  onResult: (result) => outcome = result,
                  onImportMedia: (request) async {
                    imports++;
                    receivedMime = request.media.mimeType;
                    receivedBytes = await request.media
                        .openRead()
                        .expand((chunk) => chunk)
                        .toList();
                    return const LiveMarkdownImportedMedia(
                      destination: 'silique-image:synthetic',
                      alt: 'fixture',
                    );
                  },
                ),
                child: MarkdownPasteRegion(
                  toDocumentOffset: (offset) => offset,
                  field: TextField(
                    controller: editing,
                    contextMenuBuilder: markdownPasteContextMenu,
                    onChanged: (_) => document.setValue(editing.value),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.showKeyboard(find.byType(TextField));
      editing.selection = const TextSelection.collapsed(offset: 5);
      document.setSelection(editing.selection);
      await tester.pumpAndSettle();
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      editable.clipboardStatus.value = ClipboardStatus.notPasteable;
      final items = (markdownPasteContextMenu(
        editable.context,
        editable,
      ) as SiliqueSelectionToolbar).buttonItems;
      expect(clipboard.reads, 0);
      expect(imports, 0);
      expect(items[4].onPressed, isNotNull);
      items[4].onPressed!();
      for (var i = 0; i < 40 && outcome == null; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
      expect(outcome?.error, isNull);
      expect(outcome?.status, LiveMarkdownPasteStatus.inserted);
      expect(clipboard.reads, 1);
      expect(imports, 1);
      expect(receivedMime, 'image/bmp');
      expect(receivedBytes, sampleBmp(width: 4, height: 4));
      expect(editing.text, 'alpha![fixture](<silique-image:synthetic>)');
      expect(document.text, editing.text);
      await tester.pumpWidget(const SizedBox());
      document.removeListener(syncSource);
      editing.dispose();
      document.dispose();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'an already open desktop edit menu follows EN PL EN without replacing input',
    (tester) async {
      final controller = TextEditingController(text: 'alpha beta');
      await tester.runAsync(() => appLanguage.setLanguage('en'));
      await tester.pumpWidget(
        SiliqueMaterialApp(
          home: Scaffold(
            body: TextField(
              controller: controller,
              contextMenuBuilder: siliqueTextContextMenu,
            ),
          ),
        ),
      );
      await tester.showKeyboard(find.byType(TextField));
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 5,
      );
      await tester.pump();
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      await tester.tapAt(
        tester.getTopLeft(find.byType(EditableText)) + const Offset(10, 20),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      for (final code in ['en', 'pl', 'en']) {
        await tester.runAsync(() => appLanguage.setLanguage(code));
        await tester.pumpAndSettle();
        expect(find.byType(SiliqueSelectionToolbar), findsOneWidget);
        expect(find.text(code == 'pl' ? 'Cofnij' : 'Undo'), findsOneWidget);
        expect(find.text(code == 'pl' ? 'Ponów' : 'Redo'), findsOneWidget);
        expect(find.text(code == 'pl' ? 'Usuń' : 'Delete'), findsOneWidget);
        expect(
          tester.state<EditableTextState>(find.byType(EditableText)),
          same(editable),
        );
        expect(controller.text, 'alpha beta');
      }
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.runAsync(() => appLanguage.setLanguage('pl'));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'stale live menu cannot undo after document replacement',
    (tester) async {
      final first = LiveMarkdownController(text: 'first');
      final second = LiveMarkdownController(text: 'second');
      var active = first;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return MarkdownMenuPresentation(
                  selectionToolbarBuilder: siliqueSelectionToolbar,
                  menuEntryBuilder: (context, value, label, icon, enabled) =>
                      PopupMenuItem(value: value, child: Text(label)),
                  child: LiveMarkdownEditor(controller: active),
                );
              },
            ),
          ),
        ),
      );
      await tester.showKeyboard(find.byType(TextField));
      first.text = 'first edited';
      await tester.pumpAndSettle();
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      final stale = (markdownPasteContextMenu(
        editable.context,
        editable,
      ) as SiliqueSelectionToolbar).buttonItems;
      expect(stale[0].onPressed, isNotNull);
      update(() => active = second);
      await tester.pumpAndSettle();
      stale[0].onPressed!();
      await tester.pump();
      expect(first.text, 'first edited');
      expect(second.text, 'second');
      await tester.pumpWidget(const SizedBox());
      first.dispose();
      second.dispose();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  for (final scenario in [
    (
      name: 'table',
      text: '| Heading |\n| --- |\n| alpha beta |',
      preview: 'table-cell-0-2-0',
      field: 'table-editor-0-2-0',
    ),
    (
      name: 'callout title',
      text: '> [!note] alpha beta\n> Body words',
      preview: null,
      field: 'callout-title-editor-0',
    ),
    (
      name: 'callout body',
      text: '> [!note] Heading\n> alpha beta',
      preview: null,
      field: 'callout-body-editor-0',
    ),
  ]) {
    testWidgets(
      'active ${scenario.name} right-click exposes complete native text menu and document undo',
      (tester) async {
        final document = LiveMarkdownController(
          text: scenario.text,
          selection: TextSelection.collapsed(offset: scenario.text.length),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MarkdownMenuPresentation(
                selectionToolbarBuilder: siliqueSelectionToolbar,
                menuEntryBuilder: (context, value, label, icon, enabled) =>
                    PopupMenuItem(
                      value: value,
                      enabled: enabled,
                      child: Text(label),
                    ),
                child: LiveMarkdownEditor(controller: document),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          scenario.preview == null
              ? find.text('alpha beta', findRichText: true)
              : find.byKey(ValueKey(scenario.preview!)),
        );
        await tester.pumpAndSettle();
        final finder = find.descendant(
          of: find.byKey(ValueKey(scenario.field)),
          matching: find.byType(EditableText),
        );
        final editable = tester.state<EditableTextState>(finder);
        editable.userUpdateTextEditingValue(
          editable.textEditingValue.copyWith(
            selection: const TextSelection(baseOffset: 0, extentOffset: 5),
          ),
          SelectionChangedCause.keyboard,
        );
        await tester.pump();
        final selectedBox = editable.renderEditable
            .getBoxesForSelection(
              const TextSelection(baseOffset: 0, extentOffset: 5),
            )
            .first;
        await tester.tapAt(
          editable.renderEditable.localToGlobal(selectedBox.toRect().center),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        final toolbar = tester.widget<SiliqueSelectionToolbar>(
          find.byType(SiliqueSelectionToolbar),
        );
        expect(toolbar.buttonItems.length, 7);
        final delete = toolbar.buttonItems[5];
        expect(delete.onPressed, isNotNull);
        delete.onPressed!();
        await tester.pumpAndSettle();
        expect(document.text, scenario.text.replaceFirst('alpha', ''));
        final items = (markdownPasteContextMenu(
          editable.context,
          editable,
        ) as SiliqueSelectionToolbar).buttonItems;
        expect(items[0].onPressed, isNotNull);
        items[0].onPressed!();
        await tester.pumpAndSettle();
        expect(document.text, scenario.text);
        await tester.pumpWidget(const SizedBox());
        document.dispose();
      },
      variant: TargetPlatformVariant({
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets(
    'cut copy paste delete obey real selection clipboard and readOnly including stale callbacks',
    (tester) async {
      String? clipboard;
      var reads = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          switch (call.method) {
            case 'Clipboard.setData':
              clipboard = (call.arguments as Map)['text'] as String;
            case 'Clipboard.getData':
              reads++;
              return {'text': clipboard};
            case 'Clipboard.hasStrings':
              return {'value': clipboard?.isNotEmpty ?? false};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final controller = TextEditingController(text: 'alpha beta');
      var readOnly = false;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return TextField(
                  controller: controller,
                  readOnly: readOnly,
                  contextMenuBuilder: siliqueTextContextMenu,
                );
              },
            ),
          ),
        ),
      );
      await tester.showKeyboard(find.byType(TextField));
      await tester.pumpAndSettle();
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      List<ContextMenuButtonItem> items() => (siliqueTextContextMenu(
        editable.context,
        editable,
      ) as SiliqueSelectionToolbar).buttonItems;
      controller.selection = const TextSelection(
        baseOffset: 5,
        extentOffset: 0,
      );
      await tester.pump();
      items()[3].onPressed!();
      await tester.pump();
      expect(clipboard, 'alpha');
      expect(controller.text, 'alpha beta');
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 5,
      );
      items()[2].onPressed!();
      await tester.pump();
      expect(clipboard, 'alpha');
      expect(controller.text, ' beta');
      await tester.runAsync(() => editable.clipboardStatus.update());
      await tester.pump();
      final beforeMenu = reads;
      expect(items()[4].onPressed, isNotNull);
      expect(
        reads,
        beforeMenu,
        reason: 'Building menus must never read clipboard payloads',
      );
      items()[4].onPressed!();
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(controller.text, 'alpha beta');
      expect(reads, beforeMenu + 1);
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 5,
      );
      final stale = items();
      update(() => readOnly = true);
      await tester.pump();
      expect(items().map((item) => item.onPressed != null).toList(), [
        false,
        false,
        false,
        true,
        false,
        false,
        true,
      ]);
      for (final index in [0, 2, 4, 5]) {
        stale[index].onPressed?.call();
      }
      await tester.pump();
      expect(controller.text, 'alpha beta');
      expect(clipboard, 'alpha');
      items()[3].onPressed!();
      await tester.pump();
      expect(clipboard, 'alpha');
      controller.clear();
      await tester.pump();
      expect(items().every((item) => item.onPressed == null), isTrue);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'live menu uses document history even without media paste configuration',
    (tester) async {
      final document = LiveMarkdownController(text: 'alpha');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MarkdownMenuPresentation(
              selectionToolbarBuilder: siliqueSelectionToolbar,
              menuEntryBuilder: (context, value, label, icon, enabled) =>
                  PopupMenuItem(
                    value: value,
                    enabled: enabled,
                    child: Text(label),
                  ),
              child: LiveMarkdownEditor(controller: document),
            ),
          ),
        ),
      );
      await tester.showKeyboard(find.byType(TextField));
      await tester.pumpAndSettle();
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      List<ContextMenuButtonItem> items() => (markdownPasteContextMenu(
        editable.context,
        editable,
      ) as SiliqueSelectionToolbar).buttonItems;
      document.text = 'alpha beta';
      document.text = 'alpha beta gamma';
      await tester.pump();
      expect(items().length, 7);
      expect(items()[0].onPressed, isNotNull);
      items()[0].onPressed!();
      await tester.pump();
      expect(document.text, 'alpha beta');
      expect(items()[1].onPressed, isNotNull);
      items()[1].onPressed!();
      await tester.pump();
      expect(document.text, 'alpha beta gamma');
      await tester.pumpWidget(const SizedBox());
      document.dispose();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'desktop menu has all seven commands with actual native history and selection state',
    (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.hasStrings') return {'value': false};
          if (call.method == 'Clipboard.getData') return {'text': ''};
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final controller = TextEditingController(text: 'alpha beta');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextField(
              controller: controller,
              contextMenuBuilder: siliqueTextContextMenu,
            ),
          ),
        ),
      );
      await tester.showKeyboard(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      List<ContextMenuButtonItem> items() => (siliqueTextContextMenu(
        editable.context,
        editable,
      ) as SiliqueSelectionToolbar).buttonItems;
      expect(items().map((item) => item.label ?? item.type.name).toList(), [
        'Cofnij',
        'Ponów',
        'cut',
        'copy',
        'paste',
        'Usuń',
        'selectAll',
      ]);
      expect(items().map((item) => item.onPressed != null).toList(), [
        false,
        false,
        false,
        false,
        false,
        false,
        true,
      ]);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'alpha beta!',
          selection: TextSelection.collapsed(offset: 11),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(items()[0].onPressed, isNotNull);
      items()[0].onPressed!();
      await tester.pump();
      expect(controller.text, 'alpha beta');
      expect(items()[1].onPressed, isNotNull);
      items()[1].onPressed!();
      await tester.pump();
      expect(controller.text, 'alpha beta!');
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 5,
      );
      await tester.pump();
      expect(items()[2].onPressed, isNotNull);
      expect(items()[3].onPressed, isNotNull);
      expect(items()[5].onPressed, isNotNull);
      items()[5].onPressed!();
      await tester.pump();
      expect(controller.text, ' beta!');
      expect(controller.selection, const TextSelection.collapsed(offset: 0));
      items()[6].onPressed!();
      await tester.pump();
      expect(
        controller.selection,
        const TextSelection(baseOffset: 0, extentOffset: 6),
      );
      expect(items()[6].onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );
}
