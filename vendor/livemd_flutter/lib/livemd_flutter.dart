/// Lossless Markdown editing with an in-place live preview.
///
/// Start with [LiveMarkdownController] and [LiveMarkdownEditor]. The application
/// owns controller disposal, persistence, navigation, and media players.
/// For source-aware tooling, use [MarkdownSyntaxParser], [SourceRange], and
/// [applyMarkdownEditingCommand]. All source offsets use UTF-16 code units.
library;

export 'src/live_markdown_appearance.dart' show LiveMarkdownAppearance;
export 'src/live_markdown_theme.dart' show LiveMarkdownThemeData;
export 'src/live_markdown_annotation.dart' show LiveMarkdownAnnotation;
export 'src/live_markdown_controller.dart';
export 'src/desktop_text_context_menu.dart';
export 'src/live_markdown_editor.dart';
export 'src/live_markdown_paste.dart';
export 'src/markdown_menu_presentation.dart';
export 'src/markdown_paste_region.dart'
    show
        MarkdownPasteScope,
        MarkdownPasteRegion,
        markdownContentInsertionConfiguration,
        markdownPasteContextMenu;
export 'src/live_markdown_media.dart';
export 'src/markdown_block.dart';
export 'src/markdown_block_parser.dart';
export 'src/markdown_editing_commands.dart';
export 'src/markdown_syntax_tree.dart';
export 'src/text_selection_edge_auto_scroll.dart';
