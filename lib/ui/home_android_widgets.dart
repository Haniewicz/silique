part of 'home.dart';

/// Keep launcher routing separate from editor layout/gesture implementation.
/// Actions are serialized: a second tap cannot be discarded by Home's busy gate.
extension _AndroidWidgetRouting on _HomeScreenState {
  void _startAndroidWidgets() {
    _widgetActions = _androidWidgets.actions.listen((action) {
      _widgetTail = _widgetTail
          .then((_) => _applyWidgetAction(action))
          .catchError((Object error) => _notify('$error'));
    });
    unawaited(
      _androidWidgets.start().catchError((Object error) {
        // An unavailable Keystore/index must not prevent opening the notebook.
        _androidWidgets.lastError = error;
      }),
    );
  }

  Future<void> _applyWidgetAction(WidgetAction action) async {
    while (mounted && _busy) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!mounted || !action.isEligible(repo)) return;
    await _run(() async {
      // _switch flushes edits, locks/leaves hidden mode and resets list filters.
      final target = action.targetVault(repo);
      if (target == null) return;
      await _switch(target);
      if (!mounted || !action.isEligible(repo)) return;
      if (action.action == 'openNote') {
        final note = repo.notes[target]?[action.noteId];
        if (note != null && !note.hidden && !note.deleted) await _select(note);
      } else {
        final today = DateTime.now();
        final date =
            '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
        final journal = action.action == 'journal';
        final note = await repo.createNote(
          target,
          journalDate: journal ? date : null,
        );
        if (!mounted || !repo.unlocked.containsKey(target)) return;
        _filter = journal ? 'Dziennik' : 'Wszystkie';
        await _select(note);
      }
    });
  }
}
