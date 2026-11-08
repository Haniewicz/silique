import '../l10n/app_language.dart';

import 'package:flutter/material.dart';
import 'package:livemd_flutter/livemd_flutter.dart';

import 'theme.dart';

/// One surface for anchored menus, searchable choices and selection actions.
class SiliqueMenuSurface extends StatelessWidget {
  const SiliqueMenuSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(8),
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) {
    Localizations.localeOf(context);
    return Material(
      color: menuGraphite,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: Colors.black54,
      shape: menuShape,
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
  }
}

/// The ink target itself is rounded, not merely the icon/label inside it.
class SiliqueMenuRow extends StatelessWidget {
  const SiliqueMenuRow({
    super.key,
    required this.child,
    this.icon,
    this.subtitle,
    this.trailing,
    this.selected = false,
    this.enabled = true,
    this.destructive = false,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
  });
  final Widget child;
  final IconData? icon;
  final Widget? subtitle, trailing;
  final bool selected, enabled, destructive;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) {
    Localizations.localeOf(context);
    final color = !enabled
        ? muted.withValues(alpha: .45)
        : destructive
        ? Colors.redAccent
        : Theme.of(context).colorScheme.onSurface;
    return Semantics(
      selected: selected,
      enabled: enabled,
      button: true,
      child: Material(
        color: selected ? accent.withValues(alpha: .13) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: enabled ? onTap : null,
          canRequestFocus: enabled,
          borderRadius: BorderRadius.circular(10),
          hoverColor: menuHover,
          focusColor: menuHover,
          splashColor: accent.withValues(alpha: .16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: padding,
              child: IconTheme(
                data: IconThemeData(
                  size: 20,
                  color: !enabled
                      ? color
                      : destructive
                      ? Colors.redAccent
                      : accent,
                ),
                child: DefaultTextStyle.merge(
                  style: TextStyle(fontSize: 13, color: color),
                  child: Row(
                    children: [
                      if (icon != null) ...[
                        Icon(icon),
                        const SizedBox(width: 14),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            child,
                            if (subtitle != null)
                              DefaultTextStyle.merge(
                                style: TextStyle(
                                  fontSize: 11,
                                  color: enabled ? muted : color,
                                ),
                                child: subtitle!,
                              ),
                          ],
                        ),
                      ),
                      if (trailing != null)
                        trailing!
                      else if (selected)
                        const Icon(Icons.check, size: 18),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

IconData siliqueActionIcon(Object? value) => switch (value) {
  'open' => Icons.open_in_new,
  'rename' => Icons.edit_outlined,
  'move' || 'folder' || 'reveal' => Icons.drive_file_move_outline,
  'color' => Icons.palette_outlined,
  'favorite' => Icons.push_pin_outlined,
  'export' => Icons.ios_share_outlined,
  'restore' => Icons.restore,
  'purge' || 'delete-hidden' => Icons.delete_forever_outlined,
  'trash' => Icons.delete_outline,
  'hide' || 'lock' => Icons.lock_outline,
  'password' => Icons.key_outlined,
  'sub' => Icons.create_new_folder_outlined,
  'new' => Icons.note_add_outlined,
  'updated' => Icons.update_outlined,
  'title' => Icons.sort_by_alpha,
  'created-asc' => Icons.arrow_upward_outlined,
  'created-desc' => Icons.arrow_downward_outlined,
  _ => Icons.folder_outlined,
};

class SiliquePopupItem<T> extends PopupMenuItem<T> {
  const SiliquePopupItem({
    super.key,
    super.value,
    super.enabled,
    required super.child,
    this.icon,
    this.selected = false,
    this.destructive = false,
  });
  final IconData? icon;
  final bool selected, destructive;
  @override
  PopupMenuItemState<T, SiliquePopupItem<T>> createState() =>
      _SiliquePopupItemState<T>();
}

class _SiliquePopupItemState<T>
    extends PopupMenuItemState<T, SiliquePopupItem<T>> {
  @override
  Widget build(BuildContext context) {
    Localizations.localeOf(context);
    return SiliqueMenuRow(
      icon: widget.icon ?? siliqueActionIcon(widget.value),
      enabled: widget.enabled,
      selected: widget.selected,
      destructive:
          widget.destructive ||
          widget.value == 'purge' ||
          widget.value == 'delete-hidden',
      onTap: handleTap,
      child: widget.child ?? const SizedBox.shrink(),
    );
  }
}

/// Integer route values deliberately distinguish a nullable choice from cancel.
class SiliqueChoiceItem<T> {
  const SiliqueChoiceItem({
    required this.value,
    required this.child,
    this.icon = Icons.folder_outlined,
    this.separatorBefore = false,
  });
  final T value;
  final Widget child;
  final IconData icon;
  final bool separatorBefore;
}

class SiliqueChoice<T> extends StatelessWidget {
  const SiliqueChoice({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.decoration,
    this.style,
  });
  final T value;
  final List<SiliqueChoiceItem<T>> items;
  final ValueChanged<T>? onChanged;
  final InputDecoration? decoration;
  final TextStyle? style;
  @override
  Widget build(BuildContext context) {
    Localizations.localeOf(context);
    final selected = items.where((item) => item.value == value).firstOrNull;
    final trigger = Row(
      children: [
        Expanded(
          child: DefaultTextStyle.merge(
            style: style ?? const TextStyle(fontSize: 13),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            child: selected?.child ?? const SizedBox.shrink(),
          ),
        ),
        const SizedBox(width: 8),
        const Icon(Icons.expand_more, size: 18),
      ],
    );
    return PopupMenuButton<int>(
      enabled: onChanged != null,
      tooltip: decoration?.labelText ?? tr('Wybierz vault', 'Choose vault'),
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 420),
      onSelected: (index) => onChanged?.call(items[index].value),
      itemBuilder: (_) => [
        for (var i = 0; i < items.length; i++) ...[
          if (items[i].separatorBefore) const PopupMenuDivider(),
          SiliquePopupItem(
            value: i,
            icon: items[i].icon,
            selected: items[i].value == value,
            child: items[i].child,
          ),
        ],
      ],
      child: decoration == null
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: trigger,
            )
          : InputDecorator(
              decoration: decoration!.copyWith(enabled: onChanged != null),
              isEmpty: selected == null,
              child: trigger,
            ),
    );
  }
}

Widget siliqueSelectionToolbar(
  BuildContext context,
  TextSelectionToolbarAnchors anchors,
  List<ContextMenuButtonItem> items,
) => SiliqueSelectionToolbar(anchors: anchors, buttonItems: items);

class SiliqueSelectionToolbar extends StatelessWidget {
  const SiliqueSelectionToolbar({
    super.key,
    required this.anchors,
    required this.buttonItems,
  });
  final TextSelectionToolbarAnchors anchors;
  final List<ContextMenuButtonItem> buttonItems;

  // Material's TextSelectionToolbar lays its children out as one horizontal
  // strip clamped to a single row of 44px, which hid every row of this
  // vertical menu but the first ("Cofnij" was the only visible command).
  // Position the card directly with a custom layout delegate instead;
  // the constants mirror the Material toolbar's anchor padding.
  static const double _screenPadding = 8.0;
  static const double _contentDistanceAbove = 8.0;

  @override
  Widget build(BuildContext context) {
    Localizations.localeOf(context);
    final media = MediaQuery.of(context);
    final viewInsetsBottom = media.viewInsets.bottom;
    final paddingTop = media.padding.top;
    final viewportHeight = media.size.height;

    // The visible bottom edge of the viewport: the keyboard (viewInsets)
    // carves area out of the bottom. The toolbar must stay entirely above
    // this line with its _screenPadding margin.
    final visibleBottom =
        viewportHeight - viewInsetsBottom - _screenPadding;

    // Anchors in screen coordinates.
    final anchorAbove =
        anchors.primaryAnchor - const Offset(0, _contentDistanceAbove);
    final anchorBelowScreen =
        (anchors.secondaryAnchor ?? anchors.primaryAnchor) +
        const Offset(0, TextSelectionToolbar.kHandleSize - 2);

    // Clamp the below-anchor to the visible area so the delegate never tries
    // to position the card beyond the keyboard.
    final anchorBelow = Offset(
      anchorBelowScreen.dx,
      anchorBelowScreen.dy.clamp(0.0, visibleBottom),
    );

    final topMargin = paddingTop + _screenPadding;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        _screenPadding,
        topMargin,
        _screenPadding,
        _screenPadding,
      ),
      child: CustomSingleChildLayout(
        delegate: _VisibleAreaToolbarDelegate(
          anchorAbove: anchorAbove -
              Offset(_screenPadding, topMargin),
          anchorBelow: anchorBelow -
              Offset(_screenPadding, topMargin),
          visibleBottom:
              visibleBottom - topMargin,
        ),
        child: SiliqueMenuSurface(
          child: SizedBox(
            width: 250,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: visibleBottom - topMargin,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final item in buttonItems)
                      SiliqueMenuRow(
                        icon: switch (item.type) {
                          ContextMenuButtonType.cut => Icons.content_cut,
                          ContextMenuButtonType.copy => Icons.copy_outlined,
                          ContextMenuButtonType.paste =>
                            Icons.content_paste_outlined,
                          ContextMenuButtonType.selectAll => Icons.select_all,
                          ContextMenuButtonType.delete => Icons.delete_outline,
                          _ => Icons.text_fields,
                        },
                        enabled: item.onPressed != null,
                        onTap: item.onPressed,
                        child: Text(
                          AdaptiveTextSelectionToolbar.getButtonLabel(
                            context,
                            item,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A [SingleChildLayoutDelegate] that positions the selection toolbar card
/// above or below the anchor, always clamped within the visible viewport
/// (avoiding the software keyboard area).
class _VisibleAreaToolbarDelegate extends SingleChildLayoutDelegate {
  const _VisibleAreaToolbarDelegate({
    required this.anchorAbove,
    required this.anchorBelow,
    required this.visibleBottom,
  });

  final Offset anchorAbove;
  final Offset anchorBelow;
  final double visibleBottom;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return constraints.loosen();
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // The available Y range: from _screenPadding to visibleBottom - childHeight,
    // leaving a _screenPadding margin at both ends.
    const double pad = SiliqueSelectionToolbar._screenPadding;
    final double maxY = (visibleBottom - childSize.height - pad)
        .clamp(0.0, size.height);
    final double minY = pad.clamp(0.0, maxY);

    // Decide side: if there's more room above the anchor or the card doesn't
    // fit below, put the card above the anchor; otherwise below.
    final bool fitsBelow =
        anchorBelow.dy + childSize.height + pad <= visibleBottom;
    final bool fitsAbove =
        anchorAbove.dy - childSize.height - pad >= 0.0;

    // Use the side with more room when both fit; prefer below when neither
    // fits (the clamp handles the rest).
    double y;
    if (fitsAbove && fitsBelow) {
      final roomAbove = anchorAbove.dy - pad;
      final roomBelow = visibleBottom - anchorBelow.dy - pad;
      y = roomAbove >= roomBelow
          ? anchorAbove.dy - childSize.height - pad
          : anchorBelow.dy + pad;
    } else if (fitsAbove) {
      y = anchorAbove.dy - childSize.height - pad;
    } else if (fitsBelow) {
      y = anchorBelow.dy + pad;
    } else {
      // Neither fits perfectly: put above and let clamp fix it.
      y = anchorAbove.dy - childSize.height - pad;
    }

    y = y.clamp(minY, maxY);

    // Horizontal: clamp to screen padding on both sides.
    final double x = (anchorAbove.dx - childSize.width / 2).clamp(
      pad,
      size.width - childSize.width - pad,
    );

    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_VisibleAreaToolbarDelegate oldDelegate) {
    return anchorAbove != oldDelegate.anchorAbove ||
        anchorBelow != oldDelegate.anchorBelow ||
        visibleBottom != oldDelegate.visibleBottom;
  }
}

/// Every platform gets the same full edit menu; commands that cannot run are
/// present but disabled instead of being omitted.
Widget siliqueTextContextMenu(
  BuildContext context,
  EditableTextState editable,
) => siliqueSelectionToolbar(
  context,
  editable.contextMenuAnchors,
  desktopTextContextMenuItems(
    editable,
    undoLabel: tr('Cofnij', 'Undo'),
    redoLabel: tr('Ponów', 'Redo'),
    deleteLabel: tr('Usuń', 'Delete'),
  ),
);
