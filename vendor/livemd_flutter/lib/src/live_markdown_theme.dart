import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'live_markdown_appearance.dart';

/// Semantic editor styles, usable in ThemeData.extensions or on one editor.
///
/// Null fields inherit. TextStyle fields merge property by property; decorations
/// and borders replace. Appearance merges its individual fields. No field
/// controls document state, focus, page layout, or media dimensions.
@immutable
class LiveMarkdownThemeData extends ThemeExtension<LiveMarkdownThemeData> {
  /// Creates partial overrides. An empty instance preserves the default style.
  const LiveMarkdownThemeData({
    this.bodyStyle,
    this.h1Style,
    this.h2Style,
    this.h3Style,
    this.h4Style,
    this.h5Style,
    this.h6Style,
    this.linkStyle,
    this.codeStyle,
    this.tableBodyStyle,
    this.tableHeadStyle,
    this.codeBlockDecoration,
    this.tableBorder,
    this.tableColumnWidth,
    this.tableVerticalAlignment,
    this.tableCellDecoration,
    this.tableHeaderCellDecoration,
    this.tableCellHorizontalPadding,
    this.tableHeaderCellHorizontalPadding,
    this.appearance,
  }) : assert(
         tableCellHorizontalPadding == null ||
             (tableCellHorizontalPadding >= 0 &&
                 tableCellHorizontalPadding < double.infinity),
       ),
       assert(
         tableHeaderCellHorizontalPadding == null ||
             (tableHeaderCellHorizontalPadding >= 0 &&
                 tableHeaderCellHorizontalPadding < double.infinity),
       );

  /// Openbox's host-adaptive base preset.
  ///
  /// This is the original editor appearance: host bodyMedium with height 1.5,
  /// heading sizes 32/28/24/21/18/16, and host-derived colors. It deliberately
  /// leaves colors and most styles inherited, so it works in light and dark
  /// hosts. The editor uses this preset by default, through the same public
  /// configuration as an explicitly supplied preset.
  const LiveMarkdownThemeData.openbox()
    : this(
        bodyStyle: const TextStyle(height: 1.5),
        h1Style: const TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.w700,
          height: 1.25,
        ),
        h2Style: const TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          height: 1.25,
        ),
        h3Style: const TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          height: 1.25,
        ),
        h4Style: const TextStyle(
          fontSize: 21,
          fontWeight: FontWeight.w700,
          height: 1.25,
        ),
        h5Style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          height: 1.25,
        ),
        h6Style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          height: 1.25,
        ),
        linkStyle: const TextStyle(decoration: TextDecoration.underline),
        // Silique: the bundled app font replaces the generic 'monospace'
        // family, which Flutter does not resolve deterministically on Linux.
        codeStyle: const TextStyle(
          fontFamily: 'RobotoMono',
          fontFamilyFallback: ['monospace'],
        ),
      );

  /// Base text style, also used for Callout and table body defaults.
  final TextStyle? bodyStyle;

  /// Level 1 heading style.
  final TextStyle? h1Style;

  /// Level 2 heading style.
  final TextStyle? h2Style;

  /// Level 3 heading style.
  final TextStyle? h3Style;

  /// Level 4 heading style.
  final TextStyle? h4Style;

  /// Level 5 heading style.
  final TextStyle? h5Style;

  /// Level 6 heading style.
  final TextStyle? h6Style;

  /// Markdown and Wiki link style; an omitted decoration defaults to underline.
  final TextStyle? linkStyle;

  /// Inline and fenced-code text style.
  final TextStyle? codeStyle;

  /// Table body text style.
  final TextStyle? tableBodyStyle;

  /// Table header text style, merged over the table body.
  final TextStyle? tableHeadStyle;

  /// Painted fenced-code background; does not change its layout.
  final Decoration? codeBlockDecoration;

  /// Table border used by the existing table renderer.
  final TableBorder? tableBorder;

  /// Column width policy. Markdown cell alignment remains source-owned.
  final TableColumnWidth? tableColumnWidth;

  /// Vertical alignment of rendered table cells.
  final TableCellVerticalAlignment? tableVerticalAlignment;

  /// Table body cell decoration.
  final Decoration? tableCellDecoration;

  /// Table header decoration; inherits the body decoration when omitted.
  final Decoration? tableHeaderCellDecoration;

  /// Symmetric left/right cell padding. Vertical padding is layout-owned.
  final double? tableCellHorizontalPadding;

  /// Header left/right padding; inherits body padding when omitted.
  final double? tableHeaderCellHorizontalPadding;

  /// Editor-specific paint overrides, merged field by field.
  final LiveMarkdownAppearance? appearance;

  /// Replaces non-null fields. To clear overrides, construct a new partial
  /// theme and replace the old one instead of passing null to copyWith.
  @override
  LiveMarkdownThemeData copyWith({
    TextStyle? bodyStyle,
    TextStyle? h1Style,
    TextStyle? h2Style,
    TextStyle? h3Style,
    TextStyle? h4Style,
    TextStyle? h5Style,
    TextStyle? h6Style,
    TextStyle? linkStyle,
    TextStyle? codeStyle,
    TextStyle? tableBodyStyle,
    TextStyle? tableHeadStyle,
    Decoration? codeBlockDecoration,
    TableBorder? tableBorder,
    TableColumnWidth? tableColumnWidth,
    TableCellVerticalAlignment? tableVerticalAlignment,
    Decoration? tableCellDecoration,
    Decoration? tableHeaderCellDecoration,
    double? tableCellHorizontalPadding,
    double? tableHeaderCellHorizontalPadding,
    LiveMarkdownAppearance? appearance,
  }) => LiveMarkdownThemeData(
    bodyStyle: bodyStyle ?? this.bodyStyle,
    h1Style: h1Style ?? this.h1Style,
    h2Style: h2Style ?? this.h2Style,
    h3Style: h3Style ?? this.h3Style,
    h4Style: h4Style ?? this.h4Style,
    h5Style: h5Style ?? this.h5Style,
    h6Style: h6Style ?? this.h6Style,
    linkStyle: linkStyle ?? this.linkStyle,
    codeStyle: codeStyle ?? this.codeStyle,
    tableBodyStyle: tableBodyStyle ?? this.tableBodyStyle,
    tableHeadStyle: tableHeadStyle ?? this.tableHeadStyle,
    codeBlockDecoration: codeBlockDecoration ?? this.codeBlockDecoration,
    tableBorder: tableBorder ?? this.tableBorder,
    tableColumnWidth: tableColumnWidth ?? this.tableColumnWidth,
    tableVerticalAlignment:
        tableVerticalAlignment ?? this.tableVerticalAlignment,
    tableCellDecoration: tableCellDecoration ?? this.tableCellDecoration,
    tableHeaderCellDecoration:
        tableHeaderCellDecoration ?? this.tableHeaderCellDecoration,
    tableCellHorizontalPadding:
        tableCellHorizontalPadding ?? this.tableCellHorizontalPadding,
    tableHeaderCellHorizontalPadding:
        tableHeaderCellHorizontalPadding ??
        this.tableHeaderCellHorizontalPadding,
    appearance: appearance ?? this.appearance,
  );

  /// Overlays another partial theme without discarding unspecified properties.
  LiveMarkdownThemeData merge(LiveMarkdownThemeData? other) {
    if (other == null) return this;
    return LiveMarkdownThemeData(
      bodyStyle: bodyStyle?.merge(other.bodyStyle) ?? other.bodyStyle,
      h1Style: h1Style?.merge(other.h1Style) ?? other.h1Style,
      h2Style: h2Style?.merge(other.h2Style) ?? other.h2Style,
      h3Style: h3Style?.merge(other.h3Style) ?? other.h3Style,
      h4Style: h4Style?.merge(other.h4Style) ?? other.h4Style,
      h5Style: h5Style?.merge(other.h5Style) ?? other.h5Style,
      h6Style: h6Style?.merge(other.h6Style) ?? other.h6Style,
      linkStyle: linkStyle?.merge(other.linkStyle) ?? other.linkStyle,
      codeStyle: codeStyle?.merge(other.codeStyle) ?? other.codeStyle,
      tableBodyStyle:
          tableBodyStyle?.merge(other.tableBodyStyle) ?? other.tableBodyStyle,
      tableHeadStyle:
          tableHeadStyle?.merge(other.tableHeadStyle) ?? other.tableHeadStyle,
      codeBlockDecoration: other.codeBlockDecoration ?? codeBlockDecoration,
      tableBorder: other.tableBorder ?? tableBorder,
      tableColumnWidth: other.tableColumnWidth ?? tableColumnWidth,
      tableVerticalAlignment:
          other.tableVerticalAlignment ?? tableVerticalAlignment,
      tableCellDecoration: other.tableCellDecoration ?? tableCellDecoration,
      tableHeaderCellDecoration:
          other.tableHeaderCellDecoration ?? tableHeaderCellDecoration,
      tableCellHorizontalPadding:
          other.tableCellHorizontalPadding ?? tableCellHorizontalPadding,
      tableHeaderCellHorizontalPadding:
          other.tableHeaderCellHorizontalPadding ??
          tableHeaderCellHorizontalPadding,
      appearance: appearance?.merge(other.appearance) ?? other.appearance,
    );
  }

  /// Interpolates two extensions during Flutter theme transitions.
  @override
  LiveMarkdownThemeData lerp(covariant LiveMarkdownThemeData? other, double t) {
    if (other == null) return this;
    if (t == 0) return this;
    if (t == 1) return other;
    return LiveMarkdownThemeData(
      bodyStyle: TextStyle.lerp(bodyStyle, other.bodyStyle, t),
      h1Style: TextStyle.lerp(h1Style, other.h1Style, t),
      h2Style: TextStyle.lerp(h2Style, other.h2Style, t),
      h3Style: TextStyle.lerp(h3Style, other.h3Style, t),
      h4Style: TextStyle.lerp(h4Style, other.h4Style, t),
      h5Style: TextStyle.lerp(h5Style, other.h5Style, t),
      h6Style: TextStyle.lerp(h6Style, other.h6Style, t),
      linkStyle: TextStyle.lerp(linkStyle, other.linkStyle, t),
      codeStyle: TextStyle.lerp(codeStyle, other.codeStyle, t),
      tableBodyStyle: TextStyle.lerp(tableBodyStyle, other.tableBodyStyle, t),
      tableHeadStyle: TextStyle.lerp(tableHeadStyle, other.tableHeadStyle, t),
      codeBlockDecoration: Decoration.lerp(
        codeBlockDecoration,
        other.codeBlockDecoration,
        t,
      ),
      tableBorder: TableBorder.lerp(tableBorder, other.tableBorder, t),
      tableColumnWidth: t < 0.5 ? tableColumnWidth : other.tableColumnWidth,
      tableVerticalAlignment: t < 0.5
          ? tableVerticalAlignment
          : other.tableVerticalAlignment,
      tableCellDecoration: Decoration.lerp(
        tableCellDecoration,
        other.tableCellDecoration,
        t,
      ),
      tableHeaderCellDecoration: Decoration.lerp(
        tableHeaderCellDecoration,
        other.tableHeaderCellDecoration,
        t,
      ),
      tableCellHorizontalPadding: lerpDouble(
        tableCellHorizontalPadding,
        other.tableCellHorizontalPadding,
        t,
      ),
      tableHeaderCellHorizontalPadding: lerpDouble(
        tableHeaderCellHorizontalPadding,
        other.tableHeaderCellHorizontalPadding,
        t,
      ),
      appearance: LiveMarkdownAppearance.lerp(appearance, other.appearance, t),
    );
  }
}

/// Resolves public inputs once at the editor; not part of the public library.
/// @nodoc
class ResolvedLiveMarkdownTheme {
  ResolvedLiveMarkdownTheme({
    required ThemeData host,
    LiveMarkdownThemeData? theme,
  }) {
    final overrides = const LiveMarkdownThemeData.openbox()
        .merge(host.extension<LiveMarkdownThemeData>())
        .merge(theme);
    final defaultBody =
        host.textTheme.bodyMedium?.copyWith(height: 1.5) ??
        const TextStyle(fontSize: 14, height: 1.5);
    bodyStyle = defaultBody.merge(overrides.bodyStyle);
    final defaults = _openboxSheet(host, bodyStyle);
    styleSheet = defaults.copyWith(
      h1: defaults.h1?.merge(overrides.h1Style) ?? overrides.h1Style,
      h2: defaults.h2?.merge(overrides.h2Style) ?? overrides.h2Style,
      h3: defaults.h3?.merge(overrides.h3Style) ?? overrides.h3Style,
      h4: defaults.h4?.merge(overrides.h4Style) ?? overrides.h4Style,
      h5: defaults.h5?.merge(overrides.h5Style) ?? overrides.h5Style,
      h6: defaults.h6?.merge(overrides.h6Style) ?? overrides.h6Style,
      a:
          defaults.a
              ?.merge(overrides.linkStyle)
              .copyWith(
                decorationColor:
                    overrides.linkStyle?.decorationColor ??
                    overrides.linkStyle?.color ??
                    defaults.a?.decorationColor,
              ) ??
          overrides.linkStyle,
      code: defaults.code?.merge(overrides.codeStyle) ?? overrides.codeStyle,
      tableBody:
          defaults.tableBody?.merge(overrides.tableBodyStyle) ??
          overrides.tableBodyStyle,
      tableHead:
          defaults.tableHead?.merge(overrides.tableHeadStyle) ??
          overrides.tableHeadStyle,
      codeblockDecoration:
          overrides.codeBlockDecoration ?? defaults.codeblockDecoration,
      tableBorder: overrides.tableBorder ?? defaults.tableBorder,
      tableColumnWidth: overrides.tableColumnWidth ?? defaults.tableColumnWidth,
      tableVerticalAlignment:
          overrides.tableVerticalAlignment ?? defaults.tableVerticalAlignment,
      tableCellsDecoration:
          overrides.tableCellDecoration ?? defaults.tableCellsDecoration,
      tableHeadCellsDecoration:
          overrides.tableHeaderCellDecoration ??
          defaults.tableHeadCellsDecoration,
      tableCellsPadding: overrides.tableCellHorizontalPadding == null
          ? defaults.tableCellsPadding
          : EdgeInsets.symmetric(
              horizontal: overrides.tableCellHorizontalPadding!,
            ),
      tableHeadCellsPadding: overrides.tableHeaderCellHorizontalPadding == null
          ? defaults.tableHeadCellsPadding
          : EdgeInsets.symmetric(
              horizontal: overrides.tableHeaderCellHorizontalPadding!,
            ),
    );
    paint = ResolvedLiveMarkdownAppearance(host, overrides.appearance);
    headingStyles = [
      styleSheet.h1 ?? bodyStyle,
      styleSheet.h2 ?? bodyStyle,
      styleSheet.h3 ?? bodyStyle,
      styleSheet.h4 ?? bodyStyle,
      styleSheet.h5 ?? bodyStyle,
      styleSheet.h6 ?? bodyStyle,
    ];
  }

  late final TextStyle bodyStyle;
  late final MarkdownStyleSheet styleSheet;
  late final ResolvedLiveMarkdownAppearance paint;
  late final List<TextStyle> headingStyles;
}

MarkdownStyleSheet _openboxSheet(ThemeData theme, TextStyle base) {
  const preset = LiveMarkdownThemeData.openbox();
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: base,
    a: base.copyWith(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: theme.colorScheme.primary,
    ),
    code: base.copyWith(
      fontFamily: 'RobotoMono',
      fontFamilyFallback: const ['monospace'],
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
    ),
    h1: base.merge(preset.h1Style),
    h2: base.merge(preset.h2Style),
    h3: base.merge(preset.h3Style),
    h4: base.merge(preset.h4Style),
    h5: base.merge(preset.h5Style),
    h6: base.merge(preset.h6Style),
    blockquote: base,
    checkbox: base.copyWith(color: theme.colorScheme.primary),
    listBullet: base,
    tableBody: base,
  );
}
