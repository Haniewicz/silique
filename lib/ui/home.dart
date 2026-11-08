import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:image_picker/image_picker.dart';

import 'image_attachment_provider.dart';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livemd_flutter/livemd_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart' show notebookProvider;
import '../core/models.dart';
import '../l10n/app_language.dart';
import '../core/search.dart';
import '../core/span_size.dart';
import '../core/workspace.dart';
import '../services/notebook.dart';
import '../services/android_widgets.dart';
import '../services/sync_coordinator.dart';
import '../services/app_updates.dart';
import '../core/updates.dart';
import '../services/windows_update_handoff.dart';
import '../storage/native_files.dart';
import '../storage/native_image_clipboard.dart';
import '../storage/native_storage.dart';
import '../storage/native_window.dart';
import 'color_picker.dart';
import 'dialogs.dart';
import 'highlight_controller.dart';
import 'theme.dart';
import 'menus.dart';
import 'top_pull_dismiss.dart';
import 'mobile_note_viewport.dart';
import 'vault_import_dialog.dart';
import 'vault_delete_dialog.dart';

part 'home_android_widgets.dart';

String get exampleBody => tr(
  '''## 🎯 Główne cele

- [x] Stworzyć przestrzeń na dobre pomysły
- [ ] Zaplanować najważniejsze zadania
- [ ] Znaleźć czas na to, co ważne

## 🗓 Spotkania

- **Poniedziałek 10:00** — Planowanie tygodnia
- **Środa 14:00** — Czas na pracę w skupieniu
- **Piątek 15:00** — Podsumowanie i nowe pomysły

## 💡 Pomysły

- Zapisuj myśli, zanim uciekną
- Łącz notatki za pomocą [[linków]]
- Zorganizuj projekty we własnych folderach

> Małe, regularne kroki prowadzą do dużych rezultatów.

## 📊 Notatki

To Twoja przestrzeń. Notatki zapisują się automatycznie, również bez internetu. Serwer możesz dodać później w ustawieniach.
''',
  '''## 🎯 Main goals

- [x] Make room for good ideas
- [ ] Plan the most important tasks
- [ ] Find time for what matters

## 🗓 Meetings

- **Monday 10:00** — Weekly planning
- **Wednesday 14:00** — Focused work
- **Friday 15:00** — Review and new ideas

## 💡 Ideas

- Write down thoughts before they slip away
- Connect notes using [[links]]
- Organize projects in your own folders

> Small, regular steps lead to big results.

## 📊 Notes

This is your space. Notes save automatically, even offline. You can add a server later in settings.
''',
);

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key, this.androidWidgets, this.updater});
  final AndroidWidgets? androidWidgets;
  final AppUpdater? updater;
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  final _scaffold = GlobalKey<ScaffoldState>();
  final _sourceViewport = GlobalKey();
  final _editorViewport = GlobalKey();

  /// Coordinates the floating wiki panel over the document viewport. The
  /// caret rectangle lives in [_wikiStackKey] coordinates and is refreshed
  /// after frames whose editing value actually changed; see
  /// [_scheduleWikiAnchorUpdate].
  final _wikiStackKey = GlobalKey();
  Rect? _wikiCaret;
  TextEditingValue? _wikiAnchorValue;
  bool _wikiFocusFramePending = false;
  bool _droppingImage = false;
  final _search = TextEditingController(), _title = TextEditingController();
  final _searchFocus = FocusNode();
  final _sourceFocus = FocusNode();
  final _titleFocus = FocusNode();

  LiveMarkdownController _editor = LiveMarkdownController();
  Timer? _autosave;
  late final SyncCoordinator _syncCoordinator;
  StreamSubscription<void>? _localChanges;
  StreamSubscription<String>? _vaultDeletions;
  late final AndroidWidgets _androidWidgets =
      widget.androidWidgets ?? AndroidWidgets(notebook: repo);
  StreamSubscription<WidgetAction>? _widgetActions;
  Future<void> _widgetTail = Future<void>.value();
  StreamSubscription<void>? _hiddenChanges;
  Timer? _hiddenWatch;
  final _hiddenNotes = <String, Note>{};
  final _editorImages = <ImageProvider<Object>>{};
  Future<void> _hiddenPending = Future<void>.value();
  Object? _hiddenSaveError;
  bool _revealingHidden = false;
  bool get _editorReadOnly =>
      _windowsUpdateBlocked ||
      _revealingHidden ||
      (_vaultId != null && repo.vaultDeletionPending(_vaultId!));
  int _hiddenEpoch = 0;
  bool get _inHidden => _filter == 'Ukryte';
  bool get _hiddenAvailable => _inHidden && unlocked && repo.hiddenUnlocked;
  Note? _noteById(String? id) => _inHidden
      ? (_hiddenAvailable ? _hiddenNotes[id] : null)
      : repo.notes[_vaultId]?[id];
  late final _updates = widget.updater ??
      AppUpdater(
        restartAfterInstall: Platform.isLinux ? NativeWindow.restart : null,
      );
  bool _windowsUpdateBlocked = false;
  DialogRoute<void>? _windowsUpdateBarrier;
  int? _announcedUpdate;
  String? _vaultId, _folder;
  Note? _selected;
  String _filter = 'Wszystkie',
      _query = '',
      _status = 'Lokalnie',
      _sort = 'updated';
  bool _mobileEditor = false,
      _focus = false,
      _source = false,
      _syncing = false,
      _busy = false,
      _loading = false,
      _dirty = false,
      _notesCollapsed = false;
  final _tabs = <String>[];
  /// Most-recently-used order of opened tabs (front = most recent). Mirrors
  /// `_tabs` ids so closing the selected tab can fall back to the last note
  /// the user actually looked at, before resorting to a positional neighbor.
  final _tabOrder = <String>[];
  final _find = TextEditingController();
  late final FocusNode _findFocus = FocusNode(onKeyEvent: _findKeyEvent);
  bool _finding = false;
  final double _fontSize = 14;
  final _spanSize = TextEditingController(text: '16');
  int _matchIndex = -1;
  List<TextRange> _findMatches = const [];
  int _generation = 0;
  String _observedTitle = '', _observedBody = '';

  /// Stable note IDs selected in the active, unlocked vault.
  final Set<String> _selection = {};
  String? _selectionAnchor;
  /// How long a press must last before a sidebar row becomes a drag on
  /// desktop. Non-zero so a hand-jittered click still reaches the row's tap
  /// handler; short enough to stay invisible during a deliberate drag.
  static const _desktopDragHold = Duration(milliseconds: 150);

  bool _selecting = false;
  final Set<String> _collapsedFolders = {};

  /// Paths the user has expanded in the compact tree.  Empty means every
  /// folder and the root are collapsed, so the initial compact view shows
  /// only the folder rows and the root row — no notes until the user taps.
  final Set<String> _compactExpanded = {};
  bool _compactRootExpanded = false;

  /// When true in compact mode the entire sidebar is hidden and only a narrow
  /// restore strip remains; the editor expands into the freed width.
  bool _sidebarCollapsed = false;

  /// Real measured height of the search field rendered by `_searchField(false)`.
  /// Used as `minExtent`/`maxExtent` of the sticky `SliverPersistentHeader`.
  /// Starts at a reasonable fallback and is updated on the first layout.
  double _searchFieldExtent = 58;
  final GlobalKey _searchFieldMeasureKey = GlobalKey();

  /// Stable per-folder [GlobalKey]s backing `_folderDropTarget`'s row box.
  /// Recreating a `GlobalKey` on every build used to reparent the wrapped row
  /// whenever focus moved (e.g. the editor released keyboard focus on pointer
  /// down), which disposed the row's in-flight tap and swallowed the first
  /// click on a folder. Reusing one key per folder path keeps the element
  /// stable across rebuilds while preserving identical drag hit-testing.
  final Map<String, GlobalKey> _folderRowKeys = {};

  late final Notebook repo = ref.read(notebookProvider);
  Vault? get vault => repo.vaults.where((v) => v.id == _vaultId).firstOrNull;
  bool get unlocked => repo.unlocked.containsKey(_vaultId);
  List<Note> get filtered {
    final q = _query.trim().toLowerCase();
    final result =
        (_inHidden
                ? (_hiddenAvailable ? _hiddenNotes.values : <Note>[])
                : (repo.notes[_vaultId]?.values ?? <Note>[]))
            .where(
              (n) =>
                  (_filter == 'Kosz' ? n.deleted : !n.deleted) &&
                  (_filter != 'Ulubione' || n.favorite) &&
                  (_filter != 'Dziennik' || n.journalDate != null) &&
                  (_folder == null ||
                      n.folder == _folder ||
                      n.folder.startsWith('$_folder/')) &&
                  (q.isEmpty ||
                      '${n.title}\n${n.body}\n${n.folder}\n${n.tags.map((tag) => '#$tag').join(' ')}'
                          .toLowerCase()
                          .contains(q)),
            )
            .toList();
    result.sort((a, b) {
      if (a.favorite != b.favorite) return a.favorite ? -1 : 1;
      final comparison = switch (_sort) {
        'title' => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        'created-asc' => a.createdAt.compareTo(b.createdAt),
        'created-desc' => b.createdAt.compareTo(a.createdAt),
        _ => b.updatedAt.compareTo(a.updatedAt),
      };
      return comparison != 0 ? comparison : a.id.compareTo(b.id);
    });
    return result;
  }

  String _filterLabel(String id) => switch (id) {
    'Wszystkie' => tr('Wszystkie', 'All'),
    'Ostatnie' => tr('Ostatnie', 'Recent'),
    'Ulubione' => tr('Ulubione', 'Favorites'),
    'Dziennik' => tr('Dziennik', 'Journal'),
    'Ukryte' => tr('Ukryte', 'Hidden'),
    _ => id,
  };

  String get _statusLabel => switch (_status) {
    'Lokalnie' => tr('Lokalnie', 'Local'),
    'Zaszyfrowane • ukryte' => tr(
      'Zaszyfrowane • ukryte',
      'Encrypted • hidden',
    ),
    'Błąd zapisu' => tr('Błąd zapisu', 'Save error'),
    'Zapisano lokalnie' => tr('Zapisano lokalnie', 'Saved locally'),
    'Zapisano lokalnie • oczekuje na synchronizację' => tr(
      'Zapisano lokalnie • oczekuje na synchronizację',
      'Saved locally • waiting to sync',
    ),
    'Zsynchronizowano • E2EE' => tr('Zsynchronizowano • E2EE', 'Synced • E2EE'),
    'Offline • zmiany zachowane lokalnie' => tr(
      'Offline • zmiany zachowane lokalnie',
      'Offline • changes saved locally',
    ),
    'Ukryte notatki są poza widokiem.' => tr(
      'Ukryte notatki są poza widokiem.',
      'Hidden notes are out of view.',
    ),
    'Ukryte notatki są zablokowane.' => tr(
      'Ukryte notatki są zablokowane.',
      'Hidden notes are locked.',
    ),
    'Vault usunięty • kończenie porządkowania' => tr(
      'Vault usunięty • kończenie porządkowania',
      'Vault deleted • finishing cleanup',
    ),
    _ => _status,
  };

  /// Every folder known to the active vault, sorted for pickers.
  List<String> get _allFolderPaths =>
      repo.allFolders(_vaultId ?? '').toList()..sort();

  /// Visible folder rows after applying collapsed subtrees.
  List<FolderEntry> get _folderRows =>
      repo.folderRowsOf(_vaultId ?? '', collapsed: _collapsedFolders);

  /// Folder rows for the compact tree.  Every unseen folder starts collapsed,
  /// so `_compactExpanded` tracks explicit expansions.
  List<FolderEntry> _compactFolderRows() {
    final all = repo.allFolders(_vaultId ?? '').toSet();
    return repo.folderRowsOf(
      _vaultId ?? '',
      collapsed: all.difference(_compactExpanded),
    );
  }

  /// Whether the active vault prefers the compact sidebar presentation.
  bool get _compactMode => repo.compactModeOf(_vaultId ?? '');

  /// Compact mode merges the folder list and the notes list into one
  /// hierarchical tree for the ordinary folder+notes view.
  bool get _compactTree =>
      _compactMode && _filter == 'Wszystkie' && _folder == null && !_inHidden;

  /// Any compact-mode state (tree or a special filter) where the sidebar owns
  /// the note list in a single 300 px column and there is no separate notes
  /// panel. Folder filters (`_folder != null`) still use the classic layout.
  bool get _compactLayout => _compactMode && _folder == null;

  /// Compact mode with a special filter (trash / recent / favorites / hidden)
  /// active: the folder tree is replaced by a flat note list plus a back row.
  bool get _compactFiltered =>
      _compactMode && _filter != 'Wszystkie' && _folder == null;

  /// Notes behind the current selection, resolved by stable ID.
  List<Note> get _selectionNotes =>
      filtered.where((note) => _selection.contains(note.id)).toList();

  bool get _hasSelection => _selection.isNotEmpty;

  void _clearSelection() {
    _selection.clear();
    _selectionAnchor = null;
    _selecting = false;
  }

  /// Drops IDs that are no longer visible in the active filter.
  ///
  /// Called after every filter, vault or data change, so a hidden or deleted
  /// note can never be acted on by a stale bulk action.
  void _pruneSelection({bool keepMode = false}) {
    final visible = {for (final note in filtered) note.id};
    _selection.removeWhere((id) => !visible.contains(id));
    if (_selectionAnchor != null && !_selection.contains(_selectionAnchor)) {
      _selectionAnchor = null;
    }
    if (_selection.isEmpty && !keepMode) _selecting = false;
  }

  void _toggleSelected(Note note) {
    setState(() {
      _selecting = true;
      if (!_selection.remove(note.id)) {
        _selection.add(note.id);
        _selectionAnchor = note.id;
      } else if (_selectionAnchor == note.id) {
        _selectionAnchor = _selection.isEmpty ? null : _selection.first;
      }
    });
  }

  /// Selects the visible range between the anchor and [note] (Shift+click).
  void _extendSelectionTo(Note note) {
    final list = filtered;
    final anchor = _selectionAnchor;
    var from = anchor == null ? -1 : list.indexWhere((n) => n.id == anchor);
    var to = list.indexWhere((n) => n.id == note.id);
    if (to < 0) return;
    if (from < 0) from = to;
    if (from > to) (from, to) = (to, from);
    setState(() {
      _selecting = true;
      for (final candidate in list.sublist(from, to + 1)) {
        _selection.add(candidate.id);
      }
      _selectionAnchor ??= note.id;
    });
  }

  /// Routes a tap on a note card: modifier clicks select, plain clicks open.
  void _handleNoteTap(Note note) {
    if (_inHidden) {
      if (_hiddenAvailable) unawaited(_select(note));
      return;
    }
    final keys = HardwareKeyboard.instance;
    final additive = keys.isControlPressed || keys.isMetaPressed;
    if (keys.isShiftPressed) {
      _extendSelectionTo(note);
      return;
    }
    if (additive || _selecting) {
      _toggleSelected(note);
      return;
    }
    // Remember the opened note so a following Shift+click selects the range from
    // it, not only the clicked note.
    _selectionAnchor = note.id;
    unawaited(_select(note));
  }

  /// Refreshes the open note from storage after a bulk action touched it.
  void _refreshSelected() {
    final selected = _selected;
    if (selected == null) return;
    final current = repo.notes[_vaultId]?[selected.id];
    if (current == null) {
      _dropTab(selected.id);
      return;
    }
    _selected = current;
  }

  /// Moves notes to [folder] after flushing the editor and prunes the selection.
  Future<void> _moveNotesTo(
    Iterable<Note> notes,
    String folder,
  ) => _run(() async {
    final list = notes.toList();
    if (list.isEmpty) return;
    await _flush();
    final moved = await repo.moveNotes(list, folder);
    if (!mounted) return;
    setState(() {
      _pruneSelection();
      _refreshSelected();
    });
    _notify(
      moved == 0
          ? tr(
              'Notatki są już w tym folderze.',
              'The notes are already in this folder.',
            )
          : tr(
              'Przeniesiono $moved ${_plural(moved, 'notatkę', 'notatki', 'notatek')}.',
              'Moved $moved ${moved == 1 ? 'note' : 'notes'}.',
            ),
    );
  }, onError: (error) => _notify('$error'));

  static String _plural(int count, String one, String few, String many) {
    if (count == 1) return one;
    final mod10 = count % 10, mod100 = count % 100;
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return few;
    return many;
  }

  Future<void> _bulkMove() async {
    if (_selection.isEmpty || !mounted) return;
    final target = await chooseTargetFolder(
      context,
      folders: _allFolderPaths,
      initial: '',
      folderColors: repo.folderColorsOf(_vaultId ?? ''),
    );
    if (target == null) return;
    await _moveNotesTo(_selectionNotes, target);
  }

  Future<void> _bulkFavorite() => _run(() async {
    final notes = _selectionNotes;
    if (notes.isEmpty) return;
    await _flush();
    final value = notes.any((note) => !note.favorite);
    final changed = await repo.setFavoriteAll(notes, value);
    if (!mounted) return;
    setState(() {
      _pruneSelection();
      _refreshSelected();
    });
    _notify(
      value
          ? tr(
              'Przypięto $changed ${_plural(changed, 'notatkę', 'notatki', 'notatek')}.',
              'Pinned $changed ${changed == 1 ? 'note' : 'notes'}.',
            )
          : tr(
              'Odpięto $changed ${_plural(changed, 'notatkę', 'notatki', 'notatek')}.',
              'Unpinned $changed ${changed == 1 ? 'note' : 'notes'}.',
            ),
    );
  }, onError: (error) => _notify('$error'));

  Future<void> _bulkTrash({required bool restore}) => _run(() async {
    final notes = _selectionNotes;
    if (notes.isEmpty) return;
    await _flush();
    final changed = await repo.setDeletedAll(notes, !restore);
    if (!mounted) return;
    setState(() {
      if (!restore) {
        // Trashing any open note must also close its tab, so a tab never keeps
        // a note that is now in the trash.
        for (final note in notes) {
          _dropTab(note.id);
        }
      }
      _pruneSelection();
      _mobileEditor = false;
    });
    _notify(
      restore
          ? tr(
              'Przywrócono $changed ${_plural(changed, 'notatkę', 'notatki', 'notatek')}.',
              'Restored $changed ${changed == 1 ? 'note' : 'notes'}.',
            )
          : tr(
              'Przeniesiono do kosza $changed ${_plural(changed, 'notatkę', 'notatki', 'notatek')}.',
              'Moved $changed ${changed == 1 ? 'note' : 'notes'} to trash.',
            ),
    );
  }, onError: (error) => _notify('$error'));

  Future<void> _bulkPurge() async {
    final notes = _selectionNotes;
    if (notes.isEmpty || !mounted) return;
    if (!await confirmAction(
      context,
      () => tr(
        'Usunąć bezpowrotnie ${notes.length} ${_plural(notes.length, 'notatkę', 'notatki', 'notatek')}?',
        'Permanently delete ${notes.length} ${notes.length == 1 ? 'note' : 'notes'}?',
      ),
      () => tr(
        'Tej operacji nie można cofnąć. Notatki znikną również z innych urządzeń.',
        'This cannot be undone. The notes will also be removed from other devices.',
      ),
    )) {
      return;
    }
    await _run(() async {
      await _flush();
      var purged = 0;
      for (final note in notes) {
        await repo.purgeNote(note);
        purged++;
      }
      if (!mounted) return;
      setState(() {
        for (final note in notes) {
          _dropTab(note.id);
        }
        _clearSelection();
        _mobileEditor = false;
      });
      _notify(
        tr(
          'Usunięto $purged ${_plural(purged, 'notatkę', 'notatki', 'notatek')}.',
          'Deleted $purged ${purged == 1 ? 'note' : 'notes'}.',
        ),
      );
    }, onError: (error) => _notify('$error'));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_globalShortcuts);
    NativeWindow.instance.beforeClose = () async {
      if (_windowsUpdateBlocked) {
        throw StateError(
          tr(
            'Trwa przygotowanie aktualizacji.',
            'An update is being prepared.',
          ),
        );
      }
      await _prepareClose();
    };
    _updates.prepareWindowsInstall = _prepareWindowsUpdate;
    _updates.addListener(_updateChanged);
    unawaited(_updates.initialize());
    _title.addListener(_changed);
    _editor.addListener(_changed);
    // Focus leaving the document field must hide the floating wiki panel even
    // when no controller change schedules a rebuild.
    FocusManager.instance.addListener(_wikiFocusChanged);
    _search.addListener(() {
      if (mounted) {
        setState(() {
          _query = _search.text;
          _pruneSelection(keepMode: true);
        });
      }
    });
    if (repo.vaults.isNotEmpty) {
      _vaultId = repo.lastVaultId;
      final first = filtered.firstOrNull;
      if (first != null) _load(first);
    }
    _syncCoordinator = SyncCoordinator(
      api: () => repo.api,
      synchronize: () async => _busy ? false : await _sync(quiet: true),
    );
    _localChanges = repo.localChanges.listen(
      (_) => _syncCoordinator.localChanged(),
    );
    _syncCoordinator.start();
    _hiddenChanges = repo.hiddenStateChanges.listen((_) {
      // The deletion stream independently wipes ordinary selected editors.
      if (_inHidden && !_hiddenAvailable) _forgetHidden();
    });
    _vaultDeletions = repo.vaultDeletions.listen(_vaultDeleted);
    _startAndroidWidgets();
    // Also enforce wall-clock expiry when queued storage work delays locking.
    _hiddenWatch = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_inHidden &&
          !_hiddenAvailable &&
          (_hiddenNotes.isNotEmpty || _selected != null)) {
        _forgetHidden();
        unawaited(repo.lockHidden());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncCoordinator.start();
    } else {
      _syncCoordinator.stop();
      if (repo.hiddenLockOnBackground) {
        if (_inHidden) {
          // Wipe before the first await, including app-switcher snapshots.
          unawaited(_lockHiddenFolder());
        } else if (repo.hiddenUnlocked) {
          // A timed unlock can survive navigation; revoke it before an ordinary
          // editor save has a chance to delay the background lock.
          unawaited(repo.lockHidden());
        }
      }
      unawaited(_flush().catchError((Object error) {}));
      if (state == AppLifecycleState.hidden ||
          state == AppLifecycleState.paused) {
        unawaited(_lockProtected().catchError((Object error) {}));
      }
    }
  }

  Future<void> _lockProtected() async {
    try {
      await _flush();
    } finally {
      if (repo.hiddenUnlocked && repo.hiddenLockOnBackground) {
        await repo.lockHidden();
      }
    }
    for (final v in repo.vaults.where((v) => v.protected)) {
      repo.lock(v.id);
    }
    if (mounted) {
      setState(() {
        if (vault?.protected == true) _clearEditor();
      });
    }
  }

  /// Opens the in-note search from anywhere, including inside the live editor.
  ///
  /// The editor's focus node only handles its own editing keys, but a focused
  /// text field otherwise keeps Cmd/Ctrl+F away from [CallbackShortcuts]. This
  /// handler runs before focus dispatch, so the shortcut works from the note
  /// list, the live editor and the source editor alike.
  Future<void> _prepareClose() async {
    await _flush();
    if (_inHidden) await _lockHiddenFolder();
    if (repo.hiddenUnlocked) await repo.lockHidden();
    final storage = repo.storage;
    if (storage is NativeStorage) storage.checkpointJournal(truncate: false);
  }

  Future<WindowsUpdateHandoff> _prepareWindowsUpdate() async {
    if (!mounted || _busy || _windowsUpdateBlocked) {
      throw StateError(
        tr(
          'Poczekaj na zakończenie operacji.',
          'Please wait for the operation to finish.',
        ),
      );
    }
    return PreparedWindowsUpdate.prepare(
      notebook: repo,
      // Notebook fences/drains background work before admitting this final
      // editor flush, then revokes hidden keys and verifies its checkpoint.
      beforeClose: _flush,
      close: NativeWindow.finishPreparedUpdate,
      blockInput: (blocked) {
        if (!blocked) _removeWindowsUpdateBarrier();
        if (!mounted) return;
        setState(() => _windowsUpdateBlocked = blocked);
        if (blocked) {
          FocusScope.of(context).unfocus();
          final barrier = DialogRoute<void>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) {
              Localizations.localeOf(ctx);
              return AnimatedBuilder(
                animation: _updates,
                builder: (ctx, _) {
                  Localizations.localeOf(ctx);
                  return PopScope(
                    canPop: false,
                    child: AlertDialog(
                      content: Text(
                        _updates.message ??
                            tr(
                              'Przygotowywanie aktualizacji. Poczekaj na okno instalatora lub potwierdzenie UAC.',
                              'Preparing the update. Wait for the installer window or UAC confirmation.',
                            ),
                      ),
                      actions: [
                        if (_updates.stage == UpdateStage.closeRequired)
                          FilledButton(
                            key: const Key('retry-update-close'),
                            onPressed: _updates.retryWindowsClose,
                            child: Text(
                              tr(
                                'Ponów zamknięcie Silique',
                                'Retry closing Silique',
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              );
            },
          );
          _windowsUpdateBarrier = barrier;
          unawaited(Navigator.of(context, rootNavigator: true).push(barrier));
        }
      },
    );
  }

  void _removeWindowsUpdateBarrier({bool afterFrame = false}) {
    final barrier = _windowsUpdateBarrier;
    _windowsUpdateBarrier = null;
    if (barrier == null) return;
    void remove() {
      if (barrier.isActive) barrier.navigator!.removeRoute(barrier);
    }

    // Home may be disposed during a Navigator rebuild; its history is locked
    // until the frame completes. Capture only the route, not this State.
    if (afterFrame) {
      WidgetsBinding.instance.addPostFrameCallback((_) => remove());
    } else {
      remove();
    }
  }

  bool _globalShortcuts(KeyEvent event) {
    if (_windowsUpdateBlocked) return true;
    if (event is! KeyDownEvent) return false;
    if (_hiddenAvailable &&
        mounted &&
        (ModalRoute.of(context)?.isCurrent ?? true)) {
      repo.hiddenActivity();
    }
    // AltGr may arrive as Ctrl+Alt, or as the distinct AltGraph key. Neither
    // is an app command: let the OS text-input path deliver layout characters.
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed ||
        keyboard.isLogicalKeyPressed(LogicalKeyboardKey.altGraph)) {
      return false;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyN &&
        (HardwareKeyboard.instance.isMetaPressed ||
            HardwareKeyboard.instance.isControlPressed) &&
        mounted &&
        (ModalRoute.of(context)?.isCurrent ?? true)) {
      unawaited(_newNote());
      return true;
    }
    if (event.logicalKey != LogicalKeyboardKey.keyF) return false;
    if (!keyboard.isMetaPressed && !keyboard.isControlPressed) return false;
    if (!mounted ||
        _selected == null ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return false;
    }
    if (_busy) return false;
    _showFind();
    return true;
  }

  @override
  void dispose() {
    _removeWindowsUpdateBarrier(afterFrame: true);
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_globalShortcuts);
    FocusManager.instance.removeListener(_wikiFocusChanged);
    NativeWindow.instance.beforeClose = null;
    _updates.removeListener(_updateChanged);
    _updates.dispose();
    _autosave?.cancel();
    unawaited(_widgetActions?.cancel());
    unawaited(_androidWidgets.dispose());
    _hiddenWatch?.cancel();
    unawaited(_hiddenChanges?.cancel());
    _evictEditorImages();
    if (_inHidden) {
      _loading = true;
      _title.clear();
      _editor.wipe();
      _raw?.clear();
      _find.clear();
      _search.clear();
      _hiddenNotes.clear();
      unawaited(repo.lockHidden());
    }
    _syncCoordinator.stop();
    unawaited(_localChanges?.cancel());
    unawaited(_vaultDeletions?.cancel());
    _editor.removeListener(_changed);
    _editor.dispose();
    _title.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _sourceFocus.dispose();
    _titleFocus.dispose();

    _find.dispose();
    _findFocus.dispose();
    _spanSize.dispose();
    _raw?.dispose();
    super.dispose();
  }

  void _updateChanged() {
    if (!mounted ||
        !_updates.available ||
        _announcedUpdate == _updates.release!.build) {
      return;
    }
    _announcedUpdate = _updates.release!.build;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          tr(
            'Dostępna jest aktualizacja Silique ${_updates.release!.version}.',
            'Silique ${_updates.release!.version} is available.',
          ),
        ),
        action: SnackBarAction(
          label: tr('Zobacz', 'View'),
          onPressed: () => _settings(openUpdates: true),
        ),
      ),
    );
  }

  void _notify(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));
    }
  }

  Future<void> _run(
    Future<void> Function() fn, {
    void Function(Object error)? onError,
  }) async {
    if (_busy || _windowsUpdateBlocked) return;
    setState(() => _busy = true);
    try {
      await fn();
    } catch (e) {
      if (onError != null) {
        onError(e);
      } else {
        _notify('$e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _returnToList() => _run(() async {
    await _flush();
    if (mounted) {
      FocusScope.of(context).unfocus();
      setState(() => _mobileEditor = false);
    }
  });

  void _changed() {
    if (_loading || _selected == null) return;
    if (_windowsUpdateBlocked ||
        _revealingHidden ||
        repo.vaultDeletionPending(_selected!.vaultId)) {
      // Reject stale IME/controller/formatting callbacks during the move, not
      // just their persistence. The already submitted edits still drain below.
      _loading = true;
      _title.text = _observedTitle;
      if (_editor.text != _observedBody) _editor.text = _observedBody;
      if (_raw?.text != _observedBody) _raw?.text = _observedBody;
      _loading = false;
      return;
    }
    if (_selected!.hidden != _inHidden) return;
    if (_inHidden && !_hiddenAvailable) {
      _forgetHidden();
      return;
    }
    if (mounted) setState(() {});
    _scheduleWikiAnchorUpdate();
    if (_title.text == _observedTitle && _editor.text == _observedBody) {
      if (_finding && _find.text.isNotEmpty) _refreshFind();
      return;
    }
    _observedTitle = _title.text;
    _observedBody = _editor.text;
    _generation++;
    _dirty = true;
    _autosave?.cancel();

    if (_inHidden) {
      repo.hiddenActivity();
      final note = _selected!.copyWith(
        title: _title.text,
        body: _editor.text,
        hidden: true,
      );
      _selected = note;
      _hiddenNotes[note.id] = note;
      _dirty = false;
      final epoch = _hiddenEpoch;
      // Submit immediately: Notebook captures the key before any lock request.
      _hiddenPending = repo
          .save(note)
          .then(
            (_) {
              if (!mounted || epoch != _hiddenEpoch) return;
              setState(() {
                _hiddenSaveError = null;
                _status = 'Zaszyfrowane • ukryte';
              });
            },
            onError: (Object error) {
              if (!mounted) return;
              if (epoch == _hiddenEpoch) {
                setState(() {
                  _hiddenSaveError = error;
                  _status = 'Błąd zapisu';
                });
              }
              _notify(
                tr(
                  'Nie udało się zapisać ukrytej notatki.',
                  'Could not save the hidden note.',
                ),
              );
            },
          );
      if (_finding && _find.text.isNotEmpty) _refreshFind();
      return;
    }

    _autosave = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(_flush().catchError((Object error) {})),
    );
    if (_finding && _find.text.isNotEmpty) _refreshFind();
  }

  Future<void>? _saving;
  Future<void> _flush() async {
    if (_inHidden) {
      await _hiddenPending;
      if (_hiddenSaveError != null) {
        throw StateError(
          tr(
            'Nie udało się zapisać ukrytej notatki.',
            'Could not save the hidden note.',
          ),
        );
      }
      return;
    }
    final pending = _saving;
    if (pending != null) {
      await pending;
      if (_dirty) await _flush();
      return;
    }
    final operation = _flushNow();
    _saving = operation;
    try {
      await operation;
    } finally {
      _saving = null;
    }
    // An update/quit may arrive while the editor is still changing. Drain the
    // next generation too before letting the native installer replace the app.
    if (mounted && _dirty && _selected != null) await _flush();
  }

  Future<void> _flushNow() async {
    _autosave?.cancel();
    if (!_dirty || _selected == null) return;
    final version = _generation;
    // Merge into the stored note, not into the snapshot captured when the editor
    // was opened: bulk actions may have changed the folder or pin state since.
    final current =
        repo.notes[_selected!.vaultId]?[_selected!.id] ?? _selected!;
    final note = current.copyWith(title: _title.text, body: _editor.text);
    try {
      await repo.save(note);
      if (mounted) {
        setState(() {
          if (_selected?.id == note.id && version == _generation) {
            _selected = note;
            _dirty = false;
          }
          _status = repo.session == null || vault?.syncEnabled != true
              ? 'Zapisano lokalnie'
              : 'Zapisano lokalnie • oczekuje na synchronizację';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Błąd zapisu');
      _notify(tr('Nie udało się zapisać: $e', 'Could not save: $e'));
      rethrow;
    }
  }

  void _clearEditor() {
    _evictEditorImages();
    _loading = true;
    _autosave?.cancel();
    // Clear even a former ordinary note: a completed hide has already removed
    // its ordinary row, but the selected snapshot still has hidden == false.
    _editor.wipe();
    _raw?.clear();
    _selected = null;
    _title.clear();
    _wikiCaret = null;
    _wikiAnchorValue = null;
    final previous = _editor;
    previous.removeListener(_changed);
    _editor = LiveMarkdownController()..addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      previous.dispose();
    });
    final raw = _raw;
    _raw = null;
    WidgetsBinding.instance.addPostFrameCallback((_) => raw?.dispose());
    _observedTitle = _title.text;
    _observedBody = _editor.text;
    _loading = false;
    _dirty = false;
  }

  /// Records [id] as the most recently used tab, deduplicating and capping the
  /// history to the set of currently open tabs.
  void _touchTab(String id) {
    _tabOrder.remove(id);
    _tabOrder.insert(0, id);
    if (_tabOrder.length > _tabs.length) {
      _tabOrder.removeRange(_tabs.length, _tabOrder.length);
    }
  }

  /// Clears both the open-tab list and its usage history. Called everywhere the
  /// tab set is discarded (vault switch, hidden notes, vault deletion).
  void _clearTabs() {
    _tabs.clear();
    _tabOrder.clear();
  }

  void _load(Note note) {
    if (note.hidden != _inHidden || (note.hidden && !_hiddenAvailable)) return;
    _loading = true;
    if (_selected?.hidden == true) {
      _evictEditorImages();
      _editor.wipe();
      _raw?.clear();
      final raw = _raw;
      _raw = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => raw?.dispose());
    }
    _selected = note;
    if (_tabs.contains(note.id)) {
      // Re-selecting an already-open note records it as most recently used, so
      // closing the current tab can fall back to the last one the user touched.
      // A freshly opened tab carries no history yet: in a fresh session the
      // close rule degrades to the positional neighbor.
      _touchTab(note.id);
    } else {
      _tabs.add(note.id);
    }
    _title.text = note.title;
    _wikiCaret = null;
    _wikiAnchorValue = null;
    final previous = _editor;
    previous.removeListener(_changed);
    _editor = LiveMarkdownController(
      text: note.body,
      selection: TextSelection.collapsed(offset: note.body.length),
    )..addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      previous.dispose();
    });
    _observedTitle = _title.text;
    _observedBody = _editor.text;
    _loading = false;
    _dirty = false;
    if (_finding || _find.text.isNotEmpty) _closeFind();
  }

  Future<void> _select(Note note) async {
    await _flush();
    if (mounted &&
        note.hidden == _inHidden &&
        (!note.hidden ||
            _hiddenAvailable && _hiddenNotes.containsKey(note.id))) {
      if (note.hidden) repo.hiddenActivity();
      setState(() {
        _load(note);
        _mobileEditor = true;
      });
    }
  }

  Future<void> _switch(String id) async {
    if (repo.vaultDeletionPending(id)) {
      _notify(
        tr(
          'Ten vault oczekuje na dokończenie usuwania.',
          'Deletion of this vault is pending.',
        ),
      );
      return;
    }
    if (_inHidden) await _leaveHiddenFolder();
    await _flush();
    await repo.rememberVault(id);
    if (mounted) {
      setState(() {
        _vaultId = id;
        _clearTabs();
        _status = 'Lokalnie';
        _folder = null;
        _filter = 'Wszystkie';
        _search.clear();
        _clearSelection();
        _collapsedFolders.clear();
        _closeFind();
        _clearEditor();
        final first = filtered.firstOrNull;
        if (first != null) _load(first);
        _mobileEditor = false;
      });
    }
  }

  Future<void> _newNote({bool journal = false}) => _run(() async {
    if (_inHidden && journal) {
      await _leaveHiddenFolder();
      if (mounted) setState(() => _filter = 'Wszystkie');
    }
    if (vault == null) {
      await _createVault();
      return;
    }
    if (!unlocked) {
      await _unlock();
      return;
    }
    await _flush();
    final today = DateTime.now();
    if (_inHidden) {
      if (!_hiddenAvailable) {
        if (!await _ensureHiddenUnlocked() || !mounted) return;
        await _readHidden();
      }
      final epoch = _hiddenEpoch;
      final note = await repo.createHiddenNote(_vaultId!);
      if (!mounted || !_hiddenAvailable || epoch != _hiddenEpoch) return;
      setState(() {
        _search.clear();
        _hiddenNotes[note.id] = note;
        _load(note);
        _mobileEditor = true;
      });
      return;
    }
    final date =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final note = await repo.createNote(
      _vaultId!,
      journalDate: journal ? date : null,
      folder: _folder ?? '',
    );
    if (mounted) {
      setState(() {
        _filter = journal ? 'Dziennik' : 'Wszystkie';
        _folder = null;
        _load(note);
        _mobileEditor = true;
      });
    }
  });
  Future<void> _createVault() async {
    final config = await askVault(context);
    if (config == null) return;
    final key = await repo.createVault(config.name, password: config.password);
    final created = repo.vaults.last;
    await _switch(created.id);
    if (key != null && mounted) await showRecovery(context, key, vault: true);
  }

  Future<void> _unlock({bool recovery = false}) async {
    if (vault == null) return;
    final pass = await askText(
      context,
      '',
      titleBuilder: () => recovery
          ? tr('Klucz odzyskiwania vaulta', 'Vault recovery key')
          : tr('Odblokuj vault', 'Unlock vault'),
      secret: true,
      hintBuilder: () => recovery
          ? tr('Klucz odzyskiwania', 'Recovery key')
          : tr('Hasło vaulta', 'Vault password'),
    );
    if (pass == null) return;
    await repo.unlock(vault!, password: pass, recovery: recovery);
    if (mounted) {
      setState(() {
        final first = filtered.firstOrNull;
        if (first != null) _load(first);
      });
    }
  }

  Future<bool> _sync({bool quiet = false}) async {
    if (_syncing) return false;
    if (repo.session == null) return true;
    if (mounted) setState(() => _syncing = true);
    try {
      await _flush();
      final version = _generation;
      await repo.sync();
      if (mounted) {
        setState(() {
          _status = vault?.syncEnabled == true
              ? 'Zsynchronizowano • E2EE'
              : 'Zapisano lokalnie';
          if (_vaultId == null && repo.vaults.isNotEmpty) {
            _vaultId = repo.lastVaultId;
          }
          if (!_inHidden &&
              version == _generation &&
              !_dirty &&
              _selected != null) {
            final current = repo.notes[_vaultId]?[_selected!.id];
            if (current == null) {
              _dropTab(_selected!.id);
            }
            if (current != null && !current.deleted) {
              if (current.body != _editor.text ||
                  current.title != _title.text) {
                _load(current);
              } else {
                _selected = current;
              }
            }
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = 'Offline • zmiany zachowane lokalnie');
      }
      if (!quiet) _notify('$e');
      return false;
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
    return true;
  }

  Future<void> _settings({bool openUpdates = false}) async {
    if (_inHidden) await _filterBy('Wszystkie');
    await _flush();
    if (!mounted) return;
    final moveStorage = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        Localizations.localeOf(ctx);
        return Dialog(
          insetPadding: const EdgeInsets.all(16),
          child: SettingsPanel(
            notebook: repo,
            vault: vault,
            updater: _updates,
            beforeUpdate: _flush,
            openUpdates: openUpdates,
            onMoveStorage: canMoveStorage
                ? () => Navigator.pop(ctx, true)
                : null,
            onChanged: () {
              if (!_inHidden &&
                  repo.hiddenAutoLock == null &&
                  repo.hiddenUnlocked) {
                // Settings can switch to section-exit locking after the section
                // was left with a timed unlock still active.
                unawaited(repo.lockHidden());
              }
              if (mounted) setState(() {});
            },
          ),
        );
      },
    );
    if (moveStorage == true && mounted) await _run(_moveStorage);
    if (mounted) {
      setState(() {
        if (_vaultId == null && repo.vaults.isNotEmpty) {
          _vaultId = repo.lastVaultId;
          final first = filtered.firstOrNull;
          if (first != null) _load(first);
        }
      });
    }
  }

  Future<void> _filterBy(String value, {String? folder}) async {
    if (_inHidden && value != 'Ukryte') {
      await _leaveHiddenFolder();
    } else {
      await _flush();
    }
    if (value == 'Ukryte') {
      await _openHidden();
      return;
    }
    if (mounted) {
      setState(() {
        if (value == 'Kosz' || _filter == 'Kosz' || _inHidden) _search.clear();
        _filter = value;
        _folder = folder;
        // Choosing a folder is an explicit request to see its notes, so it
        // restores the notes list even when the header toggle collapsed it.
        if (folder != null) _notesCollapsed = false;
        _clearSelection();
        _mobileEditor = false;
      });
    }
  }

  /// The extra password is created when the first note is hidden; later hides
  /// and reveals only unlock an existing one.
  Future<bool> _ensureHiddenUnlocked() async {
    if (!mounted) return false;
    if (repo.hiddenUnlocked) {
      repo.hiddenActivity();
      return true;
    }
    if (!repo.hiddenPasswordSet) {
      final created = await askHiddenPassword(context, create: true);
      if (created == null || !mounted) return false;
      await repo.setHiddenPassword(created);
      return repo.hiddenUnlocked;
    }
    final value = await askHiddenPassword(context, create: false);
    if (value == null || !mounted) return false;
    final ok = await repo.unlockHidden(value);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Nieprawidłowe hasło.', 'Incorrect password.')),
        ),
      );
    }
    return ok;
  }

  Future<void> _openHidden() => _run(() async {
    if (vault == null) return;
    if (!unlocked) {
      await _unlock();
      if (!unlocked) return;
    }
    if (!await _ensureHiddenUnlocked() || !mounted) return;
    setState(() {
      _clearEditor();
      _clearTabs();
      _closeFind();
      _search.clear();
      _clearSelection();
      _folder = null;
      _filter = 'Ukryte';
      _mobileEditor = false;
      _status = 'Zaszyfrowane • ukryte';
    });
    await _readHidden();
  });

  Future<void> _readHidden() async {
    final epoch = _hiddenEpoch, id = _vaultId!;
    final notes = await repo.hiddenNotes(id);
    if (!mounted ||
        !_hiddenAvailable ||
        epoch != _hiddenEpoch ||
        id != _vaultId) {
      return;
    }
    setState(() {
      _hiddenNotes
        ..clear()
        ..addEntries(notes.map((n) => MapEntry(n.id, n)));
    });
  }

  ImageProvider<Object> _trackEditorImage(ImageProvider<Object> image) {
    // Track ordinary images too: moving their note to hidden must revoke the
    // former ordinary cache keys, not only providers created after the move.
    _editorImages.add(image);
    return image;
  }

  void _evictEditorImages() {
    // These providers use themselves as synchronous cache keys. Evicting pending
    // entries detaches cache listeners, so late decodes cannot reinsert pixels.
    for (final image in _editorImages) {
      PaintingBinding.instance.imageCache.evict(image, includeLive: true);
    }
    _editorImages.clear();
  }

  void _forgetHidden() {
    if (!mounted) return;
    _hiddenEpoch++;
    _loading = true;
    _title.clear();
    _editor.wipe();
    _raw?.clear();
    _loading = false;
    FocusScope.of(context).unfocus();
    setState(() {
      _closeFind();
      _search.clear();
      _clearEditor();
      _hiddenNotes.clear();
      _clearTabs();
      _clearSelection();
      _hiddenSaveError = null;
      _mobileEditor = false;
      _focus = false;
      _droppingImage = false;
      _status = repo.hiddenUnlocked
          ? 'Ukryte notatki są poza widokiem.'
          : 'Ukryte notatki są zablokowane.';
    });
  }

  Future<void> _leaveHiddenFolder() async {
    if (!_inHidden) return;
    if (repo.hiddenAutoLock == null) {
      await _lockHiddenFolder();
    } else {
      await _flush();
      // Remove plaintext from the view while the key remains under the
      // configured inactivity and background policies.
      _forgetHidden();
    }
  }

  Future<void> _lockHiddenFolder() async {
    final pending = _hiddenPending;
    final failed = _hiddenSaveError != null;
    _forgetHidden();
    // Unavailable synchronously; key erasure queues behind captured-key saves.
    final locking = repo.lockHidden();
    await pending;
    await locking;
    if (failed) {
      _notify(
        tr(
          'Nie udało się zapisać zmian przed blokadą.',
          'Could not save changes before locking.',
        ),
      );
    }
  }

  Future<void> _revealHidden(Note note) async {
    if (!_hiddenAvailable || _revealingHidden) return;
    final folder = await chooseTargetFolder(
      context,
      folders: _allFolderPaths,
      initial: '',
      folderColors: repo.folderColorsOf(_vaultId ?? ''),
    );
    if (folder == null || !mounted || !_hiddenAvailable) return;
    setState(() => _revealingHidden = true);
    try {
      await _flush();
      if (!_hiddenAvailable) return;
      await repo.unhideNote(note.vaultId, note.id, folder: folder);
      await _filterBy('Wszystkie', folder: folder.isEmpty ? null : folder);
    } finally {
      if (mounted) setState(() => _revealingHidden = false);
    }
  }

  Future<void> _deleteHidden(Note note) async {
    if (!_hiddenAvailable ||
        !await confirmAction(
          context,
          () => tr('Usunąć ukrytą notatkę?', 'Delete the hidden note?'),
          () => tr(
            'Notatka zostanie usunięta bez możliwości przywrócenia.',
            'The note will be deleted permanently.',
          ),
        )) {
      return;
    }
    if (!mounted || !_hiddenAvailable) return;
    await _flush();
    if (!_hiddenAvailable) return;
    await repo.deleteHiddenNote(note.vaultId, note.id);
    if (!mounted) return;
    setState(() {
      _hiddenNotes.remove(note.id);
      final wasSelected = _selected?.id == note.id;
      _dropTab(note.id);
      if (wasSelected && _selected == null) _mobileEditor = false;
    });
  }

  Future<void> _hideNote(Note note) async {
    await _flush();
    if (!mounted) return;
    if (!await confirmAction(
      context,
      () => tr('Przenieść do ukrytych?', 'Move to hidden notes?'),
      () => tr(
        'Ukryte notatki są dodatkowo szyfrowane osobnym hasłem — trafiają do serwera tylko w tej zaszyfrowanej kopercie. '
            'Dla notatki synchronizowanej wymaga to połączenia z serwerem i usunie zwykłą kopię oraz jej historię ze wszystkich urządzeń po ich synchronizacji. '
            'Wcześniejsze eksporty i kopie zapasowe nie zostaną zmienione.',
        'Hidden notes are additionally encrypted with a separate password and reach the server only inside this encrypted envelope. '
            'For synced notes, this requires a server connection and removes the ordinary copy and its history from all devices after they sync. '
            'Previous exports and backups will not be changed.',
      ),
    )) {
      return;
    }
    if (!await _ensureHiddenUnlocked() || !mounted) return;
    final current = repo.notes[note.vaultId]?[note.id] ?? note;
    try {
      await _androidWidgets.withoutSnapshot(() => repo.hideNote(current));
    } finally {
      // Ambiguous remote failures preserve a private recovery copy. Never keep
      // its old ordinary editor/controller open after the local move committed.
      if (mounted &&
          repo.storage
              .documents('hidden:${note.vaultId}')
              .containsKey(note.id)) {
        setState(() {
          final wasSelected = _selected?.id == note.id;
          _dropTab(note.id);
          if (wasSelected && _selected == null) _mobileEditor = false;
        });
      }
    }
    if (!mounted) return;
    _notify(
      tr(
        'Notatka ukryta. Otwórz sekcję Ukryte, aby ją edytować.',
        'Note hidden. Open Hidden to edit it.',
      ),
    );
  }

  Future<void> _favorite(Note note) async {
    await _flush();
    final current = repo.notes[note.vaultId]?[note.id] ?? note;
    final changed = current.copyWith(favorite: !current.favorite);
    await repo.save(changed);
    if (mounted) {
      setState(() {
        if (_selected?.id == note.id) _selected = changed;
      });
    }
  }

  Future<void> _trash() async {
    await _flush();
    if (_selected == null) return;
    final changed = _selected!.copyWith(deleted: !_selected!.deleted);
    await repo.save(changed);
    if (mounted) {
      setState(() {
        _clearEditor();
        _mobileEditor = false;
      });
    }
  }

  Future<void> _importVault() async {
    if (_inHidden) return;
    if (!unlocked || _vaultId == null) return;
    await _flush();
    if (!mounted) return;
    final result = await showDialog<VaultImportResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => VaultImportDialog(
        notebook: repo,
        vaultId: _vaultId!,
        initialFolder: _folder ?? '',
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _filter = 'Wszystkie';
      _folder = null;
      _search.clear();
      _clearSelection();
      _collapsedFolders.clear();
    });
    if (result.notes.isNotEmpty) await _select(result.notes.first);
    _notify(
      tr(
        'Zaimportowano ${result.notes.length} notatek, ${result.folderCount} folderów i ${result.imageCount} zdjęć.',
        'Imported ${result.notes.length} notes, ${result.folderCount} folders and ${result.imageCount} images.',
      ),
    );
  }

  Future<void> _folderDialog({String parent = ''}) async {
    if (_inHidden) return;
    if (!unlocked) return;
    final path = await askFolderName(
      context,
      parent: parent,
      existing: _allFolderPaths,
      titleBuilder: () => parent.isEmpty
          ? tr('Nowy folder', 'New folder')
          : tr('Nowy podfolder', 'New subfolder'),
    );
    if (path == null) return;
    await _run(() async {
      await _flush();
      await repo.createFolder(vault!, path);
      if (!mounted) return;
      setState(() {
        _collapsedFolders.removeWhere(
          (folder) => isSameOrDescendantPath(path, folder),
        );
        if (_compactTree) {
          // In the compact merged tree the new folder must appear without
          // switching the panel to a folder filter: expand it and its
          // ancestors instead of selecting the (still empty) folder.
          _compactExpanded
            ..add(path)
            ..addAll(folderAncestors(path));
        } else {
          _folder = path;
        }
        _filter = 'Wszystkie';
        _clearSelection();
      });
    }, onError: (error) => _notify('$error'));
  }

  void _format(String before, [String after = '']) {
    if (_revealingHidden) return;
    final range = _editor.selection;
    final start = range.isValid ? range.start : 0,
        end = range.isValid ? range.end : 0;
    final text = _editor.text.substring(start, end);
    _editor.replaceRange(
      start,
      end,
      '$before$text$after',
      selection: TextSelection(
        baseOffset: start + before.length,
        extentOffset: start + before.length + text.length,
      ),
    );
  }

  /// Picks the tab that should become selected after [id] closes. Prefers the
  /// most recently used still-open tab (usage history), then falls back to the
  /// positional neighbor: the tab to the right of [id], else the one to the
  /// left. Returns `null` when no tab remains. Must be called while [id] is
  /// still present in `_tabs`, so the positional neighbor is found correctly.
  String? _tabAfterClose(String id) {
    for (final recent in _tabOrder) {
      if (recent != id && _tabs.contains(recent)) return recent;
    }
    final index = _tabs.indexOf(id);
    for (var i = index + 1; i < _tabs.length; i++) {
      final tab = _tabs[i];
      if (tab != id && _noteById(tab) != null) return tab;
    }
    for (var i = index - 1; i >= 0; i--) {
      final tab = _tabs[i];
      if (tab != id && _noteById(tab) != null) return tab;
    }
    return null;
  }

  /// Removes [id] from the open-tab set and usage history, and — when it was
  /// the selected note — advances the selection using the shared close rule.
  /// Callers must already be inside `setState` (or trigger a rebuild after).
  void _dropTab(String id) {
    final wasSelected = _selected?.id == id;
    final next = wasSelected ? _tabAfterClose(id) : null;
    _tabs.remove(id);
    _tabOrder.remove(id);
    if (wasSelected) {
      _clearEditor();
      if (next != null) {
        final note = _noteById(next);
        if (note != null) _load(note);
      }
    }
  }

  Future<void> _closeTab(String id) async {
    await _flush();
    if (!mounted) return;
    setState(() => _dropTab(id));
  }

  /// Keyboard handling for the find field.
  ///
  /// The field's focus node sees Enter before the text input connection, so
  /// Enter/Shift+Enter/arrows cycle through the matches while the caret stays in
  /// the field and the document is never edited.
  KeyEventResult _findKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _findNext(back: HardwareKeyboard.instance.isShiftPressed);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _findNext();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _findNext(back: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      setState(_closeFind);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _showFind() {
    if (_selected == null) return;
    setState(() => _finding = true);
    _refreshFind(selectFirst: true);
    _findFocus.requestFocus();
  }

  bool _applyingFind = false;

  /// Recomputes match ranges for the active note and repaints highlights.
  ///
  /// The match list is derived from the editor source only; it never changes
  /// the document, the undo history or the saved note. The caret stays in the
  /// find field unless [selectFirst] selects the first match.
  void _refreshFind({bool selectFirst = false}) {
    final query = _find.text;
    final matches = findMatchRanges(_editor.text, query);
    if (_matchIndex >= matches.length) _matchIndex = matches.length - 1;
    setState(() {
      _findMatches = matches;
      if (matches.isEmpty) {
        _matchIndex = -1;
      } else if (_matchIndex < 0) {
        _matchIndex = 0;
      }
    });
    _applyFindHighlights();
    if (selectFirst && matches.isNotEmpty) {
      _selectMatch(_matchIndex < 0 ? 0 : _matchIndex, keepFocus: false);
    }
  }

  void _applyFindHighlights() {
    if (_applyingFind) return;
    _applyingFind = true;
    try {
      final active = _matchIndex >= 0 && _matchIndex < _findMatches.length
          ? _matchIndex
          : -1;
      _editor.setAnnotations([
        for (var i = 0; i < _findMatches.length; i++)
          LiveMarkdownAnnotation(
            start: _findMatches[i].start,
            end: _findMatches[i].end,
            backgroundColor: i == active
                ? const Color(0x99ffb300)
                : const Color(0x55ffd54f),
          ),
      ]);
      _raw?.matches = (ranges: _findMatches, active: active);
    } finally {
      _applyingFind = false;
    }
  }

  void _selectMatch(int index, {bool keepFocus = true}) {
    if (index < 0 || index >= _findMatches.length) return;
    final match = _findMatches[index];
    setState(() => _matchIndex = index);
    _applyFindHighlights();
    final selection = TextSelection(
      baseOffset: match.start,
      extentOffset: match.end,
    );
    _editor.setSelection(selection);
    if (_source) {
      _sourceController().selection = selection;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        EditableTextState? state;
        void visit(Element element) {
          if (element is StatefulElement &&
              element.state is EditableTextState) {
            state = element.state as EditableTextState;
          }
          element.visitChildren(visit);
        }

        (_sourceViewport.currentContext as Element?)?.visitChildren(visit);
        state?.bringIntoView(TextPosition(offset: selection.start));
      });
    }
    if (keepFocus) _findFocus.requestFocus();
  }

  /// Cycles through matches; the last match wraps to the first one.
  void _findNext({bool back = false}) {
    if (_find.text.isEmpty) return;
    if (_findMatches.isEmpty) _refreshFind();
    if (_findMatches.isEmpty) return;
    final count = _findMatches.length;
    final current = _matchIndex;
    final next = current < 0
        ? (back ? count - 1 : 0)
        : back
        ? (current - 1 + count) % count
        : (current + 1) % count;
    _selectMatch(next);
  }

  /// Closes the find bar and removes every highlight.
  void _closeFind() {
    _find.text = '';
    _findMatches = const [];
    _matchIndex = -1;
    _finding = false;
    _editor.setAnnotations(const []);
    _raw?.matches = (ranges: const <TextRange>[], active: -1);
  }

  /// Applies an inline font size to the current editor selection only.
  void _applySpanSize() {
    final size = double.tryParse(_spanSize.text.replaceAll(',', '.'));
    if (size == null || size < minSpanFontSize || size > maxSpanFontSize) {
      _notify(
        tr('Podaj rozmiar od 8 do 72 px.', 'Enter a size from 8 to 72 px.'),
      );
      return;
    }
    final result = applySpanFontSize(_editor.text, _editor.selection, size);
    if (result == null) {
      _notify(
        tr(
          'Zaznacz fragment tekstu, aby zmienić jego rozmiar.',
          'Select some text to change its size.',
        ),
      );
      return;
    }
    _editor.setValue(
      TextEditingValue(text: result.text, selection: result.selection),
    );
  }

  RegExpMatch? get _wikiPrefix {
    final caret = _editor.selection.extentOffset;
    if (caret < 0) return null;
    return RegExp(r'\[\[([^\]\n]*)$')
        .firstMatch(_editor.text.substring(0, caret));
  }

  List<Note> get _wikiSuggestions {
    if (_inHidden) return [];
    final prefix = _wikiPrefix;
    if (prefix == null) return [];
    final query = prefix.group(1)!.toLowerCase();
    return (repo.notes[_vaultId]?.values ?? <Note>[])
        .where(
          (n) =>
              !n.deleted &&
              n.id != _selected?.id &&
              n.title.toLowerCase().contains(query),
        )
        .take(5)
        .toList();
  }

  void _completeWiki(String title) {
    final prefix = _wikiPrefix;
    if (prefix == null) return;
    final caret = _editor.selection.extentOffset;
    final end = _editor.text.substring(caret).startsWith(']]')
        ? caret + 2
        : caret;
    final value = '[[$title]]';
    _editor.replaceRange(
      prefix.start,
      end,
      value,
      selection: TextSelection.collapsed(offset: prefix.start + value.length),
    );
  }

  /// The document caret rectangle in [_wikiStackKey] coordinates, measured
  /// from the laid-out body field. The floating suggestion panel anchors to
  /// it without ever taking part in the editor layout.
  Rect? _wikiCaretRect() {
    final stack =
        _wikiStackKey.currentContext?.findRenderObject() as RenderBox?;
    if (stack == null || !stack.hasSize) return null;
    final state = _bodyEditableState();
    if (state == null || !state.mounted) return null;
    final selection = state.textEditingValue.selection;
    if (!selection.isValid) return null;
    final editable = state.renderEditable;
    if (!editable.attached || !editable.hasSize) return null;
    final caret = editable.getLocalRectForCaret(
      TextPosition(offset: selection.extentOffset),
    );
    return stack.globalToLocal(editable.localToGlobal(caret.topLeft)) &
        caret.size;
  }

  /// Recomputes the caret anchor once, after the frame in which the editing
  /// value changed. The value guard keeps this out of a build/setState loop:
  /// an unchanged value or rectangle schedules no further frame.
  void _scheduleWikiAnchorUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final value = _editor.value;
      if (value == _wikiAnchorValue) return;
      _wikiAnchorValue = value;
      final next = _wikiCaretRect();
      if (next == _wikiCaret) return;
      setState(() => _wikiCaret = next);
    });
  }

  /// Primary-focus changes re-evaluate the panel visibility: focus leaving
  /// the document field hides the floating suggestions immediately. Focus
  /// can move during a frame, so the rebuild is deferred to a post-frame
  /// callback instead of a synchronous setState.
  void _wikiFocusChanged() {
    if (!mounted || _wikiCaret == null || _wikiFocusFramePending) return;
    _wikiFocusFramePending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _wikiFocusFramePending = false;
      if (mounted && _wikiCaret != null) setState(() {});
    });
  }

  /// The floating wiki suggestion panel anchored at the caret inside the
  /// document stack, or null while it must not be shown. The panel is a pure
  /// overlay: appearing or disappearing never moves the document layout or
  /// its scroll offset. Below the caret when there is room, above it when
  /// not. Taps on [SiliqueMenuRow] do not request focus, so the document
  /// field keeps the caret while the panel is open.
  Widget? _wikiSuggestionOverlay() {
    final suggestions = _wikiSuggestions;
    final caret = _wikiCaret;
    if (suggestions.isEmpty || caret == null) return null;
    if (_bodyEditableState()?.widget.focusNode.hasFocus != true) return null;
    final stack =
        _wikiStackKey.currentContext?.findRenderObject() as RenderBox?;
    if (stack == null || !stack.hasSize) return null;
    final size = stack.size;
    const width = 300.0, gap = 6.0, margin = 8.0;
    final height = suggestions.length * 48.0 + 16.0;
    var top = caret.bottom + gap;
    if (top + height > size.height) top = caret.top - height - gap;
    if (top < 0) top = 0;
    var left = caret.left < margin ? margin : caret.left;
    final maxLeft = size.width - width - margin;
    if (maxLeft > margin && left > maxLeft) left = maxLeft;
    return Positioned(
      left: left,
      top: top,
      width: width,
      child: SiliqueMenuSurface(
        key: const Key('wiki-suggestions'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final note in suggestions)
              SiliqueMenuRow(
                icon: Icons.link_outlined,
                child: Text(
                  note.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => _completeWiki(note.title),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _insertImage() async {
    if (_inHidden) return;
    final note = _selected;
    if (note == null || note.deleted) return;
    final platform = Theme.of(context).platform;
    final file =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS
        ? await ImagePicker().pickImage(
            source: ImageSource.gallery,
            requestFullMetadata: false,
          )
        : await pickImage();
    if (file != null) await _insertImageFiles(note, [file]);
  }

  Future<void> _insertImageFiles(
    Note target,
    List<XFile> files, {
    int? offset,
  }) async {
    var insertion = offset;
    var inserted = 0;
    final rejected = <String>[];
    for (final file in files) {
      try {
        final image = await readImageFile(file);
        final destination = await repo.addImage(
          target.vaultId,
          target.id,
          image.bytes,
          image.mime,
        );
        final alt = image.name.replaceAll(RegExp(r'[\[\]\r\n]'), '_');
        final markdown = '\n![$alt]($destination)\n';
        if (mounted &&
            _selected?.id == target.id &&
            _vaultId == target.vaultId) {
          final position =
              (insertion ??
                      (_editor.selection.isValid
                          ? _editor.selection.extentOffset
                          : _editor.text.length))
                  .clamp(0, _editor.text.length);
          _editor.replaceRange(
            position,
            position,
            markdown,
            selection: TextSelection.collapsed(
              offset: position + markdown.length,
            ),
          );
          insertion = position + markdown.length;
        } else {
          final current = repo.notes[target.vaultId]?[target.id];
          if (current == null ||
              current.deleted ||
              !repo.unlocked.containsKey(target.vaultId)) {
            throw StateError(
              tr('Notatka nie jest dostępna.', 'The note is not available.'),
            );
          }
          await repo.save(current.copyWith(body: '${current.body}$markdown'));
        }
        inserted++;
      } catch (error) {
        rejected.add('$error');
      }
    }
    if (mounted && _selected?.id == target.id) await _flush();
    if (rejected.isNotEmpty) {
      _notify(
        '${inserted > 0 ? tr('Wstawiono $inserted zdjęć. ', 'Inserted $inserted images. ') : ''}${rejected.join('\n')}',
      );
    }
  }

  int? _dropOffset(Offset point) {
    EditableTextState? state;
    void visit(Element element) {
      if (element is StatefulElement && element.state is EditableTextState) {
        state = element.state as EditableTextState;
      }
      element.visitChildren(visit);
    }

    (_editorViewport.currentContext as Element?)?.visitChildren(visit);
    return state?.renderEditable.getPositionForPoint(point).offset;
  }

  Widget _imageDropSurface(Widget child) => DropTarget(
    enable: !_inHidden && unlocked && _selected?.deleted == false && !_busy,
    onDragEntered: (_) => setState(() => _droppingImage = true),
    onDragExited: (_) => setState(() => _droppingImage = false),
    onDragDone: (details) async {
      setState(() => _droppingImage = false);
      final target = _selected;
      if (target == null || target.deleted) return;
      final offset = _dropOffset(details.globalPosition);
      final files = details.files.whereType<DropItemFile>().toList();
      if (files.isEmpty) {
        _notify(
          tr(
            'Przeciągnij plik zdjęcia do edytora.',
            'Drag an image file into the editor.',
          ),
        );
        return;
      }
      await _run(() async {
        final opened = <DropItemFile>[];
        try {
          for (final file in files) {
            final bookmark = file.extraAppleBookmark;
            if (bookmark != null && bookmark.isNotEmpty) {
              if (await DesktopDrop.instance
                  .startAccessingSecurityScopedResource(bookmark: bookmark)) {
                opened.add(file);
              }
            }
          }
          await _insertImageFiles(target, files, offset: offset);
        } finally {
          for (final file in opened) {
            await DesktopDrop.instance.stopAccessingSecurityScopedResource(
              bookmark: file.extraAppleBookmark!,
            );
          }
          for (final file in files.where((file) => file.fromPromise)) {
            await removePromisedImage(file);
          }
        }
      });
    },
    child: Stack(
      key: _editorViewport,
      fit: StackFit.expand,
      children: [
        child,
        if (_droppingImage)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: .12),
                  border: Border.all(color: accent, width: 2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.all(18),
                      child: Text(
                        tr('Upuść zdjęcia tutaj', 'Drop images here'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  /// The document body's editable state under the editor viewport. The title
  /// field shares the same scrollable document, so it is skipped by its
  /// controller identity.
  EditableTextState? _bodyEditableState() {
    EditableTextState? body;
    void visit(Element element) {
      if (element is StatefulElement && element.state is EditableTextState) {
        final state = element.state as EditableTextState;
        if (state.widget.controller != _title) body = state;
      }
      element.visitChildren(visit);
    }

    (_editorViewport.currentContext as Element?)?.visitChildren(visit);
    return body;
  }

  /// A tap on the blank area below the content continues typing at the end.
  void _focusBodyEnd() {
    if (_revealingHidden || (_inHidden && !_hiddenAvailable)) {
      return;
    }
    final state = _bodyEditableState();
    if (state == null || state.widget.readOnly) return;
    state.widget.controller.selection = TextSelection.collapsed(
      offset: state.widget.controller.text.length,
    );
    state.requestKeyboard();
  }

  /// Enter in the title moves focus to the body with the caret at its start.
  void _focusBodyFromTitle() {
    if (_editorReadOnly) return;
    if (_source) {
      final controller = _sourceController();
      controller.selection = TextSelection.collapsed(offset: 0);
      _sourceFocus.requestFocus();
      return;
    }
    final state = _bodyEditableState();
    if (state == null || state.widget.readOnly) return;
    state.widget.controller.selection = TextSelection.collapsed(offset: 0);
    state.widget.focusNode.requestFocus();
    state.requestKeyboard();
  }

  /// Keyboard handling for the note title field.
  ///
  /// The focus node sees hardware Enter before the text input connection, so
  /// Enter navigates to the body instead of being dropped by the newline
  /// formatter. The IME action path uses the field's [TextField.onSubmitted].
  KeyEventResult _titleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    _focusBodyFromTitle();
    return KeyEventResult.handled;
  }

  Future<String?> _contextMenu(
    Offset? point,
    Map<String, String Function()> entries,
  ) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final p = point ?? overlay.localToGlobal(overlay.size.center(Offset.zero));
    return showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(p.dx, p.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final entry in entries.entries) ...[
          if ((entry.key == 'rename' && entries.containsKey('sub')) ||
              entry.key == 'trash' ||
              entry.key == 'purge' ||
              entry.key == 'delete-hidden')
            const PopupMenuDivider(),
          SiliquePopupItem(
            value: entry.key,
            child: LanguageBuilder(builder: (_) => Text(entry.value())),
          ),
        ],
      ],
    );
  }

  Future<void> _noteMenu(Note note, Offset? point) async {
    if (note.hidden) {
      if (!_hiddenAvailable) return;
      final action = await _contextMenu(point, {
        'open': () => tr('Otwórz w karcie', 'Open in a tab'),
        'reveal': () => tr('Przenieś do folderu', 'Move to folder'),
        'delete-hidden': () => tr('Usuń ukrytą notatkę', 'Delete hidden note'),
      });
      if (!mounted || !_hiddenAvailable) return;
      if (action == 'open') await _select(note);
      if (action == 'reveal') await _run(() => _revealHidden(note));
      if (action == 'delete-hidden') await _run(() => _deleteHidden(note));
      return;
    }
    final action = await _contextMenu(point, {
      'open': () => tr('Otwórz w karcie', 'Open in a tab'),
      'rename': () => tr('Zmień nazwę', 'Rename'),
      'favorite': () =>
          note.favorite ? tr('Odepnij', 'Unpin') : tr('Przypnij', 'Pin'),
      'color': () => tr('Kolor notatki', 'Note color'),
      'move': () => tr('Przenieś do folderu', 'Move to folder'),
      if (!note.deleted)
        'hide': () => tr('Przenieś do ukrytych', 'Move to hidden notes'),
      'export': () => tr('Eksportuj Markdown', 'Export Markdown'),
      'trash': () => note.deleted
          ? tr('Przywróć z kosza', 'Restore from trash')
          : tr('Przenieś do kosza', 'Move to trash'),
      if (note.deleted)
        'purge': () => tr('Usuń bezpowrotnie', 'Delete permanently'),
    });
    if (action == null || !mounted) return;
    if (action == 'color') {
      await _pickNoteColor(note);
      return;
    }
    await _run(() async {
      await _flush();
      final current = repo.notes[note.vaultId]?[note.id] ?? note;
      if (action == 'open') {
        await _select(current);
        return;
      }
      if (action == 'export') {
        await exportMarkdown(await repo.noteWithEmbeddedImages(current));
        return;
      }
      if (action == 'favorite') {
        await _favorite(current);
        return;
      }
      if (action == 'hide') {
        await _hideNote(current);
        return;
      }
      if (action == 'move') {
        if (!mounted) return;
        final folder = await chooseTargetFolder(
          context,
          folders: _allFolderPaths,
          initial: '',
          folderColors: repo.folderColorsOf(_vaultId ?? ''),
        );
        if (folder != null && mounted) {
          await repo.moveNotes([current], folder);
          if (mounted) setState(_refreshSelected);
        }
        return;
      }
      if (action == 'purge') {
        if (!mounted ||
            !await confirmAction(
              context,
              () => tr('Usunąć bezpowrotnie?', 'Delete permanently?'),
              () => tr(
                'Notatka nie będzie dostępna do przywrócenia.',
                'The note cannot be restored.',
              ),
            )) {
          return;
        }
        await repo.purgeNote(current);
        await _closeTab(current.id);
        if (mounted) setState(() {});
        return;
      }
      Note changed = current;
      if (action == 'trash') {
        changed = current.copyWith(deleted: !current.deleted);
      }
      if (action == 'rename') {
        if (!mounted) return;
        final value = await askText(
          context,
          '',
          titleBuilder: () => tr('Zmień nazwę', 'Rename'),
          initial: current.title,
        );
        if (value == null) return;
        changed = current.copyWith(title: value);
      }
      await repo.save(changed);
      if (mounted) {
        // Moving the currently open note to the trash closes its tab so the
        // editor never keeps showing a note that is now in the trash. Restoring
        // a note keeps the ordinary reload path.
        if (action == 'trash' && changed.deleted) {
          await _closeTab(changed.id);
        } else {
          setState(() {
            if (_selected?.id == changed.id) _load(changed);
          });
        }
      }
    });
  }

  Future<void> _folderMenu(String folder, Offset? point) async {
    final action = await _contextMenu(point, {
      'sub': () => tr('Nowy podfolder', 'New subfolder'),
      'new': () => tr('Nowa notatka', 'New note'),
      'rename': () => tr('Zmień nazwę', 'Rename'),
      'move': () => tr('Przenieś folder', 'Move folder'),
      // The hidden section keeps its fixed presentation; accents are only
      // offered for the ordinary folder tree.
      if (!_inHidden) 'color': () => tr('Kolor folderu', 'Folder color'),
      'trash': () => tr('Przenieś folder do kosza', 'Move folder to trash'),
    });
    if (action == null || !mounted) return;
    if (_inHidden) await _filterBy('Wszystkie', folder: folder);
    if (!mounted) return;
    if (action == 'sub') {
      await _folderDialog(parent: folder);
      return;
    }
    if (action == 'color') {
      await _pickFolderColor(folder);
      return;
    }
    await _run(() async {
      await _flush();
      if (action == 'new') {
        final note = await repo.createNote(_vaultId!, folder: folder);
        await _select(note);
        return;
      }
      if (!mounted) return;
      if (action == 'move') {
        final parent = await chooseTargetFolder(
          context,
          folders: _allFolderPaths,
          sourceFolder: folder,
          folderColors: repo.folderColorsOf(_vaultId ?? ''),
        );
        if (parent == null || !mounted) return;
        await repo.renameFolder(
          vault!,
          folder,
          joinFolderPath(parent, folderName(folder)),
        );
        if (mounted) {
          setState(() {
            _folder = null;
            _clearSelection();
            _clearEditor();
          });
        }
        return;
      }
      String? name;
      if (action == 'rename') {
        final leaf = await askText(
          context,
          '',
          titleBuilder: () => tr('Nazwa folderu', 'Folder name'),
          initial: folderName(folder),
        );
        if (leaf == null) return;
        final error = folderSegmentError(leaf);
        if (error != null) throw FormatException(error);
        name = joinFolderPath(folderAncestors(folder).lastOrNull ?? '', leaf);
        if (name.trim().isEmpty) return;
        final normalized = normalizeFolderPath(name);
        if (normalized == null) {
          throw FormatException(
            folderPathError(name) ??
                tr('Nieprawidłowa ścieżka.', 'Invalid path.'),
          );
        }
        name = normalized;
      } else if (!await confirmAction(
        context,
        () => tr('Przenieść folder do kosza?', 'Move folder to trash?'),
        () => tr(
          'Wszystkie notatki w folderze i podfolderach trafią do kosza.',
          'All notes in this folder and its subfolders will be moved to trash.',
        ),
      )) {
        return;
      }
      if (action == 'rename') {
        await repo.renameFolder(vault!, folder, name!);
      } else {
        await repo.trashFolder(vault!, folder);
      }
      if (mounted) {
        setState(() {
          _folder = null;
          _clearSelection();
          _clearEditor();
        });
      }
    }, onError: (error) => _notify('$error'));
  }

  /// Accent stored for [path], or null when the row keeps its default icon
  /// color. The metadata facade stores 32-bit ARGB values. An explicit color
  /// wins over the vault's default folder color; when neither is set the row
  /// keeps its colorless look.
  Color? _folderColorOf(String path) {
    final explicit = repo.folderColorsOf(_vaultId ?? '')[path];
    final fallback = repo.defaultFolderColorOf(_vaultId ?? '');
    final argb = explicit ?? fallback;
    return argb == null ? null : Color(argb);
  }

  /// Opens the shared visual picker for [folder]. The result distinguishes an
  /// explicit color from the "no color" choice, and both from cancelling. The
  /// choice persists through [_run] like the other folder actions.
  Future<void> _pickFolderColor(String folder) async {
    final target = vault;
    if (target == null) return;
    final current = _folderColorOf(folder);
    final result = await showVisualColorPicker(
      context,
      initial: current,
      title: tr('Kolor folderu', 'Folder color'),
    );
    if (result == null || !mounted) return;
    final argb = switch (result) {
      VisualColorClear() => null,
      VisualColorValue(:final color) => color.toARGB32(),
    };
    await _run(() async {
      await _flush();
      await repo.setFolderColor(target, folder, argb);
      if (mounted) setState(() {});
    }, onError: (error) => _notify('$error'));
  }

  /// Opens the shared visual picker for [note]. The result distinguishes an
  /// explicit color from "no color" (which clears the entry), and both from
  /// cancelling. The choice persists through [_run] like the folder color.
  Future<void> _pickNoteColor(Note note) async {
    final target = repo.vaults.where((v) => v.id == note.vaultId).firstOrNull;
    if (target == null) return;
    final stored = repo.noteColorsOf(note.vaultId)[note.id];
    final result = await showVisualColorPicker(
      context,
      initial: stored == null ? null : Color(stored),
      title: tr('Kolor notatki', 'Note color'),
    );
    if (result == null || !mounted) return;
    final argb = switch (result) {
      VisualColorClear() => null,
      VisualColorValue(:final color) => color.toARGB32(),
    };
    await _run(() async {
      await _flush();
      await repo.setNoteColor(target, note.id, argb);
      if (mounted) setState(() {});
    }, onError: (error) => _notify('$error'));
  }

  void _vaultDeleted(String id) {
    if (!mounted) return;
    for (final image
        in _editorImages
            .whereType<AttachmentImage>()
            .where((image) => image.vaultId == id)
            .toList()) {
      PaintingBinding.instance.imageCache.evict(image, includeLive: true);
      _editorImages.remove(image);
    }
    if (_vaultId != id) {
      setState(() {});
      return;
    }
    setState(() {
      _generation++;
      _hiddenEpoch++;
      _clearEditor();
      _hiddenNotes.clear();
      _hiddenSaveError = null;
      _clearTabs();
      _clearSelection();
      _collapsedFolders.clear();
      _closeFind();
      _search.clear();
      _filter = 'Wszystkie';
      _folder = null;
      _vaultId = repo.vaults
          .where((v) => v.id != id && !repo.vaultDeletionPending(v.id))
          .firstOrNull
          ?.id;
      _mobileEditor = false;
      _status = 'Vault usunięty • kończenie porządkowania';
    });
  }

  Future<void> _deleteVault(Vault target) => _run(() async {
    if (repo.vaultDeletionPending(target.id)) {
      await repo.retryVaultDeletions();
      if (mounted) setState(() {});
      return;
    }
    if (!repo.unlocked.containsKey(target.id)) {
      final password = await askText(
        context,
        '',
        titleBuilder: () => tr(
          'Odblokuj vault przed usunięciem',
          'Unlock the vault before deleting it',
        ),
        secret: true,
        hintBuilder: () => tr('Hasło vaulta', 'Vault password'),
      );
      if (password == null) return;
      await repo.unlock(target, password: password);
    }
    if (!mounted) return;
    final current = repo.vaults.where((v) => v.id == target.id).firstOrNull;
    if (current == null) return;
    final removed = await deleteVaultDialog(context, current, (
      confirmation,
    ) async {
      final operation = repo.vaultDeletionPending(current.id)
          ? repo.retryVaultDeletions()
          : repo.deleteVault(current, confirmation: confirmation);
      if (mounted) setState(() {});
      try {
        await operation;
      } finally {
        if (mounted) setState(() {});
      }
    });
    if (removed) {
      _notify(
        tr(
          'Usunięto vault wraz z zawartością w podanym zakresie.',
          'The vault and its contents were deleted within the specified scope.',
        ),
      );
    }
  });

  Future<void> _manageVaults() async {
    await _flush();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        Localizations.localeOf(ctx);
        return SimpleDialog(
          title: Text(tr('Zarządzaj vaultami', 'Manage vaults')),
          children: [
            for (final v in repo.vaults)
              SiliqueMenuRow(
                icon: v.protected ? Icons.lock_outline : Icons.folder_outlined,
                selected: v.id == _vaultId,
                subtitle: Text(
                  repo.vaultDeletionPending(v.id)
                      ? tr(
                          'Usuwanie oczekuje na dokończenie',
                          'Deletion pending',
                        )
                      : v.syncEnabled
                      ? tr('Synchronizacja E2EE', 'E2EE sync')
                      : tr('Lokalnie', 'Local'),
                ),
                onTap: repo.vaultDeletionPending(v.id)
                    ? null
                    : () {
                        Navigator.pop(ctx);
                        _switch(v.id);
                      },
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: tr('Zmień nazwę', 'Rename'),
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: repo.vaultDeletionPending(v.id)
                          ? null
                          : () async {
                              final name = await askText(
                                ctx,
                                '',
                                titleBuilder: () =>
                                    tr('Nazwa vaulta', 'Vault name'),
                                initial: v.name,
                              );
                              if (name != null) {
                                await _run(() async {
                                  await repo.renameVault(v, name);
                                  if (ctx.mounted) Navigator.pop(ctx);
                                  if (mounted) setState(() {});
                                });
                              }
                            },
                    ),
                    IconButton(
                      tooltip: repo.vaultDeletionPending(v.id)
                          ? tr('Dokończ usuwanie', 'Finish deletion')
                          : tr(
                              'Usuń vault wraz z zawartością',
                              'Delete vault and contents',
                            ),
                      icon: Icon(
                        repo.vaultDeletionPending(v.id)
                            ? Icons.refresh
                            : Icons.delete_outline,
                        color: accent,
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        unawaited(_deleteVault(v));
                      },
                    ),
                  ],
                ),
                child: Text(v.name),
              ),
            const Divider(height: 16, color: menuBorder),
            SiliqueMenuRow(
              icon: Icons.create_new_folder_outlined,
              onTap: () {
                Navigator.pop(ctx);
                _run(_createVault);
              },
              child: Text(tr('Utwórz vault', 'Create vault')),
            ),
            if (canMoveStorage)
              SiliqueMenuRow(
                icon: Icons.drive_file_move_outline,
                onTap: () {
                  Navigator.pop(ctx);
                  _run(_moveStorage);
                },
                child: Text(
                  tr(
                    'Miejsce zapisu i przenoszenie danych',
                    'Storage location and data transfer',
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _moveStorage() async {
    if (!mounted) return;
    if (!await confirmAction(
      context,
      () => tr('Miejsce zapisu', 'Storage location'),
      () => tr(
        'Bieżący katalog: ${repo.dataLocation}\n\nWybierz pusty katalog. Przeniesione zostaną wszystkie lokalne vaulty i ich pliki. Kopia w poprzednim miejscu pozostanie do odzyskania danych.',
        'Current directory: ${repo.dataLocation}\n\nChoose an empty directory. All local vaults and their files will be moved. A copy will remain in the previous location for recovery.',
      ),
    )) {
      return;
    }
    final choice = await chooseStorageDirectory();
    if (choice == null) return;
    if (!choice.usable) {
      _notify(
        tr(
          'Ten katalog nie daje ścieżki plikowej wymaganej przez bazę notatek. '
              'Wybierz inny katalog.',
          'This directory does not provide the file path required by the notes database. Choose another directory.',
        ),
      );
      return;
    }
    final destination = choice.path!;
    await _flush();
    final root = NativeStorage.prepareChosenRoot(destination);
    await rememberStorageAccess(root);
    await repo.moveStorage(root);
    _notify(tr('Przeniesiono dane do $root', 'Data moved to $root'));
  }

  String _snippet(Note note) {
    var body = note.body
        .replaceAll(RegExp(r'[#*`>\[\]]'), '')
        .replaceAll('\n', ' ')
        .trim();
    final q = _query.toLowerCase();
    final index = body.toLowerCase().indexOf(q);
    if (q.isNotEmpty && index > 30) body = '…${body.substring(index - 25)}';
    return body;
  }

  String _timestamp(DateTime value) {
    final d = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  String _time(Note n) {
    final date = n.updatedAt.toLocal(), now = DateTime.now();
    if (date.year == now.year &&
        date.month == now.month &&
        date.day == now.day) {
      return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    }
    return '${date.day}.${date.month.toString().padLeft(2, '0')}';
  }

  Future<void> _openLink(String destination) async {
    final uri = Uri.tryParse(destination);
    if (uri?.scheme == 'silique-note') {
      final note = _noteById(uri!.path);
      if (note != null && !note.deleted) {
        await _select(note);
      } else {
        _notify(
          tr(
            'Ta notatka nie jest już dostępna.',
            'This note is no longer available.',
          ),
        );
      }
      return;
    }
    if (uri == null || !['https', 'http', 'mailto'].contains(uri.scheme)) {
      _notify(tr('Nieobsługiwany typ odnośnika.', 'Unsupported link type.'));
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _wiki(String target) async {
    if (_inHidden) {
      await _run(() async {
        if (!_hiddenAvailable) return;
        await _flush();
        if (!_hiddenAvailable) return;
        final epoch = _hiddenEpoch;
        var note = _hiddenNotes.values
            .where((n) => n.title.toLowerCase() == target.toLowerCase())
            .firstOrNull;
        if (note == null) {
          note = await repo.createHiddenNote(_vaultId!);
          if (!mounted || !_hiddenAvailable || epoch != _hiddenEpoch) return;
          note = note.copyWith(title: target);
          await repo.save(note);
          if (!mounted || !_hiddenAvailable || epoch != _hiddenEpoch) return;
          _hiddenNotes[note.id] = note;
        }
        await _select(note);
      });
      return;
    }
    final match = repo.notes[_vaultId]?.values
        .where(
          (n) => !n.deleted && n.title.toLowerCase() == target.toLowerCase(),
        )
        .firstOrNull;
    if (match != null) {
      await _select(match);
    } else {
      final n = await repo.createNote(_vaultId!);
      final changed = n.copyWith(title: target);
      await repo.save(changed);
      await _select(changed);
    }
  }

  @override
  Widget build(BuildContext context) {
    Localizations.localeOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final mobile = constraints.maxWidth < 1000;
        final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
        final bottomNavVisible = mobile && !_mobileEditor && !keyboardOpen;
        return PopScope(
          canPop: !mobile || !_mobileEditor,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && mobile && _mobileEditor) {
              unawaited(_returnToList());
            }
          },
          child: CallbackShortcuts(
            bindings: {
              LogicalKeySet(
                LogicalKeyboardKey.control,
                LogicalKeyboardKey.keyF,
              ): _showFind,
              LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyF):
                  _showFind,
              LogicalKeySet(
                LogicalKeyboardKey.control,
                LogicalKeyboardKey.keyN,
              ): () =>
                  _newNote(),
              LogicalKeySet(
                LogicalKeyboardKey.meta,
                LogicalKeyboardKey.keyN,
              ): () =>
                  _newNote(),
              LogicalKeySet(
                LogicalKeyboardKey.control,
                LogicalKeyboardKey.keyK,
              ): () {
                setState(() => _mobileEditor = false);
                _searchFocus.requestFocus();
              },
              LogicalKeySet(
                LogicalKeyboardKey.meta,
                LogicalKeyboardKey.keyK,
              ): () {
                setState(() => _mobileEditor = false);
                _searchFocus.requestFocus();
              },
              LogicalKeySet(
                LogicalKeyboardKey.control,
                LogicalKeyboardKey.keyS,
              ): () =>
                  _flush(),
              const SingleActivator(LogicalKeyboardKey.escape): () {
                if (_hasSelection) {
                  setState(_clearSelection);
                } else if (_finding) {
                  setState(_closeFind);
                } else if (_focus) {
                  setState(() => _focus = false);
                } else if (mobile) {
                  setState(() => _mobileEditor = false);
                }
              },
            },
            child: Scaffold(
              key: _scaffold,
              floatingActionButton: bottomNavVisible && repo.vaults.isNotEmpty
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: 74),
                      child: FloatingActionButton(
                        onPressed: () => _newNote(),
                        backgroundColor: const Color(0xff6660ff),
                        foregroundColor: Colors.white,
                        elevation: 2,
                        shape: const CircleBorder(),
                        tooltip: tr('Nowa notatka', 'New note'),
                        child: const Icon(Icons.add),
                      ),
                    )
                  : null,
              drawerEnableOpenDragGesture: false,
              drawer: mobile
                  ? Drawer(
                      width: 260,
                      backgroundColor: sidebar,
                      child: SafeArea(child: _sidebar(mobile: true)),
                    )
                  : null,
              body: _navigationSwipe(
                mobile,
                SafeArea(
                  child: Stack(
                    children: [
                      if (repo.vaults.isEmpty)
                        _onboarding()
                      else
                        Column(
                          children: [
                            Expanded(
                              child: Row(
                                children: [
                                  if (!mobile &&
                                      !_focus &&
                                      !(_compactLayout && _sidebarCollapsed))
                                    SizedBox(
                                      width: _compactLayout ? 300 : 220,
                                      child: _sidebar(),
                                    ),
                                  if (!mobile &&
                                      !_focus &&
                                      _compactLayout &&
                                      _sidebarCollapsed)
                                    SizedBox(
                                      width: 40,
                                      child: Column(
                                        children: [
                                          const SizedBox(height: 18),
                                          IconButton(
                                            key: const Key('sidebar-restore'),
                                            tooltip: tr(
                                              'Pokaż menu boczne',
                                              'Show sidebar',
                                            ),
                                            icon: const Icon(
                                              Icons.keyboard_double_arrow_right,
                                              size: 17,
                                            ),
                                            onPressed: () => setState(
                                              () => _sidebarCollapsed = false,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  if (!mobile && !_focus)
                                    const VerticalDivider(width: 1),
                                  if (!mobile &&
                                      !_focus &&
                                      !_notesCollapsed &&
                                      !_compactLayout)
                                    SizedBox(
                                      key: const Key('notes-list-panel'),
                                      width: constraints.maxWidth < 1050
                                          ? 270
                                          : 320,
                                      child: _noteList(false),
                                    ),
                                  if (!mobile &&
                                      !_focus &&
                                      _notesCollapsed &&
                                      !_compactLayout)
                                    SizedBox(
                                      width: 40,
                                      child: Column(
                                        children: [
                                          const SizedBox(height: 18),
                                          IconButton(
                                            key: const Key(
                                              'sidebar-toggle-notes-list',
                                            ),
                                            tooltip: tr(
                                              'Pokaż listę notatek',
                                              'Show notes list',
                                            ),
                                            icon: const Icon(
                                              Icons.keyboard_double_arrow_right,
                                              size: 17,
                                            ),
                                            onPressed: () => setState(
                                              () => _notesCollapsed = false,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  if (!mobile && !_focus && !_compactLayout)
                                    const VerticalDivider(width: 1),
                                  Expanded(
                                    child: mobile
                                        ? (_mobileEditor && _selected != null
                                              ? TopPullDismiss(
                                                  onDismiss: _returnToList,
                                                  child: _editorPane(true),
                                                )
                                              : _noteList(true))
                                        : _editorPane(false),
                                  ),
                                ],
                              ),
                            ),
                            if (bottomNavVisible) _bottomNav(),
                          ],
                        ),
                      // The editor footer carries the indicator while a note
                      // is open; every other layout pins the same icon to the
                      // bottom-right window corner. On phones that spot sits
                      // between the bottom navigation and the FAB. The hidden
                      // view keeps its textual security context instead.
                      if (repo.vaults.isNotEmpty &&
                          !_inHidden &&
                          !_statusFooterShown(mobile))
                        Positioned(
                          right: 14,
                          bottom: bottomNavVisible ? 68 : 8,
                          child: _syncBadge(small: true),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Offset? _swipeStart;
  double _swipeDistance = 0;
  Widget _navigationSwipe(bool mobile, Widget child) {
    child = Listener(
      onPointerDown: (_) {
        if (_hiddenAvailable) repo.hiddenActivity();
      },
      onPointerSignal: (_) {
        if (_hiddenAvailable) repo.hiddenActivity();
      },
      child: child,
    );
    final platform = Theme.of(context).platform;
    if (!mobile ||
        (platform != TargetPlatform.android &&
            platform != TargetPlatform.iOS)) {
      return child;
    }
    return GestureDetector(
      key: const Key('navigation-swipe'),
      dragStartBehavior: DragStartBehavior.down,
      onHorizontalDragStart: (details) {
        final edge = MediaQuery.systemGestureInsetsOf(context).left;
        _swipeStart =
            details.kind == PointerDeviceKind.touch &&
                details.globalPosition.dx > (edge > 32 ? edge : 32) &&
                (_editor.selection.isCollapsed || !_mobileEditor)
            ? details.globalPosition
            : null;
        _swipeDistance = 0;
      },
      onHorizontalDragUpdate: (details) {
        if (_swipeStart != null) _swipeDistance += details.delta.dx;
      },
      onHorizontalDragEnd: (details) {
        if (_swipeStart != null &&
            _swipeDistance >= 72 &&
            (details.primaryVelocity ?? 0) >= 0) {
          FocusManager.instance.primaryFocus?.unfocus();
          _scaffold.currentState?.openDrawer();
        }
        _swipeStart = null;
      },
      onHorizontalDragCancel: () => _swipeStart = null,
      child: child,
    );
  }

  // ── Sidebar ──────────────────────────────────────────────────────────

  void _measureSearchField() {
    final ctx = _searchFieldMeasureKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box != null && mounted && box.size.height != _searchFieldExtent) {
      setState(() => _searchFieldExtent = box.size.height);
    }
  }

  Widget _sidebar({bool mobile = false}) {
    if (_compactLayout && !mobile) return _compactSidebar(mobile);
    return _classicSidebar(mobile);
  }

  /// Compact sidebar: the entire content (header, vault chooser, filters,
  /// search, tree, footer) scrolls as one unit.  The search field sticks to
  /// the top via a `SliverPersistentHeader` once the user scrolls past it.
  Widget _compactSidebar(bool mobile) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureSearchField());
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [sidebar, Color(0xff101725)],
        ),
      ),
      child: CustomScrollView(
        key: const Key('compact-tree-list'),
        slivers: [
          // ── Header ──
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 6, 18),
              child: Row(
                children: [
                  const SiliqueMark(size: 30),
                  const SizedBox(width: 9),
                  const Expanded(
                    child: Text(
                      'SILIQUE',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        letterSpacing: .4,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('sidebar-toggle-notes-list'),
                    tooltip: _sidebarCollapsed
                        ? tr('Pokaż menu boczne', 'Show sidebar')
                        : tr('Ukryj menu boczne', 'Hide sidebar'),
                    icon: Icon(
                      _sidebarCollapsed
                          ? Icons.keyboard_double_arrow_right
                          : Icons.keyboard_double_arrow_left,
                      size: 17,
                    ),
                    onPressed: () =>
                        setState(() => _sidebarCollapsed = !_sidebarCollapsed),
                  ),
                ],
              ),
            ),
          ),
          // ── Vault chooser ──
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: _vaultChooser(),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          // ── New note button ──
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: _newNoteButton(mobile),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          // ── Nav items ──
          SliverToBoxAdapter(
            child: _nav(
              Icons.calendar_month_outlined,
              tr('Nowy wpis w dzienniku', 'New journal entry'),
              () => _runFromDrawer(mobile, () => _newNote(journal: true)),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          // ── Divider + folders label ──
          const SliverToBoxAdapter(child: Divider(height: 1)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tr('FOLDERY', 'FOLDERS'),
                      style: TextStyle(
                        fontSize: 10,
                        letterSpacing: .6,
                        color: muted,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('new-root-folder'),
                    onPressed: unlocked ? () => _folderDialog() : null,
                    icon: const Icon(
                      Icons.create_new_folder_outlined,
                      size: 15,
                    ),
                    tooltip: tr('Nowy folder', 'New folder'),
                  ),
                ],
              ),
            ),
          ),
          // ── Sticky search field ──
          SliverPersistentHeader(
            pinned: true,
            delegate: _FixedExtentDelegate(
              extent: _searchFieldExtent,
              child: Container(
                key: _searchFieldMeasureKey,
                color: const Color(0xff101725),
                child: _searchField(false),
              ),
            ),
          ),
          // ── Compact filter chips ──
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(13, 0, 13, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        for (final f in ['Ostatnie', 'Ulubione'])
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: InkWell(
                              key: Key('compact-filter-$f'),
                              borderRadius: BorderRadius.circular(18),
                              onTap: () => _filterBy(f),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  color: _filter == f
                                      ? accent.withValues(alpha: .12)
                                      : Colors.transparent,
                                  border: Border.all(
                                    color: line.withValues(alpha: .5),
                                  ),
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: Text(
                                  _filterLabel(f),
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: _filter == f ? accent : muted,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const Key('compact-select-mode'),
                    tooltip: _selecting
                        ? tr('Zakończ zaznaczanie', 'Finish selecting')
                        : tr('Zaznacz wiele notatek', 'Select multiple notes'),
                    icon: Icon(
                      _selecting
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 17,
                      color: _selecting ? accent : null,
                    ),
                    onPressed: () => setState(() {
                      if (_selecting) {
                        _clearSelection();
                      } else {
                        _selecting = true;
                      }
                    }),
                  ),
                ],
              ),
            ),
          ),
          // ── Tree (folders + notes) or flat filtered list ──
          ...(_compactTree
              ? _compactTreeSlivers(mobile)
              : _compactFilteredSlivers(mobile)),
          // ── Footer ──
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: Row(
                key: const Key('sidebar-footer-actions'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _footerAction(
                    label: tr('Usunięte', 'Deleted'),
                    icon: Icons.delete_outline,
                    selected: _filter == 'Kosz',
                    onPressed: () =>
                        _runFromDrawer(mobile, () => _filterBy('Kosz')),
                  ),
                  _footerAction(
                    key: const Key('hidden-folder-nav'),
                    label: _filterLabel('Ukryte'),
                    icon: Icons.lock_outline,
                    selected: _inHidden,
                    onPressed: () =>
                        _runFromDrawer(mobile, () => _filterBy('Ukryte')),
                  ),
                  _footerAction(
                    label: tr('Importuj', 'Import'),
                    icon: Icons.file_upload_outlined,
                    onPressed: !unlocked || _inHidden || _busy
                        ? null
                        : () =>
                              _runFromDrawer(mobile, () => _run(_importVault)),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: panel.withValues(alpha: .65),
                  border: Border.all(color: line),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      vault?.protected == true
                          ? Icons.lock_outline
                          : Icons.cloud_outlined,
                      color: const Color(0xff81e7db),
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            vault?.name ?? 'Vault',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                          Text(
                            tr(
                              '${repo.notes[_vaultId]?.values.where((n) => !n.deleted).length ?? 0} notatek • ${vault?.syncEnabled == true ? 'E2EE' : 'lokalnie'}',
                              '${repo.notes[_vaultId]?.values.where((n) => !n.deleted).length ?? 0} notes • ${vault?.syncEnabled == true ? 'E2EE' : 'local'}',
                            ),
                            style: const TextStyle(fontSize: 10, color: muted),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: _settings,
                      icon: const Icon(Icons.settings_outlined, size: 15),
                      tooltip: tr('Ustawienia synchronizacji', 'Sync settings'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Classic sidebar: fixed header + scrollable folder tree.  The notes-list
  /// toggle button lives in `_noteList`, not here.
  Widget _classicSidebar(bool mobile) => Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [sidebar, Color(0xff101725)],
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16, 18, mobile ? 16 : 6, 18),
          child: Row(
            children: [
              const SiliqueMark(size: 30),
              const SizedBox(width: 9),
              const Expanded(
                child: Text(
                  'SILIQUE',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .4,
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: _vaultChooser(),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: _newNoteButton(mobile),
        ),
        const SizedBox(height: 12),
        _nav(
          Icons.calendar_month_outlined,
          tr('Nowy wpis w dzienniku', 'New journal entry'),
          () => _runFromDrawer(mobile, () => _newNote(journal: true)),
        ),
        const SizedBox(height: 12),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  tr('FOLDERY', 'FOLDERS'),
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: .6,
                    color: muted,
                  ),
                ),
              ),
              IconButton(
                key: const Key('new-root-folder'),
                onPressed: unlocked ? () => _folderDialog() : null,
                icon: const Icon(Icons.create_new_folder_outlined, size: 15),
                tooltip: tr('Nowy folder', 'New folder'),
              ),
            ],
          ),
        ),
        Expanded(
          child: _compactTree
              ? _compactTreeList(mobile)
              : _compactFiltered
              ? _compactFilteredList(mobile)
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  children: [
                    _folderDropTarget(
                      folder: '',
                      child: _folderRow(
                        tr('Wszystkie notatki', 'All notes'),
                        Icons.notes_outlined,
                        selected: _folder == null && _filter == 'Wszystkie',
                        onTap: () => _runFromDrawer(
                          mobile,
                          () => _filterBy('Wszystkie'),
                        ),
                      ),
                    ),
                    for (final entry in _folderRows)
                      _folderDropTarget(
                        folder: entry.path,
                        child: _folderRow(
                          entry.name,
                          entry.path == 'Dziennik'
                              ? Icons.calendar_month_outlined
                              : Icons.folder_outlined,
                          depth: entry.depth,
                          hasChildren: entry.hasChildren,
                          expanded: !_collapsedFolders.contains(entry.path),
                          onToggle: () => setState(() {
                            if (!_collapsedFolders.remove(entry.path)) {
                              _collapsedFolders.add(entry.path);
                            }
                          }),
                          selected: _folder == entry.path,
                          folderPath: entry.path,
                          draggable: unlocked,
                          longPressDrag: mobile,
                          onTap: () => _runFromDrawer(
                            mobile,
                            () => _filterBy('Wszystkie', folder: entry.path),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
          child: Row(
            key: const Key('sidebar-footer-actions'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _footerAction(
                label: tr('Usunięte', 'Deleted'),
                icon: Icons.delete_outline,
                selected: _filter == 'Kosz',
                onPressed: () =>
                    _runFromDrawer(mobile, () => _filterBy('Kosz')),
              ),
              _footerAction(
                key: const Key('hidden-folder-nav'),
                label: _filterLabel('Ukryte'),
                icon: Icons.lock_outline,
                selected: _inHidden,
                onPressed: () =>
                    _runFromDrawer(mobile, () => _filterBy('Ukryte')),
              ),
              _footerAction(
                label: tr('Importuj', 'Import'),
                icon: Icons.file_upload_outlined,
                onPressed: !unlocked || _inHidden || _busy
                    ? null
                    : () => _runFromDrawer(mobile, () => _run(_importVault)),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: panel.withValues(alpha: .65),
              border: Border.all(color: line),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  vault?.protected == true
                      ? Icons.lock_outline
                      : Icons.cloud_outlined,
                  color: const Color(0xff81e7db),
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        vault?.name ?? 'Vault',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                      ),
                      Text(
                        tr(
                          '${repo.notes[_vaultId]?.values.where((n) => !n.deleted).length ?? 0} notatek • ${vault?.syncEnabled == true ? 'E2EE' : 'lokalnie'}',
                          '${repo.notes[_vaultId]?.values.where((n) => !n.deleted).length ?? 0} notes • ${vault?.syncEnabled == true ? 'E2EE' : 'local'}',
                        ),
                        style: const TextStyle(fontSize: 10, color: muted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _settings,
                  icon: const Icon(Icons.settings_outlined, size: 15),
                  tooltip: tr('Ustawienia synchronizacji', 'Sync settings'),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
  Widget _footerAction({
    Key? key,
    required String label,
    required IconData icon,
    bool selected = false,
    required VoidCallback? onPressed,
  }) {
    // Same hover surface as _folderRow: rounded Material + InkWell with the
    // theme hover color, instead of a TextButton's differently shaped splash.
    final foreground = selected ? accent : muted;
    return Expanded(
      key: key,
      child: Material(
        color: selected ? accent.withValues(alpha: .12) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 19, color: foreground),
                const SizedBox(height: 5),
                SizedBox(
                  width: double.infinity,
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 10, color: foreground),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Back row rendered above a compact filtered note list: returns to the
  /// full folder+notes tree. For the hidden filter this goes through
  /// `_filterBy('Wszystkie')`, which calls `_leaveHiddenFolder`, so plaintext
  /// never remains in view.
  Widget _compactBackRow(bool mobile) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
    child: Material(
      key: const Key('compact-back-row'),
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _runFromDrawer(mobile, () => _filterBy('Wszystkie')),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.arrow_back, size: 16, color: muted),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  tr('Wszystkie notatki', 'All notes'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: muted),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  /// A single note row in a compact filtered list (flat, no folder indent).
  Widget _compactFilteredNoteRow(Note note, bool mobile) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10),
    child: _noteCard(
      note,
      mobile,
      compact: true,
      onTap: mobile
          ? () {
              Navigator.pop(context);
              _handleNoteTap(note);
            }
          : null,
    ),
  );

  /// Compact filtered state (trash / recent / favorites / hidden) as slivers
  /// for the desktop `CustomScrollView`: a back row + flat note list which
  /// replaces the folder tree, still inside the single sidebar column.
  List<Widget> _compactFilteredSlivers(bool mobile) => [
    SliverToBoxAdapter(child: _compactBackRow(mobile)),
    if (_selecting) ...[
      SliverToBoxAdapter(child: _compactSelectAll()),
      SliverToBoxAdapter(child: _selectionBar(mobile)),
    ],
    if (_inHidden && !_hiddenAvailable)
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Text(
                tr(
                  'Ukryte notatki są zablokowane.',
                  'Hidden notes are locked.',
                ),
              ),
              TextButton(
                onPressed: _openHidden,
                child: Text(tr('Odblokuj', 'Unlock')),
              ),
            ],
          ),
        ),
      )
    else if (filtered.isEmpty)
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            tr('Brak notatek', 'No notes'),
            style: const TextStyle(color: muted),
          ),
        ),
      )
    else
      for (final note in filtered)
        SliverToBoxAdapter(child: _compactFilteredNoteRow(note, mobile)),
  ];

  /// Mobile drawer variant of `_compactFilteredSlivers`, as a `ListView`.
  Widget _compactFilteredList(bool mobile) => ListView(
    key: const Key('compact-tree-list'),
    padding: const EdgeInsets.symmetric(vertical: 8),
    children: [
      _compactBackRow(mobile),
      if (_inHidden && !_hiddenAvailable)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Text(
                tr(
                  'Ukryte notatki są zablokowane.',
                  'Hidden notes are locked.',
                ),
              ),
              TextButton(
                onPressed: _openHidden,
                child: Text(tr('Odblokuj', 'Unlock')),
              ),
            ],
          ),
        )
      else if (filtered.isEmpty)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            tr('Brak notatek', 'No notes'),
            style: const TextStyle(color: muted),
          ),
        )
      else
        for (final note in filtered) _compactFilteredNoteRow(note, mobile),
    ],
  );

  /// Flattens the compact folder+notes tree into a list of slivers so the
  /// outer `CustomScrollView` can scroll through them as one unit without a
  /// nested `ListView`.
  List<Widget> _compactTreeSlivers(bool mobile) {
    final searching = _query.trim().isNotEmpty;
    final notesByFolder = <String, List<Note>>{};
    for (final note in filtered) {
      notesByFolder.putIfAbsent(note.folder.trim(), () => []).add(note);
    }
    final rootHasNotes = (notesByFolder[''] ?? const <Note>[]).isNotEmpty;
    var entries = searching
        ? repo.folderRowsOf(_vaultId ?? '')
        : _compactFolderRows();
    if (searching) {
      entries = entries
          .where(
            (entry) => notesByFolder.keys.any(
              (folder) =>
                  folder == entry.path || folder.startsWith('${entry.path}/'),
            ),
          )
          .toList();
    }

    Widget noteRow(Note note, int depth) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Padding(
        padding: EdgeInsets.only(
          top: 4,
          left: 20 + (depth * 14).clamp(0, 70).toDouble(),
        ),
        child: _noteCard(
          note,
          mobile,
          compact: true,
          onTap: mobile
              ? () {
                  Navigator.pop(context);
                  _handleNoteTap(note);
                }
              : null,
        ),
      ),
    );

    final rootExpanded = searching || _compactRootExpanded;
    final slivers = <Widget>[
      if (_selecting) ...[
        SliverToBoxAdapter(child: _compactSelectAll()),
        SliverToBoxAdapter(child: _selectionBar(mobile)),
      ],
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: _folderDropTarget(
            folder: '',
            child: _folderRow(
              tr('Wszystkie notatki', 'All notes'),
              Icons.notes_outlined,
              selected: true,
              hasChildren: rootHasNotes || entries.isNotEmpty,
              expanded: rootExpanded,
              toggleKey: 'compact-root-toggle',
              onToggle: () =>
                  setState(() => _compactRootExpanded = !_compactRootExpanded),
              onTap: () =>
                  setState(() => _compactRootExpanded = !_compactRootExpanded),
            ),
          ),
        ),
      ),
    ];

    if (rootExpanded) {
      for (final note in notesByFolder[''] ?? const <Note>[]) {
        slivers.add(SliverToBoxAdapter(child: noteRow(note, 0)));
      }
    }

    for (final entry in entries) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
            child: _folderDropTarget(
              folder: entry.path,
              child: _folderRow(
                entry.name,
                entry.path == 'Dziennik'
                    ? Icons.calendar_month_outlined
                    : Icons.folder_outlined,
                depth: entry.depth,
                hasChildren:
                    entry.hasChildren ||
                    (notesByFolder[entry.path]?.isNotEmpty ?? false),
                expanded: searching || _compactExpanded.contains(entry.path),
                onToggle: () => setState(() {
                  if (!_compactExpanded.remove(entry.path)) {
                    _compactExpanded.add(entry.path);
                  }
                }),
                selected: _folder == entry.path,
                folderPath: entry.path,
                draggable: unlocked,
                longPressDrag: mobile,
                onTap: () => setState(() {
                  if (!_compactExpanded.remove(entry.path)) {
                    _compactExpanded.add(entry.path);
                  }
                }),
              ),
            ),
          ),
        ),
      );
      if (searching || _compactExpanded.contains(entry.path)) {
        for (final note in notesByFolder[entry.path] ?? const <Note>[]) {
          slivers.add(
            SliverToBoxAdapter(child: noteRow(note, entry.depth + 1)),
          );
        }
      }
    }

    if (searching && filtered.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Icon(Icons.search_off, size: 38, color: muted),
                const SizedBox(height: 12),
                Text(
                  tr('Nie znaleziono notatek', 'No notes found'),
                  style: const TextStyle(color: muted),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return slivers;
  }

  void _runFromDrawer(bool mobile, Future<void> Function() action) {
    if (mobile) Navigator.pop(context);
    unawaited(
      action().catchError((Object e) {
        _notify('$e');
      }),
    );
  }

  /// The accent "New note" button shared by the classic and compact sidebars.
  Widget _newNoteButton(bool mobile) => Container(
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [Color(0xff7b6bff), Color(0xff5756f5)],
      ),
      borderRadius: BorderRadius.circular(8),
      boxShadow: [
        BoxShadow(
          color: accent.withValues(alpha: .15),
          blurRadius: 14,
          offset: const Offset(0, 3),
        ),
      ],
    ),
    child: TextButton(
      key: const Key('new-note-button'),
      onPressed: _busy ? null : () => _runFromDrawer(mobile, () => _newNote()),
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
      ),
      child: Row(
        children: [
          const Icon(Icons.add, color: Colors.white, size: 19),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              tr('Nowa notatka', 'New note'),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const Text(
            'Ctrl + N',
            style: TextStyle(fontSize: 9, color: Color(0xffdbd6ff)),
          ),
        ],
      ),
    ),
  );

  Widget _nav(IconData icon, String label, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14),
    child: TextButton(
      key: const Key('new-journal-entry'),
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: const Color(0xffc2c8df),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
        alignment: Alignment.centerLeft,
      ),
      child: Row(
        children: [
          Icon(icon, size: 19),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    ),
  );
  Widget _dragFeedback(
    String label,
    IconData icon,
    String tooltip, {
    Color? color,
  }) => Semantics(
    label: tooltip,
    child: Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xff282d46),
          border: Border.all(color: accent.withValues(alpha: .8)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color ?? accent),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  /// Whether [drag] may be dropped on [target] without creating a cycle.
  bool _canDropOn(_WorkspaceDrag drag, String target) {
    switch (drag) {
      case _NotesDrag():
        return true;
      case _FolderDrag(:final path):
        final destination = joinFolderPath(target, folderName(path));
        if (destination == path) return false;
        if (isSameOrDescendantPath(destination, path)) return false;
        return !folderPathCollides(destination, _allFolderPaths, ignore: path);
    }
  }

  Future<void> _acceptDrop(_WorkspaceDrag drag, String target) async {
    switch (drag) {
      case _NotesDrag(:final ids):
        final notes = [
          for (final id in ids)
            if (repo.notes[_vaultId]?[id] case final Note note) note,
        ];
        await _moveNotesTo(notes, target);
      case _FolderDrag(:final path):
        await _moveFolderTo(path, target);
    }
  }

  /// Moves a folder (with its whole subtree) under [parent].
  Future<void> _moveFolderTo(String path, String parent) => _run(() async {
    final target = joinFolderPath(parent, folderName(path));
    if (target == path) return;
    if (isSameOrDescendantPath(target, path)) {
      _notify(
        tr(
          'Nie można przenieść folderu do jego podfolderu.',
          'A folder cannot be moved into its own subfolder.',
        ),
      );
      return;
    }
    await _flush();
    await repo.renameFolder(vault!, path, target);
    if (!mounted) return;
    setState(() {
      if (_folder != null && isSameOrDescendantPath(_folder!, path)) {
        _folder = replacePathPrefix(_folder!, path, target);
      }
      _clearSelection();
    });
    _notify(
      tr(
        'Przeniesiono folder „${folderName(path)}” do „${parent.isEmpty ? 'katalogu głównego' : parent}”.',
        'Moved folder “${folderName(path)}” to “${parent.isEmpty ? 'root folder' : parent}”.',
      ),
    );
  }, onError: (error) => _notify('$error'));

  /// Edges reorder siblings; the middle retains subtree/note moves.
  Widget _folderDropTarget({required String folder, required Widget child}) {
    // The row's own box keeps a stable height for hit-testing: the insertion
    // indicator is a sibling, so it must not enlarge the measured box and shift
    // the quarter thresholds mid-drag.
    final rowKey = _folderRowKeys.putIfAbsent(folder, () => GlobalKey());
    return Builder(
      builder: (rowContext) {
        bool? placement(_WorkspaceDrag drag, Offset global) {
          if (drag is! _FolderDrag ||
              folder.isEmpty ||
              folderParent(drag.path) != folderParent(folder)) {
            return null;
          }
          final render = rowKey.currentContext?.findRenderObject();
          if (render is! RenderBox || !render.attached) return null;
          final y = render.globalToLocal(global).dy;
          if (y < render.size.height * .25) return false;
          if (y > render.size.height * .75) return true;
          return null;
        }

        bool allowed(_WorkspaceDrag drag, Offset global) {
          if (!unlocked || _busy) return false;
          final edge = placement(drag, global);
          if (edge != null && drag is _FolderDrag) return drag.path != folder;
          return _canDropOn(drag, folder);
        }

        bool? hoverEdge;
        return StatefulBuilder(
          builder: (context, updateTarget) => DragTarget<_WorkspaceDrag>(
            onWillAcceptWithDetails: (details) =>
                allowed(details.data, details.offset),
            onMove: (details) {
              final next = placement(details.data, details.offset);
              if (next != hoverEdge) updateTarget(() => hoverEdge = next);
            },
            onLeave: (_) => hoverEdge = null,
            onAcceptWithDetails: (details) {
              if (!allowed(details.data, details.offset)) return;
              final edge = placement(details.data, details.offset);
              final drag = details.data;
              if (edge != null && drag is _FolderDrag) {
                final activeVault = vault;
                if (activeVault == null) return;
                unawaited(
                  _run(() async {
                    await repo.reorderFolder(
                      activeVault,
                      drag.path,
                      folder,
                      after: edge,
                    );
                    if (mounted) setState(() {});
                  }),
                );
              } else {
                unawaited(_acceptDrop(drag, folder));
              }
            },
            builder: (context, candidate, rejected) {
              final active = candidate.isNotEmpty;
              final invalid = rejected.isNotEmpty;
              final showTop = active && hoverEdge == false;
              final showBottom = active && hoverEdge == true;
              // The middle keeps the existing move-into-folder highlight; the
              // top/bottom quarters insert a real, space-taking slot instead
              // of just overpainting a thin border.
              final highlight = active && hoverEdge == null;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (showTop) const _FolderDropIndicator(),
                  Container(
                    key: rowKey,
                    decoration: BoxDecoration(
                      color: highlight
                          ? accent.withValues(alpha: .18)
                          : invalid
                          ? Colors.redAccent.withValues(alpha: .12)
                          : null,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    // The highlight border is painted on top so it never reserves
                    // an extra pixel of layout: the compact tree measures a fixed
                    // 4 px gap between rows, and a layout-taking border would
                    // skew those exact measurements.
                    foregroundDecoration: BoxDecoration(
                      border: Border.all(
                        color: highlight
                            ? accent
                            : invalid
                            ? Colors.redAccent.withValues(alpha: .55)
                            : Colors.transparent,
                      ),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: child,
                  ),
                  if (showBottom) const _FolderDropIndicator(),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _editTags() => _run(() async {
    await _flush();
    if (!mounted || _selected == null) return;
    final value = await askText(
      context,
      '',
      titleBuilder: () => tr('Tagi notatki', 'Note tags'),
      initial: _selected!.tags.map((tag) => '#$tag').join(' '),
      hintBuilder: () => tr('#planowanie #praca', '#planning #work'),
    );
    if (value == null) return;
    final tags = value
        .split(RegExp(r'[\s,]+'))
        .map((s) => s.replaceFirst(RegExp(r'^#+'), ''))
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
    if (tags.length > 20 ||
        tags.any(
          (tag) =>
              tag.length > 40 ||
              !RegExp(r'^[\p{L}\p{N}_-]+$', unicode: true).hasMatch(tag),
        )) {
      throw FormatException(
        tr(
          'Użyj maksymalnie 20 tagów: liter, cyfr, podkreśleń i myślników.',
          'Use up to 20 tags containing letters, numbers, underscores and hyphens.',
        ),
      );
    }
    final changed = _selected!.copyWith(tags: tags);
    await repo.save(changed);
    if (mounted) setState(() => _selected = changed);
  });
  Widget _folderRow(
    String name,
    IconData icon, {
    int depth = 0,
    bool hasChildren = false,
    bool expanded = true,
    VoidCallback? onToggle,
    String? toggleKey,
    bool selected = false,
    required VoidCallback onTap,
    String? folderPath,
    bool draggable = false,
    bool longPressDrag = false,
  }) {
    final row = Padding(
      padding: EdgeInsets.only(left: (depth * 14).clamp(0, 70).toDouble()),
      child: Material(
        key: folderPath == null ? null : Key('folder-row-$folderPath'),
        color: selected ? accent.withValues(alpha: .10) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          onSecondaryTapDown: folderPath == null
              ? null
              : (d) => _folderMenu(folderPath, d.globalPosition),
          onLongPress: folderPath == null || longPressDrag
              ? null
              : () => _folderMenu(folderPath, null),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              children: [
                if (hasChildren)
                  InkWell(
                    key: toggleKey != null
                        ? Key(toggleKey)
                        : Key('folder-toggle-$folderPath'),
                    borderRadius: BorderRadius.circular(4),
                    onTap: onToggle,
                    child: Tooltip(
                      message: expanded
                          ? tr('Zwiń folder', 'Collapse folder')
                          : tr('Rozwiń folder', 'Expand folder'),
                      child: Icon(
                        expanded
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_right,
                        size: 16,
                        color: muted,
                      ),
                    ),
                  )
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 4),
                Icon(
                  icon,
                  size: 16,
                  key: folderPath == null
                      ? null
                      : Key('folder-icon-$folderPath'),
                  // A saved accent tints only the glyph; the row background
                  // and label keep the shared sidebar presentation.
                  color:
                      (folderPath == null
                          ? null
                          : _folderColorOf(folderPath)) ??
                      (icon == Icons.folder_outlined
                          ? const Color(0xff8fa6de)
                          : muted),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    name,
                    style: TextStyle(
                      fontSize: 12,
                      color: selected ? Colors.white : const Color(0xffc0c7df),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (folderPath != null)
                  Builder(
                    builder: (buttonContext) => InkWell(
                      key: Key('folder-menu-$folderPath'),
                      borderRadius: BorderRadius.circular(4),
                      onTap: () {
                        final button =
                            buttonContext.findRenderObject() as RenderBox;
                        _folderMenu(
                          folderPath,
                          button.localToGlobal(Offset(0, button.size.height)),
                        );
                      },
                      child: Tooltip(
                        message: tr('Opcje folderu', 'Folder options'),
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(Icons.more_horiz, size: 15, color: muted),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!draggable || folderPath == null) return row;
    final feedback = _dragFeedback(
      folderName(folderPath),
      Icons.folder_outlined,
      tr('Przenieś folder', 'Move folder'),
      color: _folderColorOf(folderPath),
    );
    // A long press starts the drag on touch devices so the list still scrolls;
    // the row's menu stays reachable through the ⋮ button.
    // A short hold starts the drag on desktop too. Flutter's immediate
    // `Draggable` wins the gesture arena on the first pixel of pointer
    // movement, so a click that jitters by a sub-pixel never reaches the row's
    // `InkWell` — reported by the owner as "opening a folder needs two clicks"
    // while the editor holds keyboard focus. Holding 150 ms still drags the
    // row as before; touch keeps the long press so the list can scroll.
    return LongPressDraggable<_WorkspaceDrag>(
      data: _FolderDrag(folderPath),
      // DragTargetDetails.offset is the feedback origin, not the pointer.
      // Pin that origin to the pointer for accurate before/after hit testing.
      delay: longPressDrag ? kLongPressTimeout : _desktopDragHold,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: feedback,
      childWhenDragging: Opacity(opacity: .35, child: row),
      child: row,
    );
  }

  Widget _vaultChooser() => Container(
    height: 36,
    padding: const EdgeInsets.only(left: 10),
    decoration: BoxDecoration(
      color: panel,
      border: Border.all(color: line),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        Icon(
          vault?.protected == true ? Icons.lock_outline : Icons.folder_outlined,
          size: 17,
          color: accent,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SiliqueChoice<String?>(
            value: _vaultId,
            style: const TextStyle(
              fontSize: 11,
              color: Colors.white,
              fontFamily: 'Inter',
            ),
            items: [
              for (final v in repo.vaults)
                SiliqueChoiceItem(
                  value: v.id,
                  icon: v.protected
                      ? Icons.lock_outline
                      : Icons.folder_outlined,
                  child: Text(
                    v.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              SiliqueChoiceItem(
                value: 'manage',
                icon: Icons.settings_outlined,
                separatorBefore: true,
                child: Text(tr('Zarządzaj vaultami', 'Manage vaults')),
              ),
              SiliqueChoiceItem(
                value: 'new',
                icon: Icons.create_new_folder_outlined,
                child: Text(tr('+ Nowy vault', '+ New vault')),
              ),
            ],
            onChanged: (id) {
              if (id == 'manage') {
                unawaited(_manageVaults());
              } else if (id == 'new') {
                unawaited(_run(_createVault));
              } else if (id != null) {
                unawaited(_switch(id));
              }
            },
          ),
        ),
      ],
    ),
  );

  /// The notes search field, shared by the classic notes list and the compact
  /// sidebar tree (which renders it above the merged list). Exactly one of
  /// the two hosts is on screen at a time, so the shared focus node and the
  /// `note-search-field` key stay unambiguous.
  Widget _searchField(bool mobile) => Padding(
    key: const Key('note-search-field'),
    padding: EdgeInsets.fromLTRB(
      mobile ? 16 : 13,
      mobile ? 8 : 12,
      mobile ? 16 : 13,
      10,
    ),
    child: TextField(
      contextMenuBuilder: siliqueTextContextMenu,
      controller: _search,
      autocorrect: !_inHidden,
      enableSuggestions: !_inHidden,
      enableIMEPersonalizedLearning: !_inHidden,
      focusNode: _searchFocus,
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => _searchFocus.unfocus(),
      style: const TextStyle(fontSize: 12),
      decoration: InputDecoration(
        hintText: tr(
          'Szukaj w nazwach i treści…',
          'Search titles and content…',
        ),
        prefixIcon: const Icon(Icons.search, size: 18),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                onPressed: _search.clear,
                icon: const Icon(Icons.close, size: 15),
              ),
        contentPadding: const EdgeInsets.symmetric(vertical: 11),
        isDense: true,
      ),
    ),
  );

  /// The compact hierarchical list: the folder tree with every visible note
  /// rendered directly under its own folder, and folder-less notes at the
  /// root level. Folder rows keep their colors, chevrons, menus and drop
  /// targets; tapping a folder collapses or expands its subtree, tapping a
  /// note opens it. While searching, collapsed state is ignored and folders
  /// without a match in their subtree are pruned.
  Widget _compactTreeList(bool mobile) {
    final searching = _query.trim().isNotEmpty;
    final notesByFolder = <String, List<Note>>{};
    for (final note in filtered) {
      notesByFolder.putIfAbsent(note.folder.trim(), () => []).add(note);
    }
    final rootHasNotes = (notesByFolder[''] ?? const <Note>[]).isNotEmpty;
    var entries = searching
        ? repo.folderRowsOf(_vaultId ?? '')
        : _compactFolderRows();
    if (searching) {
      entries = entries
          .where(
            (entry) => notesByFolder.keys.any(
              (folder) =>
                  folder == entry.path || folder.startsWith('${entry.path}/'),
            ),
          )
          .toList();
    }
    Widget noteRow(Note note, int depth) => Padding(
      padding: EdgeInsets.only(
        top: 4,
        left: 20 + (depth * 14).clamp(0, 70).toDouble(),
      ),
      child: _noteCard(
        note,
        mobile,
        compact: true,
        // In the mobile drawer a note tap must also dismiss the drawer, the
        // same way folder taps already do there.
        onTap: mobile
            ? () {
                Navigator.pop(context);
                _handleNoteTap(note);
              }
            : null,
      ),
    );
    final rootExpanded = searching || _compactRootExpanded;
    return ListView(
      key: const Key('compact-tree-list'),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      children: [
        _folderDropTarget(
          folder: '',
          child: _folderRow(
            tr('Wszystkie notatki', 'All notes'),
            Icons.notes_outlined,
            selected: true,
            hasChildren: rootHasNotes || entries.isNotEmpty,
            expanded: rootExpanded,
            toggleKey: 'compact-root-toggle',
            onToggle: () =>
                setState(() => _compactRootExpanded = !_compactRootExpanded),
            onTap: () =>
                setState(() => _compactRootExpanded = !_compactRootExpanded),
          ),
        ),
        if (rootExpanded)
          for (final note in notesByFolder[''] ?? const <Note>[])
            noteRow(note, 0),
        for (final entry in entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _folderDropTarget(
              folder: entry.path,
              child: _folderRow(
                entry.name,
                entry.path == 'Dziennik'
                    ? Icons.calendar_month_outlined
                    : Icons.folder_outlined,
                depth: entry.depth,
                hasChildren:
                    entry.hasChildren ||
                    (notesByFolder[entry.path]?.isNotEmpty ?? false),
                expanded: searching || _compactExpanded.contains(entry.path),
                onToggle: () => setState(() {
                  if (!_compactExpanded.remove(entry.path)) {
                    _compactExpanded.add(entry.path);
                  }
                }),
                selected: _folder == entry.path,
                folderPath: entry.path,
                draggable: unlocked,
                longPressDrag: mobile,
                // Compact folders never become the panel filter; the tap only
                // collapses or expands the subtree (chevron semantics).
                onTap: () => setState(() {
                  if (!_compactExpanded.remove(entry.path)) {
                    _compactExpanded.add(entry.path);
                  }
                }),
              ),
            ),
          ),
          if (searching || _compactExpanded.contains(entry.path))
            for (final note in notesByFolder[entry.path] ?? const <Note>[])
              noteRow(note, entry.depth + 1),
        ],
        if (searching && filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Icon(Icons.search_off, size: 38, color: muted),
                const SizedBox(height: 12),
                Text(
                  tr('Nie znaleziono notatek', 'No notes found'),
                  style: const TextStyle(color: muted),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _noteList(bool mobile) {
    final list = filtered;
    final searching = mobile && MediaQuery.viewInsetsOf(context).bottom > 0;
    return Container(
      color: sidebar.withValues(alpha: .25),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (mobile && !searching) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 8, 6),
              child: Row(
                children: [
                  const SiliqueMark(size: 28),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text('SILIQUE', style: TextStyle(fontSize: 15)),
                  ),
                  IconButton(
                    onPressed: () => _scaffold.currentState?.openDrawer(),
                    icon: const Icon(Icons.menu),
                    tooltip: tr('Foldery i vaulty', 'Folders and vaults'),
                  ),
                  IconButton(
                    onPressed: _settings,
                    icon: const Icon(Icons.more_vert),
                    tooltip: tr('Ustawienia', 'Settings'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Text(
                _inHidden
                    ? _filterLabel('Ukryte')
                    : tr('Moje notatki', 'My notes'),
                style: TextStyle(fontSize: 25, fontWeight: FontWeight.w600),
              ),
            ),
          ],
          if (!mobile && !_compactTree)
            Row(
              children: [
                Expanded(child: _searchField(mobile)),
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: IconButton(
                    key: const Key('sidebar-toggle-notes-list'),
                    tooltip: _notesCollapsed
                        ? tr('Pokaż listę notatek', 'Show notes list')
                        : tr('Zwiń listę notatek', 'Collapse notes list'),
                    icon: Icon(
                      _notesCollapsed
                          ? Icons.keyboard_double_arrow_right
                          : Icons.keyboard_double_arrow_left,
                      size: 17,
                    ),
                    onPressed: () =>
                        setState(() => _notesCollapsed = !_notesCollapsed),
                  ),
                ),
              ],
            )
          else
            _searchField(mobile),
          if (_inHidden)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tr('Zaszyfrowane end-to-end', 'End-to-end encrypted'),
                      style: TextStyle(fontSize: 11, color: muted),
                    ),
                  ),
                  IconButton(
                    key: const Key('hidden-lock-now'),
                    tooltip: tr('Zablokuj teraz', 'Lock now'),
                    onPressed: _hiddenAvailable ? _lockHiddenFolder : null,
                    icon: const Icon(Icons.lock_outline, size: 18),
                  ),
                ],
              ),
            ),
          if (!_inHidden)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final f
                              in mobile
                                  ? ['Ostatnie', 'Ulubione', 'Dziennik']
                                  : ['Wszystkie', 'Ostatnie', 'Ulubione'])
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(18),
                                onTap: () => _filterBy(f),
                                child: Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: mobile ? 12 : 10,
                                    vertical: 7,
                                  ),
                                  decoration: BoxDecoration(
                                    color:
                                        (_filter == f ||
                                            mobile &&
                                                _filter == 'Wszystkie' &&
                                                f == 'Ostatnie')
                                        ? const Color(0xff28284c)
                                        : Colors.transparent,
                                    border: Border.all(
                                      color:
                                          (_filter == f ||
                                              mobile &&
                                                  _filter == 'Wszystkie' &&
                                                  f == 'Ostatnie')
                                          ? accent.withValues(alpha: .55)
                                          : line.withValues(alpha: .5),
                                    ),
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                  child: Text(
                                    _filterLabel(f),
                                    style: TextStyle(
                                      fontSize: 10,
                                      color:
                                          (_filter == f ||
                                              mobile &&
                                                  _filter == 'Wszystkie' &&
                                                  f == 'Ostatnie')
                                          ? Colors.white
                                          : muted,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('select-mode'),
                    tooltip: _selecting
                        ? tr('Zakończ zaznaczanie', 'Finish selecting')
                        : tr('Zaznacz wiele notatek', 'Select multiple notes'),
                    icon: Icon(
                      _selecting
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 17,
                      color: _selecting ? accent : null,
                    ),
                    onPressed: () => setState(() {
                      if (_selecting) {
                        _clearSelection();
                      } else {
                        _selecting = true;
                      }
                    }),
                  ),
                  PopupMenuButton<String>(
                    tooltip: tr('Sortowanie notatek', 'Sort notes'),
                    icon: const Icon(Icons.tune, size: 17),
                    onSelected: (value) => setState(() => _sort = value),
                    itemBuilder: (ctx) {
                      Localizations.localeOf(ctx);
                      return [
                        SiliquePopupItem(
                          value: 'updated',
                          selected: _sort == 'updated',
                          child: Text(
                            tr('Według ostatniej zmiany', 'Last modified'),
                          ),
                        ),
                        SiliquePopupItem(
                          value: 'title',
                          selected: _sort == 'title',
                          child: Text(tr('Według nazwy', 'Name')),
                        ),
                        SiliquePopupItem(
                          value: 'created-asc',
                          selected: _sort == 'created-asc',
                          child: Text(
                            tr(
                              'Data utworzenia: od najstarszych',
                              'Created: oldest first',
                            ),
                          ),
                        ),
                        SiliquePopupItem(
                          value: 'created-desc',
                          selected: _sort == 'created-desc',
                          child: Text(
                            tr(
                              'Data utworzenia: od najnowszych',
                              'Created: newest first',
                            ),
                          ),
                        ),
                      ];
                    },
                  ),
                ],
              ),
            ),
          if (_selecting)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextButton.icon(
                key: const Key('select-all'),
                icon: Icon(
                  list.isNotEmpty &&
                          list.every((n) => _selection.contains(n.id))
                      ? Icons.deselect
                      : Icons.select_all,
                  size: 18,
                ),
                label: Text(
                  list.isNotEmpty &&
                          list.every((n) => _selection.contains(n.id))
                      ? tr('Odznacz wszystko', 'Deselect all')
                      : tr('Zaznacz wszystko', 'Select all'),
                ),
                onPressed: list.isEmpty
                    ? null
                    : () => setState(() {
                        final all = list.every(
                          (n) => _selection.contains(n.id),
                        );
                        _selection.clear();
                        if (!all) _selection.addAll(list.map((n) => n.id));
                        _selectionAnchor = _selection.firstOrNull;
                      }),
              ),
            ),
          if (_hasSelection) _selectionBar(mobile),
          if (_folder != null || _filter == 'Kosz')
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _folder ?? tr('Usunięte', 'Deleted'),
                      style: const TextStyle(color: accent, fontSize: 11),
                    ),
                  ),
                  IconButton(
                    onPressed: () => _filterBy('Wszystkie'),
                    icon: const Icon(Icons.close, size: 14),
                    tooltip: tr('Wszystkie notatki', 'All notes'),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: !unlocked
                ? _lockedView()
                : _inHidden && !_hiddenAvailable
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          tr(
                            'Ukryte notatki są zablokowane.',
                            'Hidden notes are locked.',
                          ),
                        ),
                        TextButton(
                          onPressed: _openHidden,
                          child: Text(tr('Odblokuj', 'Unlock')),
                        ),
                      ],
                    ),
                  )
                : list.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _query.isEmpty ? Icons.edit_note : Icons.search_off,
                            size: 38,
                            color: muted,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _query.isEmpty
                                ? tr(
                                    'Miejsce na Twoje myśli',
                                    'Room for your thoughts',
                                  )
                                : tr(
                                    'Nie znaleziono notatek',
                                    'No notes found',
                                  ),
                            style: const TextStyle(color: muted),
                          ),
                          const SizedBox(height: 12),
                          if (_query.isEmpty)
                            TextButton(
                              onPressed: () => _newNote(),
                              child: Text(
                                tr(
                                  'Napisz pierwszą notatkę',
                                  'Write your first note',
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: EdgeInsets.symmetric(
                      horizontal: mobile ? 9 : 10,
                      vertical: 8,
                    ),
                    itemCount: list.length,
                    itemBuilder: (ctx, index) {
                      Localizations.localeOf(ctx);
                      final note = list[index];
                      final header = index == 0
                          ? (note.favorite
                                ? tr('Przypięte', 'Pinned')
                                : tr('Notatki', 'Notes'))
                          : list[index - 1].favorite && !note.favorite
                          ? tr('Pozostałe', 'Other notes')
                          : null;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (header != null && !mobile)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(6, 5, 6, 8),
                              child: Text(
                                header,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xffc6c2ff),
                                ),
                              ),
                            ),
                          _noteCard(note, mobile),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _noteCard(
    Note note,
    bool mobile, {
    VoidCallback? onTap,
    bool compact = false,
  }) {
    final selected = note.id == _selected?.id && !mobile;
    final marked = _selection.contains(note.id);
    // The icon color is the note's explicit color if set, otherwise the vault's
    // default (a single value shared by ordinary and journal notes). Conflict is
    // a state, not a preference: the warning icon keeps its own color.
    final noteColorValue = repo.noteColorsOf(note.vaultId)[note.id];
    final color = noteColorValue != null
        ? Color(noteColorValue)
        : Color(repo.defaultNoteColorOf(note.vaultId));
    const conflictColor = Colors.orangeAccent;
    final card = Padding(
      padding: EdgeInsets.only(bottom: compact ? 0 : 2),
      child: Material(
        color: marked
            ? accent.withValues(alpha: .16)
            : compact
            ? (selected ? accent.withValues(alpha: .10) : Colors.transparent)
            : selected
            ? const Color(0xff252944)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(compact ? 6 : 7),
        child: InkWell(
          borderRadius: BorderRadius.circular(compact ? 6 : 7),
          onSecondaryTapDown: (details) =>
              _noteMenu(note, details.globalPosition),
          onLongPress: () => _noteMenu(note, null),
          onTap: onTap ?? () => _handleNoteTap(note),
          child: Container(
            key: Key('note-card-${note.id}'),
            decoration: BoxDecoration(
              border: Border.all(
                color: marked
                    ? accent
                    : compact
                    ? Colors.transparent
                    : selected
                    ? accent.withValues(alpha: .85)
                    : Colors.transparent,
              ),
              borderRadius: BorderRadius.circular(compact ? 6 : 7),
            ),
            padding: compact
                ? const EdgeInsets.symmetric(horizontal: 4, vertical: 8)
                : EdgeInsets.symmetric(
                    horizontal: mobile ? 8 : 9,
                    vertical: mobile ? 10 : 11,
                  ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_selecting)
                  Padding(
                    padding: const EdgeInsets.only(right: 6, top: 4),
                    child: Icon(
                      marked
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 17,
                      color: marked ? accent : muted,
                    ),
                  ),
                if (compact)
                  Icon(
                    note.conflict
                        ? Icons.warning_amber_rounded
                        : note.journalDate != null
                        ? Icons.calendar_month
                        : Icons.description_outlined,
                    size: 16,
                    color: note.conflict ? conflictColor : color,
                  )
                else
                  Container(
                    width: mobile ? 43 : 23,
                    height: mobile ? 46 : 30,
                    decoration: mobile
                        ? BoxDecoration(
                            color: panel,
                            border: Border.all(color: line),
                            borderRadius: BorderRadius.circular(8),
                          )
                        : null,
                    child: Icon(
                      note.conflict
                          ? Icons.warning_amber_rounded
                          : note.journalDate != null
                          ? Icons.calendar_month
                          : Icons.description_outlined,
                      size: mobile ? 27 : 23,
                      color: note.conflict ? conflictColor : color,
                    ),
                  ),
                if (compact)
                  const SizedBox(width: 9)
                else
                  const SizedBox(width: 10),
                Expanded(
                  child: compact
                      ? Text(
                          note.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                            color: selected
                                ? Colors.white
                                : const Color(0xffc0c7df),
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    note.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (mobile)
                                  Text(
                                    _time(note),
                                    style: const TextStyle(
                                      fontSize: 9,
                                      color: muted,
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              _snippet(note),
                              maxLines: mobile ? 2 : 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 10,
                                color: muted,
                                height: 1.55,
                              ),
                            ),
                            if (!mobile)
                              Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Text(
                                  _time(note),
                                  style: const TextStyle(
                                    fontSize: 9,
                                    color: muted,
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
                if (note.favorite)
                  Padding(
                    padding: const EdgeInsets.only(left: 5, top: 3),
                    child: Icon(Icons.push_pin, size: 13, color: accent),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    final ids = marked && _selection.isNotEmpty
        ? _selection.toList()
        : <String>[note.id];
    final label = ids.length > 1
        ? tr('${ids.length} notatek', '${ids.length} notes')
        : note.title;
    final feedback = _dragFeedback(
      label,
      Icons.description_outlined,
      tr('Przenieś notatkę', 'Move note'),
    );
    if (note.hidden) return card;
    if (mobile) {
      if (!_selecting) return card;
      return LongPressDraggable<_WorkspaceDrag>(
        data: _NotesDrag(ids),
        feedback: feedback,
        childWhenDragging: Opacity(opacity: .35, child: card),
        child: card,
      );
    }
    // Same short hold as the folder rows: an immediate `Draggable` swallows a
    // click that moves the pointer by a fraction of a pixel.
    return LongPressDraggable<_WorkspaceDrag>(
      data: _NotesDrag(ids),
      delay: _desktopDragHold,
      feedback: feedback,
      childWhenDragging: Opacity(opacity: .35, child: card),
      child: card,
    );
  }

  /// The `select-all` button in the compact sidebar, matching the classic
  /// notes-list button so the shared `select-all` key behaves identically.
  Widget _compactSelectAll() {
    final list = filtered;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: TextButton.icon(
        key: const Key('select-all'),
        icon: Icon(
          list.isNotEmpty && list.every((n) => _selection.contains(n.id))
              ? Icons.deselect
              : Icons.select_all,
          size: 18,
        ),
        label: Text(
          list.isNotEmpty && list.every((n) => _selection.contains(n.id))
              ? tr('Odznacz wszystko', 'Deselect all')
              : tr('Zaznacz wszystko', 'Select all'),
        ),
        onPressed: list.isEmpty
            ? null
            : () => setState(() {
                final all = list.every((n) => _selection.contains(n.id));
                _selection.clear();
                if (!all) _selection.addAll(list.map((n) => n.id));
                _selectionAnchor = _selection.firstOrNull;
              }),
      ),
    );
  }

  /// Bulk action bar shown while at least one note is selected.
  Widget _selectionBar(bool mobile) {
    final inTrash = _filter == 'Kosz';
    final count = _selection.length;
    return Container(
      key: const Key('selection-bar'),
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: .12),
        border: Border.all(color: accent.withValues(alpha: .5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.checklist, size: 15, color: accent),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  tr('Zaznaczono $count', '$count selected'),
                  key: const Key('selection-count'),
                  style: const TextStyle(fontSize: 11, color: Colors.white),
                ),
              ),
              IconButton(
                key: const Key('bulk-clear'),
                tooltip: tr(
                  'Anuluj zaznaczanie (Esc)',
                  'Cancel selection (Esc)',
                ),
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(_clearSelection),
                icon: const Icon(Icons.close, size: 15),
              ),
            ],
          ),
          Wrap(
            spacing: 2,
            runSpacing: 2,
            children: [
              _bulkAction(
                'bulk-move',
                Icons.drive_file_move_outline,
                tr('Przenieś', 'Move'),
                _bulkMove,
              ),
              _bulkAction(
                'bulk-pin',
                Icons.push_pin_outlined,
                tr('Przypnij / odepnij', 'Pin / unpin'),
                _bulkFavorite,
              ),
              if (inTrash)
                _bulkAction(
                  'bulk-restore',
                  Icons.restore,
                  tr('Przywróć', 'Restore'),
                  () => _bulkTrash(restore: true),
                )
              else
                _bulkAction(
                  'bulk-trash',
                  Icons.delete_outline,
                  tr('Do kosza', 'Trash'),
                  () => _bulkTrash(restore: false),
                ),
              if (inTrash)
                _bulkAction(
                  'bulk-purge',
                  Icons.delete_forever,
                  tr('Usuń trwale', 'Delete permanently'),
                  _bulkPurge,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bulkAction(
    String key,
    IconData icon,
    String label,
    Future<void> Function() action,
  ) => TextButton.icon(
    key: Key(key),
    onPressed: _busy ? null : () => unawaited(action()),
    style: TextButton.styleFrom(
      minimumSize: const Size(0, 30),
      padding: const EdgeInsets.symmetric(horizontal: 7),
      foregroundColor: const Color(0xffdfe3f5),
      visualDensity: VisualDensity.compact,
    ),
    icon: Icon(icon, size: 15),
    label: Text(label, style: const TextStyle(fontSize: 10)),
  );

  Widget _lockedView() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline, size: 42, color: accent),
          const SizedBox(height: 16),
          Text(
            tr('Ten vault jest chroniony', 'This vault is protected'),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          Text(
            tr(
              'Podaj dodatkowe hasło, aby otworzyć notatki.',
              'Enter the additional password to open your notes.',
            ),
            textAlign: TextAlign.center,
            style: TextStyle(color: muted, fontSize: 12),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : () => _run(() => _unlock()),
            child: Text(tr('Odblokuj', 'Unlock')),
          ),
          TextButton(
            onPressed: _busy ? null : () => _run(() => _unlock(recovery: true)),
            child: Text(tr('Użyj klucza odzyskiwania', 'Use recovery key')),
          ),
        ],
      ),
    ),
  );

  /// Icon-only synchronization indicator: a green spinner while a sync is
  /// running or a local change is pending, a green check once the last pass
  /// succeeded, an orange cloud-off only for a genuine failed attempt, and a
  /// muted outline when idle (also the only state a local vault ever shows).
  /// The readable state lives in the hover tooltip.
  Widget _syncBadge({bool small = false}) {
    final localOnly = vault?.syncEnabled != true;
    // A failed attempt covers a save error and an offline sync failure.
    final failed = _status.startsWith('Błąd') || _status.startsWith('Offline');
    final synced = _status.startsWith('Zsynchronizowano');
    // Local changes waiting to go out: an edit that has not reached the
    // debounced save yet (_dirty), or a save whose sync pass is still pending.
    final pending =
        !localOnly &&
        (_dirty || _status == 'Zapisano lokalnie • oczekuje na synchronizację');
    final syncing = !localOnly && _syncing;
    // A local-only vault never exchanges content, so an offline status is not a
    // connection loss — only a save error overrides its "Local" tooltip.
    final label = localOnly
        ? (_status.startsWith('Błąd') ? _statusLabel : tr('Lokalnie', 'Local'))
        : _syncing
        ? tr('Synchronizacja…', 'Syncing…')
        : _statusLabel;
    final size = small ? 13.0 : 17.0;

    // State → (icon, colour): a spinner for in-flight work and pending local
    // changes, a green check once the last pass succeeded, orange cloud-off
    // only for a genuine failed attempt, and a muted outline when idle — which
    // is also the only state a local (sync-disabled) vault may ever show.
    final Widget indicator;
    if (syncing || pending) {
      indicator = SizedBox(
        width: size,
        height: size,
        child: const CircularProgressIndicator(strokeWidth: 2, color: syncOn),
      );
    } else if (!localOnly && failed) {
      indicator = Icon(Icons.cloud_off, size: size, color: syncOff);
    } else if (!localOnly && synced) {
      indicator = Icon(Icons.cloud_done_outlined, size: size, color: syncOn);
    } else {
      indicator = Icon(Icons.cloud_outlined, size: size, color: muted);
    }

    return Tooltip(
      key: const Key('sync-status'),
      message: label,
      child: InkWell(
        onTap: vault?.syncEnabled == true ? () => _sync() : null,
        borderRadius: BorderRadius.circular(8),
        child: Padding(padding: const EdgeInsets.all(3), child: indicator),
      ),
    );
  }

  Widget _breadcrumbs(bool mobile) {
    final note = _noteById(_selected?.id) ?? _selected!;
    final parts = (_inHidden ? _filterLabel('Ukryte') : note.folder)
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    return Padding(
      key: const Key('note-breadcrumbs'),
      padding: EdgeInsets.fromLTRB(mobile ? 16 : 26, 4, 12, 0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            const Icon(Icons.folder_outlined, size: 14, color: muted),
            TextButton(
              onPressed: () => _filterBy('Wszystkie'),
              child: Text(
                vault?.name ?? tr('Notatki', 'Notes'),
                style: const TextStyle(fontSize: 11),
              ),
            ),
            for (var i = 0; i < parts.length; i++) ...[
              const Icon(Icons.chevron_right, size: 14, color: muted),
              TextButton(
                onPressed: () => _inHidden
                    ? _returnToList()
                    : _filterBy(
                        'Wszystkie',
                        folder: parts.take(i + 1).join('/'),
                      ),
                child: Text(parts[i], style: const TextStyle(fontSize: 11)),
              ),
            ],
            if (parts.isEmpty)
              Text(
                tr(' / Katalog główny', ' / Root folder'),
                style: TextStyle(fontSize: 11, color: muted),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickEmoji() async {
    final controller = _editor;
    final selection = controller.selection;
    const emojis = [
      '😀',
      '😊',
      '😂',
      '🥰',
      '😍',
      '😎',
      '🤔',
      '😅',
      '😢',
      '😭',
      '😡',
      '🥳',
      '👍',
      '👎',
      '👏',
      '🙌',
      '🙏',
      '💪',
      '👋',
      '👌',
      '❤️',
      '💜',
      '💚',
      '💛',
      '🔥',
      '✨',
      '🎉',
      '🎯',
      '✅',
      '❌',
      '⭐',
      '💡',
      '📝',
      '📌',
      '📁',
      '📅',
      '🚀',
      '🌍',
      '☀️',
      '🌙',
      '🌱',
      '☕',
      '🎵',
      '🏠',
      '👩‍💻',
      '🧑‍🤝‍🧑',
      '🇵🇱',
      '👍🏽',
    ];
    final emoji = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: menuGraphite,
      shape: menuShape,
      elevation: 8,
      builder: (context) {
        Localizations.localeOf(context);
        return SafeArea(
          child: SizedBox(
            height: 300,
            child: Column(
              children: [
                Text(
                  tr('Emotki', 'Emoji'),
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 56,
                        ),
                    itemCount: emojis.length,
                    itemBuilder: (context, i) => InkWell(
                      borderRadius: BorderRadius.circular(12),
                      hoverColor: menuHover,
                      focusColor: menuHover,
                      onTap: () => Navigator.pop(context, emojis[i]),
                      child: Center(
                        child: Text(
                          emojis[i],
                          style: const TextStyle(
                            fontSize: 26,
                            fontFamilyFallback: [
                              'Apple Color Emoji',
                              'Noto Color Emoji',
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || emoji == null || !identical(controller, _editor)) return;
    final start = selection.isValid ? selection.start : controller.text.length;
    final end = selection.isValid ? selection.end : start;
    controller.replaceRange(
      start,
      end,
      emoji,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
  }

  Widget _sourceBody(
    ScrollController? scrollController, {
    bool expands = true,
  }) => Padding(
    key: _sourceViewport,
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: _menuPresentation(
      MarkdownPasteScope(
        controller: _editor,
        configuration: _pasteConfiguration(),
        child: Builder(
          builder: (context) => MarkdownPasteRegion(
            toDocumentOffset: (offset) => offset,
            field: TextField(
              key: const Key('source-editor'),
              focusNode: _sourceFocus,
              readOnly: _editorReadOnly,
              autocorrect: !_inHidden,
              enableSuggestions: !_inHidden,
              enableIMEPersonalizedLearning: !_inHidden,
              selectionControls: TextSelectionEdgeAutoScroll.controlsOf(
                context,
              ),
              scrollController: scrollController,
              keyboardType: TextInputType.multiline,
              scrollPadding: const EdgeInsets.all(40),
              controller: _sourceController(),
              contentInsertionConfiguration:
                  markdownContentInsertionConfiguration(
                    context,
                    _sourceController(),
                  ),
              contextMenuBuilder: markdownPasteContextMenu,
              maxLines: null,
              expands: expands,
              scrollPhysics: expands
                  ? null
                  : const NeverScrollableScrollPhysics(),
              style: TextStyle(
                fontFamily: kMonoFontFamily,
                fontFamilyFallback: const ['monospace'],
                fontSize: _fontSize,
                height: 1.7,
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _menuPresentation(Widget child) => MarkdownMenuPresentation(
    selectionToolbarBuilder: siliqueSelectionToolbar,
    menuEntryBuilder: (context, value, label, icon, enabled) =>
        SiliquePopupItem<Object>(
          value: value,
          enabled: enabled,
          icon: icon,
          child: Text(label),
        ),
    child: child,
  );

  LiveMarkdownPasteConfiguration? _pasteConfiguration() {
    final editor = _editor;
    final note = _selected;
    final hidden = _inHidden;
    final epoch = _hiddenEpoch;
    if (note == null ||
        note.deleted ||
        !unlocked ||
        (hidden && !_hiddenAvailable)) {
      return null;
    }
    bool current() =>
        mounted &&
        identical(_editor, editor) &&
        _selected?.id == note.id &&
        _vaultId == note.vaultId &&
        unlocked &&
        _inHidden == hidden &&
        !_editorReadOnly &&
        (!hidden || (_hiddenAvailable && _hiddenEpoch == epoch));
    return LiveMarkdownPasteConfiguration(
      clipboard: const NativeImageClipboard(),
      allowedMimeTypes: NativeImageClipboard.mimeTypes,
      contentInsertionMimeTypes: NativeImageClipboard.mimeTypes,
      maxItems: 4,
      maxConcurrentImports: 1,
      onImportMedia: (request) => importClipboardImage(
        request,
        isCurrent: current,
        saveImage: hidden
            ? null
            : (bytes, mime) => repo.addImage(
                note.vaultId,
                note.id,
                bytes,
                mime,
                isCurrent: () => current() && !request.cancellation.isCancelled,
              ),
      ),
    );
  }

  Widget _noteBody(bool mobile, ScrollController? scrollController) {
    final body = _source
        ? scrollController == null
              ? _sourceBody(null)
              : TextSelectionEdgeAutoScroll(
                  controller: _sourceController(),
                  scrollController: scrollController,
                  child: _sourceBody(scrollController),
                )
        : LiveMarkdownEditor(
            key: ValueKey(_selected!.id),
            readOnly: _editorReadOnly,
            controller: _editor,
            pasteConfiguration: _pasteConfiguration(),
            // The body always lives inside the document viewport, so the
            // field sizes to its content and the viewport owns the offset.
            contentSizedField: true,
            autocorrect: !_inHidden,
            enableSuggestions: !_inHidden,
            enableIMEPersonalizedLearning: !_inHidden,
            scrollController: scrollController,
            editorDecoration: const InputDecoration(
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              contentPadding: EdgeInsets.zero,
            ),
            padding: EdgeInsets.fromLTRB(
              mobile ? 22 : 32,
              12,
              mobile ? 22 : 32,
              mobile ? 8 : 36,
            ),
            theme: LiveMarkdownThemeData(
              bodyStyle: TextStyle(
                fontSize: _fontSize,
                height: 1.5,
                leadingDistribution: TextLeadingDistribution.even,
                color: Color(0xffcdd3e8),
              ),
              h1Style: TextStyle(
                fontSize: 28,
                height: 1.4,
                leadingDistribution: TextLeadingDistribution.even,
                fontWeight: FontWeight.w700,
              ),
              h2Style: TextStyle(
                fontSize: 21,
                height: 1.6,
                leadingDistribution: TextLeadingDistribution.even,
                fontWeight: FontWeight.w600,
              ),
              h3Style: TextStyle(
                fontSize: 18,
                height: 1.5,
                leadingDistribution: TextLeadingDistribution.even,
                fontWeight: FontWeight.w600,
              ),
              linkStyle: const TextStyle(
                color: accent,
                decoration: TextDecoration.underline,
              ),
              codeStyle: const TextStyle(
                fontFamily: kMonoFontFamily,
                fontFamilyFallback: ['monospace'],
                fontSize: 13,
                backgroundColor: Color(0xff1f2739),
              ),
              codeBlockDecoration: BoxDecoration(
                color: panel,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: line),
              ),
              appearance: LiveMarkdownAppearance(
                quoteColor: accent,
                taskColor: accent,
                syntaxColor: muted,
                calloutAccentColor: accent,
              ),
            ),
            onLinkTap: (url, _) => _openLink(url),
            onWikiLinkTap: (target, _) => _wiki(target),
            imageResolver: (destination) {
              if (destination.startsWith('silique-image:')) {
                return _trackEditorImage(
                  AttachmentImage(
                    repo,
                    _vaultId!,
                    destination.substring('silique-image:'.length),
                  ),
                );
              }
              final uri = Uri.tryParse(destination);
              if (uri?.scheme == 'data' &&
                  uri?.data?.isBase64 == true &&
                  uri!.data!.mimeType.startsWith('image/')) {
                return _trackEditorImage(
                  MemoryImage(uri.data!.contentAsBytes()),
                );
              }
              return _trackEditorImage(
                MemoryImage(
                  Uint8List.fromList(
                    base64Decode(
                      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jWZkAAAAASUVORK5CYII=',
                    ),
                  ),
                ),
              );
            },
          );
    // The document viewport owns the image drop surface on every platform.
    return _menuPresentation(body);
  }

  Widget _noteHeading(bool mobile, List<String> tags) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: EdgeInsets.fromLTRB(mobile ? 22 : 32, 8, mobile ? 22 : 32, 0),
        child: Wrap(
          spacing: 16,
          runSpacing: 3,
          children: [
            Text(
              tr(
                'Utworzono: ${_timestamp(_selected!.createdAt)}',
                'Created: ${_timestamp(_selected!.createdAt)}',
              ),
              style: const TextStyle(fontSize: 10, color: muted),
            ),
            Text(
              tr(
                'Ostatnia edycja: ${_timestamp(_selected!.updatedAt)}',
                'Last edited: ${_timestamp(_selected!.updatedAt)}',
              ),
              style: const TextStyle(fontSize: 10, color: muted),
            ),
          ],
        ),
      ),
      Padding(
        padding: EdgeInsets.fromLTRB(mobile ? 22 : 32, 20, mobile ? 22 : 32, 4),
        child: Focus(
          onKeyEvent: _titleKeyEvent,
          child: TextField(
            contextMenuBuilder: siliqueTextContextMenu,
            key: const Key('note-title'),
            focusNode: _titleFocus,
            readOnly: _editorReadOnly,
            autocorrect: !_inHidden,
            enableSuggestions: !_inHidden,
            enableIMEPersonalizedLearning: !_inHidden,
            controller: _title,
            style: TextStyle(
              fontSize: mobile ? 27 : 32,
              fontWeight: FontWeight.w700,
              height: 1.3,
              letterSpacing: -.8,
            ),
            maxLines: null,
            minLines: 1,
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _focusBodyFromTitle(),
            inputFormatters: [
              FilteringTextInputFormatter.deny(
                RegExp(r'[\r\n\u0085\u2028\u2029]'),
              ),
            ],
            decoration: InputDecoration(
              hintText: tr('Bez tytułu', 'Untitled'),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      ),
      Padding(
        padding: EdgeInsets.fromLTRB(mobile ? 22 : 32, 8, 24, 8),
        child: Wrap(
          spacing: 7,
          runSpacing: 5,
          children: [
            for (final tag in tags)
              InkWell(
                onTap: () {
                  _search.text = '#$tag';
                  setState(() => _mobileEditor = false);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xff282d46),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    '#$tag',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xffc1c0ff),
                    ),
                  ),
                ),
              ),
            if (!_inHidden)
              Tooltip(
                message: tr('Edytuj tagi', 'Edit tags'),
                child: InkWell(
                  onTap: _editTags,
                  borderRadius: BorderRadius.circular(12),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.add, size: 16, color: muted),
                  ),
                ),
              ),
          ],
        ),
      ),
    ],
  );

  /// Whether the editor pane currently paints its status footer (and thus
  /// the sync indicator) for this layout: a note must be open, the vault
  /// unlocked and, on phones, the editor must be the active view.
  bool _statusFooterShown(bool mobile) =>
      _selected != null &&
      (vault == null || unlocked) &&
      (!mobile || _mobileEditor);

  Widget _editorPane(bool mobile) {
    if (vault != null && !unlocked) return _lockedView();
    if (_selected == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SiliqueMark(size: 64),
            const SizedBox(height: 24),
            Text(
              tr('Przestrzeń na dobrą myśl', 'Space for a good idea'),
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(
              tr(
                'Wybierz notatkę lub zacznij nową.',
                'Select a note or start a new one.',
              ),
              style: TextStyle(color: muted),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => _newNote(),
              icon: const Icon(Icons.add, size: 18),
              label: Text(tr('Nowa notatka', 'New note')),
            ),
          ],
        ),
      );
    }
    final tags = <String>{
      ..._selected!.tags,
      ...RegExp(
        r'(?:^|\s)#([\p{L}\p{N}_-]+)',
        unicode: true,
      ).allMatches(_editor.text).map((m) => m.group(1)!),
    }.take(8).toList();
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff171d2b), Color(0xff101622)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!mobile)
            Container(
              height: 39,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: const BoxDecoration(
                color: Color(0xff111725),
                border: Border(bottom: BorderSide(color: line)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final id in _tabs)
                            if (_noteById(id) case final Note tab)
                              Container(
                                constraints: const BoxConstraints(
                                  maxWidth: 220,
                                ),
                                margin: const EdgeInsets.only(right: 4, top: 4),
                                decoration: BoxDecoration(
                                  color: id == _selected?.id
                                      ? const Color(0xff282b47)
                                      : panel,
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(8),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: TextButton(
                                        onPressed: () => _select(tab),
                                        child: Text(
                                          tab.title,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: tr('Zamknij kartę', 'Close tab'),
                                      icon: const Icon(Icons.close, size: 14),
                                      onPressed: () => _closeTab(id),
                                    ),
                                  ],
                                ),
                              ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => _newNote(),
                    icon: const Icon(Icons.add, size: 17),
                    tooltip: tr('Nowa notatka', 'New note'),
                  ),
                  IconButton(
                    onPressed: () => setState(() => _focus = !_focus),
                    icon: Icon(
                      _focus ? Icons.fullscreen_exit : Icons.fullscreen,
                      size: 18,
                    ),
                    tooltip: tr('Tryb skupienia', 'Focus mode'),
                  ),
                ],
              ),
            ),
          _toolbar(mobile),
          _breadcrumbs(mobile),
          if (_finding)
            Container(
              key: const Key('find-bar'),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: line)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      contextMenuBuilder: siliqueTextContextMenu,
                      key: const Key('find-field'),
                      autocorrect: !_inHidden,
                      enableSuggestions: !_inHidden,
                      enableIMEPersonalizedLearning: !_inHidden,
                      controller: _find,
                      focusNode: _findFocus,
                      decoration: InputDecoration(
                        hintText: tr('Szukaj w notatce', 'Find in note'),
                        isDense: true,
                      ),
                      onChanged: (_) => _refreshFind(selectFirst: true),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _find.text.isEmpty
                        ? ''
                        : _findMatches.isEmpty
                        ? tr('Brak wyników', 'No matches')
                        : '${_matchIndex + 1} / ${_findMatches.length}',
                    key: const Key('find-count'),
                    style: TextStyle(
                      fontSize: 10,
                      color: _findMatches.isEmpty && _find.text.isNotEmpty
                          ? Colors.orangeAccent
                          : muted,
                    ),
                  ),
                  IconButton(
                    tooltip: tr('Poprzedni wynik', 'Previous match'),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _findNext(back: true),
                    icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                  ),
                  IconButton(
                    tooltip: tr('Następny wynik', 'Next match'),
                    visualDensity: VisualDensity.compact,
                    onPressed: _findNext,
                    icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                  ),
                  IconButton(
                    tooltip: tr('Zamknij wyszukiwanie', 'Close search'),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(_closeFind),
                    icon: const Icon(Icons.close, size: 16),
                  ),
                ],
              ),
            ),
          // Every platform scrolls the heading and the content as one
          // document; tabs, toolbar, breadcrumbs, find bar and the status
          // bar stay pinned outside the viewport. The wiki suggestions float
          // above that viewport next to the caret, so opening or closing the
          // panel never moves the document layout or its scroll offset.
          Expanded(
            child: Stack(
              key: _wikiStackKey,
              fit: StackFit.expand,
              children: [
                _imageDropSurface(
                  MobileNoteViewport(
                    key: ValueKey(
                      'note-scroll-${_selected!.id}-${_source ? 'source' : 'live'}',
                    ),
                    heading: _noteHeading(mobile, tags),
                    onBlankTap: _focusBodyEnd,
                    bodyBuilder: (scroll) => _source
                        ? _sourceBody(null, expands: false)
                        : _noteBody(mobile, scroll),
                    selectionController: _source ? _sourceController() : null,
                  ),
                ),
                ?_wikiSuggestionOverlay(),
              ],
            ),
          ),
          Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: line)),
            ),
            child: Row(
              children: [
                if (_selected!.conflict)
                  Text(
                    tr('Kopia konfliktowa', 'Conflict copy'),
                    style: TextStyle(color: Colors.orangeAccent, fontSize: 9),
                  ),
                // One slack absorber keeps the whole indicator cluster flush
                // with the bottom-right corner; the inner Flexible texts
                // still ellipsize on narrow phones instead of overflowing.
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Flexible(
                        child: Text(
                          tr(
                            '${_editor.text.trim().isEmpty ? 0 : _editor.text.trim().split(RegExp(r'\s+')).length} słów',
                            '${_editor.text.trim().isEmpty ? 0 : _editor.text.trim().split(RegExp(r'\s+')).length} words',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 9, color: muted),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          tr(
                            'Ostatnia zmiana: ${_time(_selected!)}',
                            'Last changed: ${_time(_selected!)}',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 9, color: muted),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // The icon-only badge hugs the right corner; the
                      // hidden-mode text label keeps its Flexible so a long
                      // status can ellipsize.
                      if (_inHidden)
                        Flexible(
                          child: Text(
                            _statusLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 9, color: muted),
                          ),
                        )
                      else
                        _syncBadge(small: true),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  HighlightingTextController? _raw;
  TextEditingController _sourceController() {
    if (_raw == null) {
      final controller = HighlightingTextController(text: _editor.text)
        ..matches = (ranges: _findMatches, active: _matchIndex);
      controller.addListener(() {
        if (controller.value != _editor.value) {
          _editor.setValue(controller.value);
        }
      });
      _raw = controller;
    } else if (_raw!.text != _editor.text) {
      _raw!.value = _editor.value;
    }
    return _raw!;
  }

  Widget _toolbar(bool mobile) => Container(
    height: 42,
    decoration: const BoxDecoration(
      color: Color(0xff1a2030),
      border: Border(bottom: BorderSide(color: line)),
    ),
    child: Row(
      children: [
        if (mobile)
          IconButton(
            key: const Key('editor-back'),
            onPressed: _returnToList,
            icon: const Icon(Icons.arrow_back, size: 18),
            tooltip: tr('Wróć do notatek', 'Back to notes'),
            visualDensity: VisualDensity.compact,
          ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: mobile ? 2 : 8),
            child: Row(
              children: [
                SizedBox(
                  width: 88,
                  child: TextField(
                    contextMenuBuilder: siliqueTextContextMenu,
                    key: const Key('span-size'),
                    controller: _spanSize,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 12),
                    decoration: InputDecoration(
                      suffixText: 'px',
                      isDense: true,
                      contentPadding: const EdgeInsets.fromLTRB(6, 6, 0, 6),
                      suffixIconConstraints: const BoxConstraints(
                        minWidth: 26,
                        minHeight: 26,
                      ),
                      suffixIcon: Tooltip(
                        message: tr(
                          'Rozmiar zaznaczonego tekstu (8–72 px)',
                          'Selected text size (8–72 px)',
                        ),
                        child: InkWell(
                          key: const Key('span-size-apply'),
                          onTap: _applySpanSize,
                          child: const Icon(Icons.format_size, size: 15),
                        ),
                      ),
                    ),
                    onSubmitted: (_) => _applySpanSize(),
                  ),
                ),
                if (mobile)
                  _tool(
                    Icons.emoji_emotions_outlined,
                    tr('Wstaw emotkę', 'Insert emoji'),
                    _pickEmoji,
                  ),
                if (!_inHidden)
                  _tool(
                    Icons.image_outlined,
                    tr('Wstaw zdjęcie', 'Insert image'),
                    () => _run(_insertImage),
                  ),
                _tool(
                  Icons.search,
                  tr('Szukaj w notatce', 'Find in note'),
                  _showFind,
                ),
                for (final level in [1, 2, 3])
                  TextButton(
                    onPressed: () => _format('${'#' * level} '),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(35, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 7),
                      foregroundColor: const Color(0xffc3cae3),
                    ),
                    child: Text(
                      'H$level',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                const SizedBox(height: 20, child: VerticalDivider(width: 15)),
                _tool(
                  Icons.format_bold,
                  tr('Pogrubienie', 'Bold'),
                  () => _format('**', '**'),
                ),
                _tool(
                  Icons.format_italic,
                  tr('Kursywa', 'Italic'),
                  () => _format('*', '*'),
                ),
                _tool(
                  Icons.strikethrough_s,
                  tr('Przekreślenie', 'Strikethrough'),
                  () => _format('~~', '~~'),
                ),
                _tool(
                  Icons.format_list_bulleted,
                  tr('Lista', 'Bulleted list'),
                  () => _format('- '),
                ),
                _tool(
                  Icons.format_list_numbered,
                  tr('Lista numerowana', 'Numbered list'),
                  () => _format('1. '),
                ),
                _tool(
                  Icons.check_box_outlined,
                  tr('Zadanie', 'Task'),
                  () => _format('- [ ] '),
                ),
                const SizedBox(height: 20, child: VerticalDivider(width: 15)),
                _tool(Icons.link, 'Link', () => _format('[', '](https://)')),
                _tool(Icons.code, tr('Kod', 'Code'), () => _format('`', '`')),
                _tool(
                  Icons.link_outlined,
                  tr('Link do notatki', 'Link to note'),
                  () => _format('[[', ']]'),
                ),
                _tool(
                  _source ? Icons.visibility_outlined : Icons.data_object,
                  tr('Markdown / podgląd na żywo', 'Markdown / live preview'),
                  () => setState(() {
                    _source = !_source;
                    // The other mode lays the same text out differently, so
                    // the floating panel must re-anchor to the new field.
                    _wikiCaret = null;
                    _wikiAnchorValue = null;
                    _scheduleWikiAnchorUpdate();
                  }),
                ),
                _tool(Icons.undo, tr('Cofnij', 'Undo'), _editor.undo),
                _tool(Icons.redo, tr('Ponów', 'Redo'), _editor.redo),
                if (!mobile)
                  // Inside the scrolling row so the tool positions (and the
                  // visible width for them) stay unchanged.
                  _noteOptionsMenu(),
              ],
            ),
          ),
        ),
        if (_inHidden)
          IconButton(
            key: const Key('hidden-lock-now'),
            tooltip: tr('Zablokuj teraz', 'Lock now'),
            onPressed: _lockHiddenFolder,
            icon: const Icon(Icons.lock_outline, size: 18),
          ),
        if (mobile) _noteOptionsMenu(),
      ],
    ),
  );

  /// Note actions, moved from the removed header bar into the toolbar.
  Widget _noteOptionsMenu() => PopupMenuButton<String>(
    key: const Key('note-options'),
    tooltip: tr('Opcje notatki', 'Note options'),
    icon: const Icon(Icons.more_vert, size: 18),
    onSelected: (v) => _run(() async {
      if (!mounted || _selected == null) return;
      if (_inHidden) {
        if (v == 'reveal') await _revealHidden(_selected!);
        if (v == 'delete-hidden') await _deleteHidden(_selected!);
        return;
      }
      if (v == 'favorite') await _favorite(_selected!);
      if (v == 'purge') {
        if (!mounted) return;
        final note = _selected!;
        if (await confirmAction(
          context,
          () => tr('Usunąć bezpowrotnie?', 'Delete permanently?'),
          () => tr(
            'Notatki nie będzie można przywrócić.',
            'The note cannot be restored.',
          ),
        )) {
          await repo.purgeNote(note);
          await _closeTab(note.id);
        }
      }
      if (v == 'hide') await _hideNote(_selected!);
      if (v == 'trash') await _trash();
      if (v == 'export') {
        await _flush();
        await exportMarkdown(await repo.noteWithEmbeddedImages(_selected!));
      }
      if (v == 'folder') {
        if (!mounted) return;
        final f = await chooseTargetFolder(
          context,
          folders: _allFolderPaths,
          initial: '',
          folderColors: repo.folderColorsOf(_vaultId ?? ''),
        );
        if (f != null && mounted) {
          await _flush();
          final changed = _selected!.copyWith(folder: f);
          await repo.save(changed);
          if (mounted) setState(() => _selected = changed);
        }
      }
      if (v == 'lock') {
        await _flush();
        repo.lock(_vaultId!);
        if (mounted) setState(_clearEditor);
      }
      if (v == 'password') {
        if (!mounted) return;
        final p = await askText(
          context,
          '',
          titleBuilder: () => tr('Nowe hasło vaulta', 'New vault password'),
          secret: true,
          hintBuilder: () =>
              tr('Co najmniej 12 znaków', 'At least 12 characters'),
        );
        if (p != null) await repo.changeVaultPassword(vault!, p);
      }
    }),
    itemBuilder: (ctx) {
      Localizations.localeOf(ctx);
      return _inHidden
          ? [
              SiliquePopupItem(
                value: 'reveal',
                child: Text(tr('Przenieś do folderu', 'Move to folder')),
              ),
              const PopupMenuDivider(),
              SiliquePopupItem(
                value: 'delete-hidden',
                child: Text(tr('Usuń ukrytą notatkę', 'Delete hidden note')),
              ),
            ]
          : [
              SiliquePopupItem(
                value: 'favorite',
                child: Text(
                  _selected!.favorite
                      ? tr('Odepnij notatkę', 'Unpin note')
                      : tr('Przypnij notatkę', 'Pin note'),
                ),
              ),
              SiliquePopupItem(
                value: 'folder',
                child: Text(tr('Przenieś do folderu', 'Move to folder')),
              ),
              SiliquePopupItem(
                value: 'export',
                child: Text(tr('Eksportuj Markdown', 'Export Markdown')),
              ),
              const PopupMenuDivider(),
              SiliquePopupItem(
                value: 'trash',
                child: Text(
                  _selected!.deleted
                      ? tr('Przywróć z kosza', 'Restore from trash')
                      : tr('Przenieś do kosza', 'Move to trash'),
                ),
              ),
              if (!_selected!.deleted)
                SiliquePopupItem(
                  value: 'hide',
                  child: Text(
                    tr('Ukryj notatkę (hasło)', 'Hide note (password)'),
                  ),
                ),
              if (_selected!.deleted)
                SiliquePopupItem(
                  value: 'purge',
                  child: Text(tr('Usuń bezpowrotnie', 'Delete permanently')),
                ),
              if (vault!.protected) ...[
                const PopupMenuDivider(),
                SiliquePopupItem(
                  value: 'lock',
                  child: Text(tr('Zablokuj vault', 'Lock vault')),
                ),
                SiliquePopupItem(
                  value: 'password',
                  child: Text(
                    tr('Zmień hasło vaulta', 'Change vault password'),
                  ),
                ),
              ],
            ];
    },
  );
  Widget _tool(IconData icon, String hint, VoidCallback onTap) => IconButton(
    onPressed: onTap,
    icon: Icon(icon, size: 17, color: const Color(0xffc3cae3)),
    tooltip: hint,
  );
  Widget _bottomNav() => Container(
    constraints: const BoxConstraints(minHeight: 66),
    decoration: const BoxDecoration(
      color: Color(0xff111725),
      border: Border(top: BorderSide(color: line)),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _bottomItem(
          Icons.home_rounded,
          tr('Notatki', 'Notes'),
          () => _filterBy('Wszystkie'),
          _filter != 'Dziennik',
        ),
        _bottomItem(
          Icons.calendar_month_outlined,
          _filterLabel('Dziennik'),
          () => _newNote(journal: true),
          _filter == 'Dziennik',
        ),
        _bottomItem(Icons.search, tr('Szukaj', 'Search'), () async {
          await _filterBy('Wszystkie');
          _searchFocus.requestFocus();
        }, false),
        _bottomItem(
          Icons.settings_outlined,
          tr('Ustawienia', 'Settings'),
          _settings,
          false,
        ),
      ],
    ),
  );
  Widget _bottomItem(
    IconData icon,
    String text,
    Future<void> Function() action,
    bool active,
  ) => Expanded(
    child: InkWell(
      onTap: () => unawaited(action()),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 21, color: active ? accent : muted),
            const SizedBox(height: 5),
            Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 9, color: active ? accent : muted),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _onboarding() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SiliqueMark(size: 72),
            const SizedBox(height: 28),
            const Text(
              'SILIQUE',
              style: TextStyle(
                fontSize: 28,
                letterSpacing: 2,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              tr(
                'Twoje myśli. Twoja przestrzeń.',
                'Your thoughts. Your space.',
              ),
              style: TextStyle(fontSize: 18, color: muted),
            ),
            const SizedBox(height: 30),
            Text(
              tr(
                'Pisz, porządkuj i wracaj do pomysłów. Notatki działają offline. Własny serwer możesz podłączyć w dowolnym momencie.',
                'Write, organize and revisit ideas. Notes work offline. Connect your own server whenever you like.',
              ),
              textAlign: TextAlign.center,
              style: TextStyle(color: muted, height: 1.8),
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: 280,
              child: FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await repo.createVault(tr('Osobiste', 'Personal'));
                        _vaultId = repo.vaults.last.id;
                        await repo.rememberVault(_vaultId!);
                        final note = await repo.createNote(
                          _vaultId!,
                          folder: tr('Projekty', 'Projects'),
                        );
                        final sample = note.copyWith(
                          title: tr('Plan na tydzień', 'Weekly plan'),
                          body: exampleBody,
                          tags: [
                            tr('planowanie', 'planning'),
                            tr('praca', 'work'),
                            tr('cele', 'goals'),
                          ],
                          favorite: true,
                        );
                        await repo.save(sample);
                        if (mounted) setState(() => _load(sample));
                      }),
                icon: const Icon(Icons.edit_note),
                label: Text(tr('Rozpocznij lokalnie', 'Start locally')),
              ),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _busy ? null : _settings,
              icon: const Icon(Icons.cloud_outlined, size: 18),
              label: Text(
                tr('Połącz z własnym serwerem', 'Connect to your own server'),
              ),
            ),
            const SizedBox(height: 20),
            if (_busy)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            const SizedBox(height: 12),
            Text(
              tr(
                'Bez konta. Bez reklam. Pod Twoją kontrolą.',
                'No account. No ads. Under your control.',
              ),
              style: TextStyle(fontSize: 11, color: muted),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Payload of an in-app drag between the note list and the folder tree.
sealed class _WorkspaceDrag {
  const _WorkspaceDrag();
}

/// One or more notes identified by stable IDs inside the active vault.
class _NotesDrag extends _WorkspaceDrag {
  const _NotesDrag(this.ids);
  final List<String> ids;
}

/// A folder that moves together with its whole subtree.
class _FolderDrag extends _WorkspaceDrag {
  const _FolderDrag(this.path);
  final String path;
}

/// The visible insertion slot drawn when a dragged folder hovers the top or
/// bottom quarter of a sibling row. It is a real, space-taking bar (3 px tall,
/// 4 px breathing room on each side) so the sibling rows visibly spread apart
/// instead of a thin line merely being painted on top of them.
class _FolderDropIndicator extends StatelessWidget {
  const _FolderDropIndicator();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Container(
      key: const Key('folder-drop-indicator'),
      width: double.infinity,
      height: 3,
      decoration: BoxDecoration(
        color: accent,
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );
}

// ── Sliver helpers ───────────────────────────────────────────────────

/// A `SliverPersistentHeaderDelegate` with a fixed extent.
/// The `child` is laid out at the full extent; the background color must be
/// supplied by the caller wrapping the child in a `Container`.
class _FixedExtentDelegate extends SliverPersistentHeaderDelegate {
  _FixedExtentDelegate({required this.extent, required this.child});
  final double extent;
  final Widget child;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => child;

  @override
  double get maxExtent => extent;

  @override
  double get minExtent => extent;

  @override
  bool shouldRebuild(_FixedExtentDelegate oldDelegate) =>
      extent != oldDelegate.extent || child != oldDelegate.child;
}
