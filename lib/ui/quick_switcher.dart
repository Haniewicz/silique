import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/fuzzy_match.dart';
import '../core/models.dart';
import '../l10n/app_language.dart';
import 'menus.dart';
import 'theme.dart';

/// A floating, non-navigating quick switcher that overlays the editor.
///
/// It renders a centered top panel (~560 px wide, at most 60% of the window
/// height) over a dimmed barrier, lists notes from the active vault (reading
/// `repo.notes[vaultId]`), and calls [onOpen] through the caller's existing
/// note-selection path so tabs, autosave and breadcrumbs behave exactly as a
/// normal click would.
class QuickSwitcher extends StatefulWidget {
  const QuickSwitcher({
    super.key,
    required this.notes,
    required this.onOpen,
    required this.onClose,
    this.locked = false,
  });

  /// All candidate notes in the active, unlocked vault.
  final List<Note> notes;

  /// When true the vault is locked/inactive and the panel explains why the
  /// list is empty instead of implying the vault has no notes.
  final bool locked;

  /// Opens [note] via the host's `_select`/`_load` path.
  final ValueChanged<Note> onOpen;

  final VoidCallback onClose;

  static const double maxWidth = 560;

  @override
  State<QuickSwitcher> createState() => _QuickSwitcherState();
}

class _QuickSwitcherState extends State<QuickSwitcher> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String _query = '';
  int _highlight = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      setState(() {
        _query = _controller.text;
        _highlight = 0;
      });
    });
    // `autofocus` requests focus during mount, which loses to an existing
    // focus (the editor or title field). Re-assert focus after the first frame
    // so Ctrl+K reliably moves the caret into the switcher.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<FuzzyMatch> get _results {
    final q = _query.trim();
    if (q.isEmpty) {
      final recency = List<Note>.of(widget.notes)
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return [
        for (final note in recency.take(8))
          FuzzyMatch(
            note: note,
            titleScore: 1,
            folderScore: 0,
            titleIndices: const [],
          ),
      ];
    }
    final matches = <FuzzyMatch>[];
    for (final note in widget.notes) {
      final match = fuzzyMatchNote(note, q);
      if (match != null) matches.add(match);
    }
    matches.sort((a, b) {
      if (a.rank != b.rank) return a.rank - b.rank;
      return b.note.updatedAt.compareTo(a.note.updatedAt);
    });
    return matches;
  }

  void _open(FuzzyMatch match) {
    widget.onOpen(match.note);
    widget.onClose();
  }

  void _moveHighlight(int delta) {
    final results = _results;
    if (results.isEmpty) return;
    setState(() => _highlight = (_highlight + delta) % results.length);
  }

  void _confirm() {
    final results = _results;
    if (results.isEmpty) return;
    final index = _highlight < 0 ? 0 : _highlight % results.length;
    _open(results[index]);
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    final media = MediaQuery.sizeOf(context);
    final maxHeight = media.height * 0.6;
    return TapRegion(
      onTapOutside: (_) => widget.onClose(),
      child: ColoredBox(
        color: Colors.black54,
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: EdgeInsets.only(top: media.height * 0.12),
            child: ListenableBuilder(
              listenable: appLanguage,
              builder: (context, _) => CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.escape):
                      widget.onClose,
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                      _moveHighlight(1),
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                      _moveHighlight(-1),
                  const SingleActivator(LogicalKeyboardKey.enter): _confirm,
                  const SingleActivator(LogicalKeyboardKey.numpadEnter):
                      _confirm,
                },
                child: Container(
                  width: QuickSwitcher.maxWidth,
                  constraints: BoxConstraints(maxHeight: maxHeight),
                  decoration: BoxDecoration(
                    color: panel,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: line),
                    boxShadow: [
                      BoxShadow(color: Colors.black54, blurRadius: 24),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                        child: TextField(
                          key: const Key('quick-switcher-field'),
                          controller: _controller,
                          focusNode: _focus,
                          autofocus: true,
                          contextMenuBuilder: siliqueTextContextMenu,
                          decoration: InputDecoration(
                            hintText: tr('Szukaj notatek…', 'Search notes…'),
                            prefixIcon: const Icon(Icons.search, size: 18),
                          ),
                        ),
                      ),
                      Flexible(child: _resultsList(results)),
                      const SizedBox(height: 6),
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

  Widget _resultsList(List<FuzzyMatch> results) {
    if (widget.locked) {
      return _emptyHint(tr('Vault jest zablokowany.', 'The vault is locked.'));
    }
    if (widget.notes.isEmpty) {
      return _emptyHint(
        tr('Brak notatek w tym vaultcie.', 'There are no notes in this vault.'),
      );
    }
    if (results.isEmpty) {
      return _emptyHint(tr('Brak wyników.', 'No results.'));
    }
    return ListView.builder(
      key: const Key('quick-switcher-list'),
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      itemCount: results.length,
      itemBuilder: (context, index) {
        final match = results[index];
        final selected = index == _highlight;
        return InkWell(
          onTap: () => _open(match),
          child: Container(
            decoration: BoxDecoration(
              color: selected ? cardSelected : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _title(match),
                      if (match.note.folder.isNotEmpty)
                        Text(
                          match.note.folder,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: muted, fontSize: 11),
                        ),
                    ],
                  ),
                ),
                if (match.folderOnly)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(Icons.folder_outlined, size: 15),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _title(FuzzyMatch match) {
    final title = match.note.title;
    final indices = match.titleIndices;
    if (indices.isEmpty) {
      return Text(title, maxLines: 1, overflow: TextOverflow.ellipsis);
    }
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final index in indices) {
      if (index > cursor) {
        spans.add(TextSpan(text: title.substring(cursor, index)));
      }
      spans.add(
        TextSpan(
          text: title.substring(index, index + 1),
          style: const TextStyle(color: accent, fontWeight: FontWeight.w700),
        ),
      );
      cursor = index + 1;
    }
    if (cursor < title.length) {
      spans.add(TextSpan(text: title.substring(cursor)));
    }
    return Text.rich(
      TextSpan(children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _emptyHint(String text) => Padding(
    padding: const EdgeInsets.all(20),
    child: Text(text, textAlign: TextAlign.center),
  );
}
