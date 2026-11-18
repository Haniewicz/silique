import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/fuzzy_match.dart';
import '../core/models.dart';
import '../core/system_folders.dart';
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

  /// The tag whose notes the switcher is filtered to, or null for an ordinary
  /// text search. Picked from the `#` tag suggestions; cleared with Escape or
  /// the chip's close button.
  String? _tagFilter;

  /// True while the typed query starts with `#`, i.e. the user asked for the
  /// vault's tags instead of notes. A selected [_tagFilter] leaves this mode so
  /// typing again narrows the tagged notes.
  bool get _tagMode => _tagFilter == null && _query.trimLeft().startsWith('#');

  /// The tag fragment typed after the leading `#` characters.
  String get _tagQuery =>
      _query.trimLeft().replaceFirst(RegExp(r'^#+'), '').trim();

  /// Every tag used by the vault's loaded notes, with how many notes cite it.
  /// Sorted by usage so the most relevant suggestions come first, then by name;
  /// [_tagQuery] narrows the list case-insensitively.
  List<_TagEntry> get _tagResults {
    final counts = <String, int>{};
    for (final note in widget.notes) {
      for (final tag in note.tags) {
        final name = tag.trim();
        if (name.isEmpty) continue;
        counts[name] = (counts[name] ?? 0) + 1;
      }
    }
    final fragment = _tagQuery.toLowerCase();
    final entries = [
      for (final entry in counts.entries)
        if (fragment.isEmpty || entry.key.toLowerCase().contains(fragment))
          _TagEntry(entry.key, entry.value),
    ];
    entries.sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      if (byCount != 0) return byCount;
      return a.tag.toLowerCase().compareTo(b.tag.toLowerCase());
    });
    return entries;
  }

  /// Length of the list the arrows and Enter currently walk.
  int get _itemCount => _tagMode ? _tagResults.length : _results.length;

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
    final filter = _tagFilter?.toLowerCase();
    final candidates = filter == null
        ? widget.notes
        : [
            for (final note in widget.notes)
              if (note.tags.any((tag) => tag.toLowerCase() == filter)) note,
          ];
    final q = _query.trim();
    if (q.isEmpty) {
      final recency = List<Note>.of(candidates)
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
    for (final note in candidates) {
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

  void _selectTag(_TagEntry entry) {
    _tagFilter = entry.tag;
    if (_controller.text.isEmpty) {
      setState(() => _highlight = 0);
    } else {
      // Clearing the field re-renders through the controller listener.
      _controller.clear();
    }
    _focus.requestFocus();
  }

  void _clearTagFilter() {
    if (_tagFilter == null) return;
    setState(() {
      _tagFilter = null;
      _highlight = 0;
    });
    _focus.requestFocus();
  }

  /// Escape steps out of the current mode before closing: first the tag filter,
  /// then the typed `#` query, and only then the switcher itself.
  void _escape() {
    if (_tagFilter != null) {
      _clearTagFilter();
      return;
    }
    if (_tagMode) {
      _controller.clear();
      return;
    }
    widget.onClose();
  }

  void _moveHighlight(int delta) {
    final count = _itemCount;
    if (count == 0) return;
    setState(() => _highlight = (_highlight + delta) % count);
  }

  void _confirm() {
    if (_tagMode) {
      final tags = _tagResults;
      if (tags.isEmpty) return;
      _selectTag(tags[_highlight % tags.length]);
      return;
    }
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
                  const SingleActivator(LogicalKeyboardKey.escape): _escape,
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
                            hintText: _tagMode
                                ? tr('Szukaj tagów…', 'Search tags…')
                                : _tagFilter != null
                                ? tr(
                                    'Szukaj w notatkach z tym tagiem…',
                                    'Search notes with this tag…',
                                  )
                                : tr(
                                    'Szukaj notatek… (wpisz #, aby szukać tagów)',
                                    'Search notes… (type # to search tags)',
                                  ),
                            prefixIcon: const Icon(Icons.search, size: 18),
                          ),
                        ),
                      ),
                      if (_tagFilter != null) _tagFilterChip(_tagFilter!),
                      Flexible(
                        child: _tagMode ? _tagList() : _resultsList(results),
                      ),
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
                          localizeSystemFolderPath(match.note.folder),
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

  /// The active tag filter, shown under the field so the narrowing is visible
  /// and can be dropped without closing the switcher.
  Widget _tagFilterChip(String tag) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 0, 8, 4),
    child: Row(
      key: const Key('quick-switcher-tag-filter'),
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.tag, size: 13, color: accent),
              const SizedBox(width: 4),
              Text(
                '#$tag',
                style: const TextStyle(fontSize: 12, color: accent),
              ),
            ],
          ),
        ),
        const Spacer(),
        IconButton(
          key: const Key('quick-switcher-tag-clear'),
          onPressed: _clearTagFilter,
          icon: const Icon(Icons.close, size: 16),
          tooltip: tr('Wyczyść filtr tagu', 'Clear the tag filter'),
        ),
      ],
    ),
  );

  /// Tag suggestions for the typed `#` query: every tag used by the vault's
  /// notes, narrowed case-insensitively, with its note count.
  Widget _tagList() {
    if (widget.locked) {
      return _emptyHint(tr('Vault jest zablokowany.', 'The vault is locked.'));
    }
    final tags = _tagResults;
    if (tags.isEmpty) {
      if (widget.notes.isEmpty) {
        return _emptyHint(
          tr(
            'Brak notatek w tym vaultcie.',
            'There are no notes in this vault.',
          ),
        );
      }
      return _emptyHint(
        _tagQuery.isEmpty
            ? tr(
                'Brak tagów w tym vaultcie.',
                'There are no tags in this vault.',
              )
            : tr('Brak pasujących tagów.', 'No matching tags.'),
      );
    }
    return ListView.builder(
      key: const Key('quick-switcher-tag-list'),
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      itemCount: tags.length,
      itemBuilder: (context, index) {
        final entry = tags[index];
        final selected = index == _highlight;
        return InkWell(
          key: Key('quick-switcher-tag-${entry.tag}'),
          onTap: () => _selectTag(entry),
          child: Container(
            decoration: BoxDecoration(
              color: selected ? cardSelected : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.tag, size: 15, color: muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '#${entry.tag}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${entry.count}',
                  style: const TextStyle(color: muted, fontSize: 11),
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

/// One tag available in the active vault: its stored name (without `#`) and how
/// many loaded notes cite it.
class _TagEntry {
  const _TagEntry(this.tag, this.count);
  final String tag;
  final int count;
}
