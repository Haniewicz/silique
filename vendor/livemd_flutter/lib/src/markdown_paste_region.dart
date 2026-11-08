import 'dart:async';

import 'package:flutter/material.dart';

import 'live_markdown_controller.dart';
import 'desktop_text_context_menu.dart';
import 'live_markdown_paste.dart';
import 'markdown_paste_controller.dart';
import 'markdown_menu_presentation.dart';

/// One coordinator shared by all native input surfaces in an editor.
class MarkdownPasteScope extends StatefulWidget {
  const MarkdownPasteScope({
    super.key,
    required this.controller,
    required this.configuration,
    required this.child,
  });
  final LiveMarkdownController controller;
  final LiveMarkdownPasteConfiguration? configuration;
  final Widget child;

  static MarkdownPasteController? maybeControllerOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_PasteScope>()?.controller;

  @override
  State<MarkdownPasteScope> createState() => _MarkdownPasteScopeState();
}

class _MarkdownPasteScopeState extends State<MarkdownPasteScope> {
  MarkdownPasteController? _controller;
  VoidCallback? _unsubscribe;
  final _regions = <TextEditingController, MarkdownPasteRegionState>{};
  @override
  void initState() {
    super.initState();
    _create();
  }

  void _create() {
    final configuration = widget.configuration;
    _controller = configuration == null
        ? null
        : MarkdownPasteController(widget.controller, configuration);
    _subscribe();
  }

  void _subscribe() {
    _unsubscribe?.call();
    _unsubscribe = null;
    final clipboard = widget.configuration?.clipboard;
    if (clipboard is LiveMarkdownClipboardEventSource) {
      _unsubscribe = (clipboard as LiveMarkdownClipboardEventSource).subscribe((
        event,
      ) {
        if (!mounted || event.isClaimed) return;
        final region = FocusManager.instance.primaryFocus?.context
            ?.getInheritedWidgetOfExactType<_PasteRegionScope>()
            ?.region;
        if (region == null ||
            !region.enabled ||
            !identical(region._paste, _controller)) {
          return;
        }
        final target = region.captureTarget();
        if (target == null) return;
        // Claim before any await so the browser does not also insert text.
        final snapshot = Future<LiveMarkdownClipboardSnapshot>.sync(
          event.claim,
        );
        unawaited(region.paste(target: target, capturedSnapshot: snapshot));
      });
    }
  }

  @override
  void didUpdateWidget(MarkdownPasteScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        (oldWidget.configuration == null) != (widget.configuration == null)) {
      _controller?.dispose();
      _create();
    } else if (widget.configuration != null) {
      _controller!.configuration = widget.configuration!;
      if (oldWidget.configuration?.clipboard !=
          widget.configuration?.clipboard) {
        _subscribe();
      }
    }
  }

  @override
  void dispose() {
    _unsubscribe?.call();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _PasteScope(
    document: widget.controller,
    controller: _controller,
    regions: _regions,
    child: widget.child,
  );
}

class _PasteScope extends InheritedWidget {
  const _PasteScope({
    required this.document,
    required this.controller,
    required this.regions,
    required super.child,
  });
  final LiveMarkdownController document;
  final MarkdownPasteController? controller;
  final Map<TextEditingController, MarkdownPasteRegionState> regions;
  @override
  bool updateShouldNotify(_PasteScope oldWidget) =>
      oldWidget.controller != controller || oldWidget.document != document;
}

/// Wraps an existing field; its native text editing and formatters remain intact.
class MarkdownPasteRegion extends StatefulWidget {
  const MarkdownPasteRegion({
    super.key,
    required this.field,
    required this.toDocumentOffset,
    this.area = MarkdownPasteArea.document,
    this.containerStart,
    this.row,
    this.column,
  });
  final TextField field;
  final int Function(int offset) toDocumentOffset;
  final MarkdownPasteArea area;
  final int? containerStart;
  final int? row;
  final int? column;

  @override
  State<MarkdownPasteRegion> createState() => MarkdownPasteRegionState();
}

class MarkdownPasteRegionState extends State<MarkdownPasteRegion> {
  MarkdownPasteController? _paste;
  _PasteScope? _scope;
  TextEditingController? _registeredController;
  TextEditingController get _text => widget.field.controller!;

  MarkdownPasteTarget? captureTarget() {
    final selection = _text.selection;
    if (!selection.isValid) return null;
    return MarkdownPasteTarget(
      selection: TextSelection(
        baseOffset: widget.toDocumentOffset(selection.baseOffset),
        extentOffset: widget.toDocumentOffset(selection.extentOffset),
        affinity: selection.affinity,
        isDirectional: selection.isDirectional,
      ),
      area: widget.area,
      containerStart: widget.containerStart,
      row: widget.row,
      column: widget.column,
    );
  }

  bool get enabled => _paste != null && !widget.field.readOnly;
  LiveMarkdownController? get document => _scope?.document;

  Future<void> pasteContent(KeyboardInsertedContent content) {
    final bytes = content.data;
    final uri = Uri.tryParse(content.uri);
    final clipboard = _paste?.configuration.clipboard;
    final snapshot = bytes == null || bytes.isEmpty
        ? clipboard is LiveMarkdownKeyboardContentReader
              ? (clipboard as LiveMarkdownKeyboardContentReader)
                    .readKeyboardContent(content)
              : Future<LiveMarkdownClipboardSnapshot>.error(
                  StateError(
                    'The input method did not supply readable media bytes.',
                  ),
                )
        : Future.value(
            LiveMarkdownClipboardSnapshot(
              media: [
                LiveMarkdownPasteMedia(
                  mimeType: content.mimeType,
                  size: bytes.length,
                  suggestedName: uri != null && uri.pathSegments.isNotEmpty
                      ? uri.pathSegments.last
                      : null,
                  openRead: () => Stream.value(bytes),
                ),
              ],
            ),
          );
    return paste(capturedSnapshot: snapshot);
  }

  Future<void> paste({
    MarkdownPasteTarget? target,
    Future<LiveMarkdownClipboardSnapshot>? capturedSnapshot,
  }) async {
    final coordinator = _paste;
    target ??= captureTarget();
    if (coordinator == null || target == null || widget.field.readOnly) {
      if (capturedSnapshot != null) await (await capturedSnapshot).dispose();
      return;
    }
    await coordinator.paste(
      target,
      pasteText: _pasteText,
      capturedSnapshot: capturedSnapshot,
    );
  }

  int? _localOffset(int global) {
    var low = 0;
    var high = _text.text.length;
    while (low <= high) {
      final middle = (low + high) ~/ 2;
      final mapped = widget.toDocumentOffset(middle);
      if (mapped == global) return middle;
      if (mapped < global) {
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return null;
  }

  EditableTextState? _editable() {
    EditableTextState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is EditableTextState) {
        final state = element.state as EditableTextState;
        if (identical(state.widget.controller, _text)) {
          found = state;
          return;
        }
      }
      element.visitChildren(visit);
    }

    context.visitChildElements(visit);
    return found;
  }

  bool _pasteText(String text, TextRange global) {
    if (!mounted) return false;
    final start = _localOffset(global.start);
    final end = _localOffset(global.end);
    final editable = _editable();
    if (start == null || end == null || editable == null) return false;
    final next = _text.value
        .copyWith(
          selection: TextSelection(baseOffset: start, extentOffset: end),
        )
        .replaced(TextRange(start: start, end: end), text);
    editable.userUpdateTextEditingValue(
      next.copyWith(composing: TextRange.empty),
      SelectionChangedCause.keyboard,
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_PasteScope>();
    if (_scope != scope || _registeredController != _text) {
      _unregister();
      _scope = scope;
      _registeredController = _text;
      scope?.regions[_text] = this;
    }
    _paste = scope?.controller;
    return _PasteRegionScope(
      region: this,
      child: Actions(
        actions: <Type, Action<Intent>>{
          if (_paste != null)
            PasteTextIntent: CallbackAction<PasteTextIntent>(
              onInvoke: (_) {
                unawaited(paste());
                return null;
              },
            ),
          UndoTextIntent: CallbackAction<UndoTextIntent>(
            onInvoke: (_) {
              if (!widget.field.readOnly) document?.undo();
              return null;
            },
          ),
          RedoTextIntent: CallbackAction<RedoTextIntent>(
            onInvoke: (_) {
              if (!widget.field.readOnly) document?.redo();
              return null;
            },
          ),
        },
        child: widget.field,
      ),
    );
  }

  void _unregister() {
    final key = _registeredController;
    if (key != null && identical(_scope?.regions[key], this)) {
      _scope?.regions.remove(key);
    }
  }

  @override
  void dispose() {
    _unregister();
    super.dispose();
  }
}

/// Android's commit-content route, shared by each editor input surface. It
/// routes to the originating field, not whichever field happens to focus later.
ContentInsertionConfiguration? markdownContentInsertionConfiguration(
  BuildContext context,
  TextEditingController controller,
) {
  final scope = context.dependOnInheritedWidgetOfExactType<_PasteScope>();
  final configuration = scope?.controller?.configuration;
  if (scope == null ||
      configuration == null ||
      configuration.contentInsertionMimeTypes.isEmpty) {
    return null;
  }
  return ContentInsertionConfiguration(
    allowedMimeTypes: configuration.contentInsertionMimeTypes,
    onContentInserted: (content) {
      final region = scope.regions[controller];
      if (region == null ||
          !region.enabled ||
          !(region.widget.field.focusNode?.hasFocus ?? false)) {
        return;
      }
      unawaited(region.pasteContent(content));
    },
  );
}

class _PasteRegionScope extends InheritedWidget {
  const _PasteRegionScope({required this.region, required super.child});
  final MarkdownPasteRegionState region;
  @override
  bool updateShouldNotify(_PasteRegionScope oldWidget) =>
      oldWidget.region != region;
}

/// Retains the platform selection toolbar, including a paste entry when the
/// clipboard contains only an image and Flutter's text status is not pasteable.
/// Every platform gets the same full edit menu; a configured media importer
/// stays invocable through the paste override, and `isCurrent` keeps retained
/// callbacks from acting after the document was replaced.
Widget markdownPasteContextMenu(
  BuildContext context,
  EditableTextState editable,
) {
  final region = editable.context
      .dependOnInheritedWidgetOfExactType<_PasteRegionScope>()
      ?.region;
  final target = region?.captureTarget();
  final document = region?.document;
  final items = desktopTextContextMenuItems(
    editable,
    document: document,
    isCurrent: region == null
        ? null
        : () => region.mounted && identical(region.document, document),
    paste: region?.enabled == true
        ? () => unawaited(region!.paste(target: target))
        : null,
  );
  final presentation =
      MarkdownMenuPresentation.maybeOf(context) ??
      MarkdownMenuPresentation.maybeOf(editable.context);
  if (presentation != null) {
    return presentation.selectionToolbarBuilder(
      context,
      editable.contextMenuAnchors,
      items,
    );
  }
  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: editable.contextMenuAnchors,
    buttonItems: items,
  );
}

/// Table cells use the same full edit menu on every platform. Row/column
/// commands remain in the cell's surrounding menu.
Widget markdownCellPasteContextMenu(
  BuildContext context,
  EditableTextState editable,
) => markdownPasteContextMenu(context, editable);
