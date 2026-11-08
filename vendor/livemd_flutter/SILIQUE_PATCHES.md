# Local patches to livemd_flutter 0.6.0

Upstream package: https://pub.dev/packages/livemd_flutter/versions/0.6.0
License: LICENSE (retained unchanged).

- Recognize bare HTTP/HTTPS destinations outside code spans and explicit links.
- Align task icon content centrally with a font-sized icon.
- Align the native caret to the rendered character after layout, including headings and mixed row metrics.
- Bring externally selected ranges into view, as required by note search.
- Render standalone media even when its Markdown source wraps, including long attachment IDs and filenames on narrow screens.

Application regression tests: test/editor_rendering_test.dart and test/ui_test.dart.

- Render persistent inline `<span style="font-size:Npx">` formatting for selected text.
- Paint presentation-only search annotations in live Markdown with efficient lookup of matching ranges.

## Mobile and pointer editing (0.2.8)

- Render empty list/task/heading prefixes after the separator, while caret entry into the marker reveals source. Preserve a real trailing space in empty tasks/headings so Flutter can measure the end-of-document caret.
- Protect the task projection between pointer down and pointer up, preventing RenderEditable selection changes from removing the checkbox before its tap fires (mouse regression on Linux).
- Apply Markdown Enter continuation to software-keyboard newline editing values. Keep emoji/IME composition intact and allow keyboard suggestions.
- Scroll the caret into view after native keyboard metrics and viewport changes, including collapsed selections on empty trailing lines.

Regression coverage: test/editor_mobile_markdown_test.dart, test/mobile_improvements_test.dart, integration_test/mobile_editor_test.dart.

- Build 14: keep the last character of rendered task markers invisible even without a trailing separator (`- [ ]`, `- [x]`, `- [X]`), retaining glyph metrics for caret layout without modifying note text. Regression tests type the marker incrementally and check both its painted spans and caret.

- Build 15: complete typed/pasted task markers with a separator in the same undo step; also repair a missing separator when entering a label after an older bare checkbox. Defer changes until IME composition commits and exclude fenced code. Enter continues an empty task instead of exiting/outdenting it; the next task is unchecked and always has trailing whitespace. Backspace still removes an empty marker.

## Narrow links and selection-edge scrolling

- Measure rendered link placeholders with the available content width and the full wrapped paragraph height. Previously the child wrapped inside a one-line-height slot, clipping the destination suffix. Keep full destinations, UTF-16 source offsets, and existing tap/source-reveal behavior; do not insert wrap characters into stored Markdown.
- Add `TextSelectionEdgeAutoScroll`, using Flutter's `EdgeDraggingAutoScroller` after native touch long-press word selection. Extend the document selection after each scroll step with its original anchor adjusted for scroll offset. Ignore pre-timeout pans and mouse pointers; stop on pointer up/cancel, multitouch, lost selection/focus, replacement, and disposal. Clamp the edge zone to short keyboard-constrained viewports.
- `LiveMarkdownEditor` wraps its bounded internal text field automatically. Source-mode hosts must wrap their bounded `TextField` in `TextSelectionEdgeAutoScroll`, supplying the same text and scroll controllers to wrapper and field. This scrolls the editable viewport, not an unrelated outer title/tag scrollable.

Regression coverage: `test/editor_link_wrap_regression_test.dart` (320/390 phone widths, multiline querystring/emoji source, final-glyph tap, focus/arrow-key reveal without source mutation), `test/editor_selection_edge_regression_test.dart` (actual native Android long press, both directions in live/source fields, stationary-pointer continuation, 80/400-height viewports, cancel/up/dispose and ordinary pan).

## Caret and selection ownership (0.2.12)

- Never schedule application caret reveal for a noncollapsed selection. During an active native long-press range selection, disable implicit caret scrolling and stop `showOnScreen` bubbling into ancestor document viewports. Explicit edge scrolling still extends the range; release/cancel restores native caret reveal and programmatic note-search scrolling.
- Refresh the `EdgeDraggingAutoScroller` drag target after every scroll step: its target is stored relative to the document origin, so a stationary finger otherwise stops driving scrolling after one step.
- Regress this through the actual phone document, with keyboard metrics, monotonic upward scrolling, reversals, and cancellation. Keep native source/live tests at both 80px and 400px viewport heights.

## Content-sized phone document (0.2.13)

- Keep the live field content-sized when the phone host owns the whole document
  scroll offset. Use `StackFit.passthrough` and omit the bounded code overlay in
  this mode; desktop fields retain their own bounded viewport and overlays.
- Regress genuine Android IME text growth, not controller assignment: the released
  live layout retained focus/input identity but reset a scrolled note to its head
  after multiline growth. Check the caret's rendered bounds above the keyboard,
  exact text/selection, identity across autosave, and both source/live modes.

Regression coverage: `test/typing_focus_test.dart` and the baseline-compatible
`test/typing_growth_regression_test.dart`; controlled reproduction in `docs/0.2.13.md`.

## Native overlay handle and projection stability (0.2.14)

- Forward Android overlay-handle events through native selection controls to the
  edge coordinator, including the full opaque minimum touch target. The handles
  are not descendants of the field's raw pointer Listener. Keep the context-menu
  API and all other platforms' native controls.
- Range highlighting retains the previous caret's layout-driving projection;
  crossing task prefixes or links must not reveal source and reflow text under
  the dragged handle. The actual source selection/copy stays lossless. A real
  edit or a new caret invalidates this presentation snapshot.
- Place source-mode reveal boundaries below the document scroll viewport, not
  outside it. Test per-frame displacement as well as direction: competing native
  reveal can jump in the same direction and pass a monotonicity-only check.

Regression coverage: `test/mobile_selection_handle_test.dart`,
`test/selection_projection_geometry_test.dart`,
`test/embedded_selection_projection_test.dart`,
`test/overlapping_selection_handles_test.dart`; evidence/limits in
`docs/selection-handle-fix.md`.

Optional rendered PNG evidence: set `SILIQUE_RENDER_EVIDENCE_DIR` to a scratch directory when running the link regression. Set `SILIQUE_RENDER_FONT` to a local TrueType font to replace Flutter test Ahem glyphs in the images; neither option is needed for the default deterministic regressions.

## Hidden-folder editor privacy

- Expose `enableSuggestions` and `enableIMEPersonalizedLearning` without changing
  ordinary editor defaults. Forward privacy to the real field and the embedded
  table source/cell and callout title/body editors, not just the host wrapper.
- Add `LiveMarkdownController.wipe()` to release source, composition, selection,
  annotations and both undo/redo stacks without recording an empty-text undo step.
  Invalidate pending mutations even when the current text is already empty.
  Disposal also releases document history and embedded editing-controller values.
  This releases controller references; immutable Dart strings and external copies
  cannot be zeroed in memory.
- Expose `readOnly` across main and embedded fields and ignore projection pointer
  mutations during a hidden-to-ordinary move. Home freezes before draining saves,
  rejects stale controller callbacks and restores editing if the move fails.

Regression coverage: `test/live_markdown_privacy_test.dart`,
`test/hidden_folder_ui_test.dart`, `test/hidden_notes_home_test.dart`,
`test/hidden_review_regressions_test.dart`.

## Deterministic code font and fenced-block left indent

- Replace the generic `'monospace'` code-family defaults with the bundled
  `RobotoMono` family (`openbox` preset `codeStyle`, `_openboxSheet`, and the
  controller's `?? 'monospace'` fallbacks in `_codeHeightStyle`,
  `_codeSourceStyle`, and the inline `codeSpan` style). Flutter does not
  resolve the fontconfig `monospace` alias deterministically on Linux, which
  painted code text as tofu; the host app bundles `RobotoMono` (OFL) with full
  Polish coverage. `'monospace'` remains only as a `fontFamilyFallback`.
- Give every line of a fenced code block a 14px logical left indent between
  the panel edge and the glyphs (`_codeBlockIndent`). The first UTF-16
  character (or surrogate pair) of each block line is projected into a
  baseline-aligned `WidgetSpan` (`Padding` + `Text`, keyed
  `code-indent-<offset>`) that keeps glyph metrics, composing underline, and
  search annotations, following the established one-placeholder-per-source-
  character pattern, so rendered offsets stay 1:1 with the source and caret,
  hit-tests, and selection remain document-global. The stored Markdown is
  never mutated; empty code lines get no placeholder; paragraphs and lists are
  untouched. Inline code spans are not indented.
- Measure the code-background panel bottom across the whole final line in
  `_measureCodeBackgrounds` (`live_markdown_editor.dart`): a baseline
  placeholder's box covers the full line height while tight text boxes stop at
  the glyph descent, so measuring only the last character left the panel a few
  pixels short of the painted glyphs on the final line once leads exist.

Regression coverage: `test/code_block_indent_test.dart` (indent geometry per
line, paragraph layout unchanged, source unchanged) and the updated
`test/code_block_formatting_test.dart` (panel geometry with lead placeholders,
`RobotoMono` inline code family).
