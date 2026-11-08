import 'package:flutter/widgets.dart';

/// Shares keyboard privacy with embedded table and callout editing fields.
/// This is internal to the editor; hosts configure [LiveMarkdownEditor].
class MarkdownInputPrivacy extends InheritedWidget {
  const MarkdownInputPrivacy({
    required this.autocorrect,
    required this.enableSuggestions,
    this.readOnly = false,
    required this.enableIMEPersonalizedLearning,
    required super.child,
    super.key,
  });

  final bool autocorrect;
  final bool enableSuggestions;
  final bool readOnly;
  final bool enableIMEPersonalizedLearning;

  static MarkdownInputPrivacy? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MarkdownInputPrivacy>();

  @override
  bool updateShouldNotify(MarkdownInputPrivacy oldWidget) =>
      readOnly != oldWidget.readOnly ||
      autocorrect != oldWidget.autocorrect ||
      enableSuggestions != oldWidget.enableSuggestions ||
      enableIMEPersonalizedLearning != oldWidget.enableIMEPersonalizedLearning;
}
