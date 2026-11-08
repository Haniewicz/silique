import 'dart:async';

import 'package:flutter/material.dart';

import 'menus.dart';

import '../core/models.dart';
import '../l10n/app_language.dart';
import '../services/notebook.dart';
import '../storage/native_window.dart';

/// A separate surface for plaintext that must never enter the ordinary editor.
class HiddenNotesPage extends StatefulWidget {
  const HiddenNotesPage({
    super.key,
    required this.notebook,
    required this.vaultId,
  });
  final Notebook notebook;
  final String vaultId;

  @override
  State<HiddenNotesPage> createState() => _HiddenNotesPageState();
}

class _HiddenNotesPageState extends State<HiddenNotesPage>
    with WidgetsBindingObserver {
  List<Note> _notes = [];
  Note? _selected;
  TextEditingController? _title, _body;
  Future<void> _pending = Future<void>.value();
  Object? _saveError;
  String? _error;
  bool _loading = true;
  bool _locked = false;
  bool _busy = false;
  bool _allowPop = false;
  StreamSubscription<void>? _hiddenChanges;
  Timer? _securityWatch;
  Future<void> Function()? _previousClose;
  late final Future<void> Function() _closeHook;

  bool get _available =>
      !_locked &&
      _repo.hiddenUnlocked &&
      _repo.unlocked.containsKey(widget.vaultId);

  Notebook get _repo => widget.notebook;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _previousClose = NativeWindow.instance.beforeClose;
    _closeHook = () async {
      if (_busy) {
        throw StateError(
          tr(
            'Poczekaj na zakończenie zapisu notatki.',
            'Please wait for the note to finish saving.',
          ),
        );
      }
      if (mounted) setState(() => _busy = true);
      try {
        await _flush();
        await _previousClose?.call();
        await _repo.lockHidden();
      } catch (error) {
        if (mounted) {
          setState(
            () => _error = tr(
              'Nie udało się zapisać zmian: $error',
              'Could not save changes: $error',
            ),
          );
        }
        rethrow; // NativeWindow must keep the window open on failure.
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    };
    NativeWindow.instance.beforeClose = _closeHook;
    _hiddenChanges = _repo.hiddenStateChanges.listen((_) {
      if (!_available) _forget();
    });
    // Ordinary vault lock has no notification stream. This check never reads
    // or decrypts a list and never extends idle time; also catches wall-time
    // expiry while a repository operation is blocking its queued timer lock.
    _securityWatch = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!_available) _forget();
    });
    if (_available) {
      unawaited(_load());
    } else {
      _locked = true;
      _loading = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_available) _forget();
      return;
    }
    if (_repo.hiddenLockOnBackground &&
        !_locked &&
        (state == AppLifecycleState.inactive ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached)) {
      // No awaited I/O before this cover: app-switcher snapshots must not
      // retain plaintext, even while encryption/storage is still pending.
      _forget();
      unawaited(_lockInBackground());
    }
  }

  Future<void> _lockInBackground() async {
    try {
      await _flush();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = tr(
            'Nie udało się zapisać zmian przed blokadą.',
            'Could not save changes before locking.',
          ),
        );
      }
    } finally {
      try {
        await _repo.lockHidden();
      } catch (error) {
        if (mounted) {
          setState(
            () => _error = tr(
              'Nie udało się zablokować ukrytych notatek.',
              'Could not lock hidden notes.',
            ),
          );
        }
      }
    }
  }

  void _forget() {
    if (!mounted || _locked) return;
    final title = _title, body = _body;
    // Clear values before detaching: even a retained controller no longer
    // holds plaintext. Dispose after EditableText has left the widget tree.
    title?.clear();
    body?.clear();
    FocusScope.of(context).unfocus();
    setState(() {
      _locked = true;
      _loading = false;
      _selected = null;
      _notes = [];
      _title = null;
      _body = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      title?.dispose();
      body?.dispose();
    });
  }

  Future<void> _lock() async {
    if (_busy || _locked) return;
    _forget();
    await _lockInBackground();
  }

  Future<void> _load() async {
    try {
      final notes = await _repo.hiddenNotes(widget.vaultId);
      if (!mounted || !_available) return;
      setState(() {
        _notes = notes;
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = tr(
            'Nie udało się wczytać ukrytych notatek: $error',
            'Could not load hidden notes: $error',
          );
        });
      }
    }
  }

  Future<void> _create() async {
    if (_busy || !_available) return;
    setState(() => _busy = true);
    try {
      final note = await _repo.createHiddenNote(widget.vaultId);
      if (!mounted || !_available) return;
      _notes.insert(0, note);
      _edit(note);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = tr(
            'Nie udało się utworzyć ukrytej notatki: $error',
            'Could not create hidden note: $error',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _edit(Note note) {
    if (!_available || _selected != null) return;
    setState(() {
      _selected = note;
      _title = TextEditingController(text: note.title);
      _body = TextEditingController(text: note.body);
    });
  }

  void _activity() {
    if (!_available) {
      _forget();
      return;
    }
    _repo.hiddenActivity();
  }

  void _changed(String _) {
    _activity();
    final note = _selected;
    if (note == null || !_available || _busy) return;
    final updated = note.copyWith(
      title: _title!.text,
      body: _body!.text,
      hidden: true,
    );
    _selected = updated;
    _notes = [
      for (final item in _notes)
        if (item.id == note.id) updated else item,
    ];
    _enqueueSave(updated);
  }

  void _enqueueSave(Note note) {
    // Submit immediately, not after a debounce: repository lock is serialized
    // behind these writes, including lock requests from its idle timer.
    _pending = _repo
        .save(note)
        .then(
          (_) {
            _saveError = null;
            if (mounted) setState(() => _error = null);
          },
          onError: (Object error, StackTrace stack) {
            _saveError = error;
            if (mounted) {
              setState(
                () => _error = tr(
                  'Nie udało się zapisać ukrytej notatki: $error',
                  'Could not save hidden note: $error',
                ),
              );
            }
          },
        );
  }

  void _retry() {
    final note = _selected;
    if (note != null && _available && !_busy) _enqueueSave(note);
  }

  Future<void> _flush() async {
    await _pending;
    if (_saveError != null) throw _saveError!;
  }

  Future<void> _pop() async {
    if (!mounted) return;
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _close() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _flush();
      await _pop();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = tr(
            'Nie udało się zapisać zmian: $error',
            'Could not save changes: $error',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reveal() async {
    if (_busy || !_available) return;
    setState(() => _busy = true);
    try {
      await _flush();
      final note = _selected;
      if (note == null) return;
      await _repo.unhideNote(widget.vaultId, note.id);
      await _pop();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = tr(
            'Nie udało się przenieść notatki: $error',
            'Could not move note: $error',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _securityWatch?.cancel();
    if (identical(NativeWindow.instance.beforeClose, _closeHook)) {
      NativeWindow.instance.beforeClose = _previousClose;
    }
    unawaited(_hiddenChanges?.cancel());
    _title?.clear();
    _body?.clear();
    _notes = [];
    _selected = null;
    _title?.dispose();
    _body?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Localizations.localeOf(context);
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _activity(),
        onPointerMove: (_) => _activity(),
        onPointerSignal: (_) => _activity(),
        child: Focus(
          autofocus: true,
          onKeyEvent: (_, _) {
            _activity();
            return KeyEventResult.ignored;
          },
          child: Scaffold(
            appBar: AppBar(
              leading: BackButton(onPressed: _busy ? null : _close),
              title: Text(tr('Ukryte notatki', 'Hidden notes')),
              actions: [
                if (!_locked)
                  IconButton(
                    key: const Key('hidden-lock-now'),
                    tooltip: tr('Zablokuj teraz', 'Lock now'),
                    onPressed: _busy ? null : _lock,
                    icon: const Icon(Icons.lock),
                  ),
                if (!_locked && _selected != null)
                  TextButton(
                    key: const Key('hidden-reveal'),
                    onPressed: _busy ? null : _reveal,
                    child: Text(
                      tr('Przenieś do zwykłych', 'Move to ordinary notes'),
                    ),
                  ),
                if (!_locked && _selected == null)
                  IconButton(
                    key: const Key('hidden-new'),
                    tooltip: tr('Nowa ukryta notatka', 'New hidden note'),
                    onPressed: _busy || _loading ? null : _create,
                    icon: const Icon(Icons.add),
                  ),
              ],
            ),
            body: Column(
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_error!, key: const Key('hidden-error')),
                  ),
                if (_saveError != null && _available && _selected != null)
                  TextButton(
                    key: const Key('hidden-retry'),
                    onPressed: _busy ? null : _retry,
                    child: Text(tr('Spróbuj zapisać ponownie', 'Retry saving')),
                  ),
                Expanded(
                  child: _locked
                      ? Center(
                          child: Text(
                            tr(
                              'Ukryte notatki są zablokowane.',
                              'Hidden notes are locked.',
                            ),
                          ),
                        )
                      : _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _selected == null
                      ? ListView(
                          children: [
                            for (final note in _notes)
                              ListTile(
                                title: Text(
                                  note.title.isEmpty
                                      ? tr('Bez tytułu', 'Untitled')
                                      : note.title,
                                ),
                                onTap: _busy ? null : () => _edit(note),
                              ),
                          ],
                        )
                      : Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              TextField(
                                contextMenuBuilder: siliqueTextContextMenu,
                                key: const Key('hidden-title'),
                                controller: _title,
                                readOnly: _busy,
                                autocorrect: false,
                                enableSuggestions: false,
                                decoration: InputDecoration(
                                  labelText: tr('Tytuł', 'Title'),
                                ),
                                onChanged: _changed,
                              ),
                              Expanded(
                                child: TextField(
                                  contextMenuBuilder: siliqueTextContextMenu,
                                  key: const Key('hidden-body'),
                                  controller: _body,
                                  readOnly: _busy,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  maxLines: null,
                                  expands: true,
                                  textAlignVertical: TextAlignVertical.top,
                                  decoration: InputDecoration(
                                    labelText: tr('Treść', 'Content'),
                                  ),
                                  onChanged: _changed,
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
