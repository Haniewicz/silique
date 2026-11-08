import 'package:flutter/material.dart';

/// Optional paint-only overrides for LiveMarkdownEditor.
///
/// Null fields preserve the editor's theme-derived defaults. Fonts and layout
/// belong to LiveMarkdownThemeData, editorDecoration and padding. Pass these
/// paint overrides through LiveMarkdownThemeData.appearance.
@immutable
class LiveMarkdownAppearance {
  /// Creates paint overrides without changing editing or layout behavior.
  const LiveMarkdownAppearance({
    this.syntaxColor,
    this.highlightColor,
    this.quoteColor,
    this.taskColor,
    this.calloutAccentColor,
    this.calloutBackgroundColor,
    this.tableActiveCellColor,
    this.calloutBorderSide,
    this.calloutBorderRadius,
  });

  /// Revealed syntax and muted markers/media placeholders. Defaults to the
  /// theme outline in the document and onSurfaceVariant in table previews.
  final Color? syntaxColor;

  /// Background of ==highlight== spans in the document and table previews.
  /// Defaults to yellow with alpha 0.38; supplied alpha is used unchanged.
  final Color? highlightColor;

  /// Quote marker color. Defaults to primary with alpha 0.5.
  final Color? quoteColor;

  /// Checked task marker color. Defaults to primary.
  final Color? taskColor;

  /// Callout border, icon and title color. Defaults to the effective task color.
  final Color? calloutAccentColor;

  /// Callout shell fill in preview and editing. Defaults to the effective
  /// Callout accent with alpha 0.10; supplied alpha is used unchanged.
  final Color? calloutBackgroundColor;

  /// Active table cell fill. Defaults to surfaceContainerHighest at alpha 0.78.
  /// Supplied alpha is used unchanged.
  final Color? tableActiveCellColor;

  /// Painted left border; does not add padding or change the shell dimensions.
  /// Defaults to width 3 in the effective Callout accent color.
  /// Use [BorderSide.none] to hide it. Does not affect title or icon colors.
  final BorderSide? calloutBorderSide;

  /// Shell corner radius; defaults to radius 6. This does not clip content or
  /// change the shell's dimensions or hit regions. Use [BorderRadius.zero]
  /// for square corners.
  final BorderRadius? calloutBorderRadius;

  /// Overlays non-null fields, preserving unspecified values from this object.
  LiveMarkdownAppearance merge(LiveMarkdownAppearance? other) {
    if (other == null) return this;
    return LiveMarkdownAppearance(
      syntaxColor: other.syntaxColor ?? syntaxColor,
      highlightColor: other.highlightColor ?? highlightColor,
      quoteColor: other.quoteColor ?? quoteColor,
      taskColor: other.taskColor ?? taskColor,
      calloutAccentColor: other.calloutAccentColor ?? calloutAccentColor,
      calloutBackgroundColor:
          other.calloutBackgroundColor ?? calloutBackgroundColor,
      tableActiveCellColor: other.tableActiveCellColor ?? tableActiveCellColor,
      calloutBorderSide: other.calloutBorderSide ?? calloutBorderSide,
      calloutBorderRadius: other.calloutBorderRadius ?? calloutBorderRadius,
    );
  }

  /// Interpolates explicit paint overrides. An unspecified endpoint inherits
  /// the other endpoint until the transition reaches it; defaults resolve later.
  static LiveMarkdownAppearance? lerp(
    LiveMarkdownAppearance? a,
    LiveMarkdownAppearance? b,
    double t,
  ) {
    if (t == 0) return a;
    if (t == 1) return b;
    if (a == null) return b;
    if (b == null) return a;
    return LiveMarkdownAppearance(
      syntaxColor: a.syntaxColor == null || b.syntaxColor == null
          ? a.syntaxColor ?? b.syntaxColor
          : Color.lerp(a.syntaxColor, b.syntaxColor, t),
      highlightColor: a.highlightColor == null || b.highlightColor == null
          ? a.highlightColor ?? b.highlightColor
          : Color.lerp(a.highlightColor, b.highlightColor, t),
      quoteColor: a.quoteColor == null || b.quoteColor == null
          ? a.quoteColor ?? b.quoteColor
          : Color.lerp(a.quoteColor, b.quoteColor, t),
      taskColor: a.taskColor == null || b.taskColor == null
          ? a.taskColor ?? b.taskColor
          : Color.lerp(a.taskColor, b.taskColor, t),
      calloutAccentColor:
          a.calloutAccentColor == null || b.calloutAccentColor == null
          ? a.calloutAccentColor ?? b.calloutAccentColor
          : Color.lerp(a.calloutAccentColor, b.calloutAccentColor, t),
      calloutBackgroundColor:
          a.calloutBackgroundColor == null || b.calloutBackgroundColor == null
          ? a.calloutBackgroundColor ?? b.calloutBackgroundColor
          : Color.lerp(a.calloutBackgroundColor, b.calloutBackgroundColor, t),
      tableActiveCellColor:
          a.tableActiveCellColor == null || b.tableActiveCellColor == null
          ? a.tableActiveCellColor ?? b.tableActiveCellColor
          : Color.lerp(a.tableActiveCellColor, b.tableActiveCellColor, t),
      calloutBorderSide:
          a.calloutBorderSide == null || b.calloutBorderSide == null
          ? a.calloutBorderSide ?? b.calloutBorderSide
          : BorderSide.lerp(a.calloutBorderSide!, b.calloutBorderSide!, t),
      calloutBorderRadius:
          a.calloutBorderRadius == null || b.calloutBorderRadius == null
          ? a.calloutBorderRadius ?? b.calloutBorderRadius
          : BorderRadius.lerp(a.calloutBorderRadius, b.calloutBorderRadius, t),
    );
  }
}

/// Internal resolved paint values shared by document and block projections.
/// @nodoc
@immutable
class ResolvedLiveMarkdownAppearance {
  ResolvedLiveMarkdownAppearance(ThemeData theme, LiveMarkdownAppearance? value)
    : syntaxColor = value?.syntaxColor ?? theme.colorScheme.outline,
      tableSyntaxColor =
          value?.syntaxColor ?? theme.colorScheme.onSurfaceVariant,
      highlightColor =
          value?.highlightColor ?? Colors.yellow.withValues(alpha: 0.38),
      quoteColor =
          value?.quoteColor ?? theme.colorScheme.primary.withValues(alpha: 0.5),
      taskColor = value?.taskColor ?? theme.colorScheme.primary,
      calloutAccentColor =
          value?.calloutAccentColor ??
          value?.taskColor ??
          theme.colorScheme.primary,
      tableActiveCellColor =
          value?.tableActiveCellColor ??
          theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.78),
      calloutBorderRadius =
          value?.calloutBorderRadius ?? BorderRadius.circular(6) {
    calloutBackgroundColor =
        value?.calloutBackgroundColor ??
        calloutAccentColor.withValues(alpha: 0.10);
    calloutBorderSide =
        value?.calloutBorderSide ??
        BorderSide(color: calloutAccentColor, width: 3);
  }

  final Color syntaxColor;
  final Color tableSyntaxColor;
  final Color highlightColor;
  final Color quoteColor;
  final Color taskColor;
  final Color calloutAccentColor;
  late final Color calloutBackgroundColor;
  final Color tableActiveCellColor;
  late final BorderSide calloutBorderSide;
  final BorderRadius calloutBorderRadius;
}
