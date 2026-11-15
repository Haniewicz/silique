import 'package:flutter/material.dart';

import '../core/models.dart';
import '../l10n/app_language.dart';
import '../services/notebook.dart';
import 'menus.dart';
import 'theme.dart';

/// Which of the long sync actions is currently running, or null when idle.
enum _SyncAction { flush, pull, reset, adopt }

/// The decision the owner made about a held source-of-truth marker.
enum SyncSourceDecision { backupAndAdopt, adopt, later }

/// Opens the source-of-truth adoption decision dialog for a held [vault] and
/// returns the chosen decision, or null on dismiss. No IO runs on open: the
/// export and adoption (and the underlying sync) only start after a decision.
Future<SyncSourceDecision?> showSyncSourceDecisionDialog(
  BuildContext context,
  Notebook notebook,
  Vault vault,
) =>
    showDialog<SyncSourceDecision>(
      context: context,
      builder: (_) => SyncSourceDecisionDialog(notebook: notebook, vault: vault),
    );

class SyncSourceDecisionDialog extends StatefulWidget {
  const SyncSourceDecisionDialog({
    super.key,
    required this.notebook,
    required this.vault,
  });
  final Notebook notebook;
  final Vault vault;
  @override
  State<SyncSourceDecisionDialog> createState() =>
      _SyncSourceDecisionDialogState();
}

class _SyncSourceDecisionDialogState extends State<SyncSourceDecisionDialog> {
  Notebook get _notebook => widget.notebook;
  Vault get _vault => widget.vault;

  /// The hold information named by the current status, for the dialog text.
  VaultSyncStatus? get _status => _notebook.syncStatus(_vault.id);

  /// Notes this device would overwrite locally by adopting (its own local
  /// live notes), used only as an informational count.
  int get _localNotes => (_notebook.notes[_vault.id]?.values ?? const <Note>[])
      .where((n) => !n.deleted && !n.hidden)
      .length;

  /// Pending revisions that would be superseded by adoption.
  int get _pending => _notebook.pendingCount(_vault.id);

  /// Human-readable device + time per the marker envelope.
  String get _deviceLabel => _status?.sourceHoldDevice ?? tr('inne urządzenie', 'another device');

  String get _timeLabel {
    final at = _status?.sourceHoldAt;
    if (at == null) return '';
    final t = DateTime.tryParse(at);
    if (t == null) return '';
    return t.toLocal().toString();
  }

  void _decide(SyncSourceDecision decision) =>
      Navigator.pop(context, decision);

  @override
  Widget build(BuildContext context) {
    Localizations.localeOf(context);
    final pending = _pending;
    final localNotes = _localNotes;
    return AlertDialog(
      title: Text(tr('Pobierz wersję z innego urządzenia', 'Fetch another device\'s version')),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr(
                'Urządzenie „$_deviceLabel” ustawiło się jako źródło prawdy '
                'dla tego vaulta ($_timeLabel). Pobierając je, zastąpisz '
                '$localNotes lokalnych notatek i $pending oczekujących zmian '
                'wersją z serwera.',
                'Device “$_deviceLabel” set itself as the source of truth for '
                'this vault ($_timeLabel). Fetching it will replace $localNotes '
                'local notes and $pending pending changes with the server version.',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              tr(
                'Aby zachować kopię obecnych notatek, wybierz „Zapisz kopię i '
                'pobierz” — eksport wykona się przed pobraniem.',
                'To keep a copy of the current notes, choose “Save a copy and '
                'fetch” — the export runs before the fetch.',
              ),
              style: const TextStyle(fontSize: 12, color: muted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('sync-source-later'),
          onPressed: () => _decide(SyncSourceDecision.later),
          child: Text(tr('Później', 'Later')),
        ),
        TextButton(
          key: const Key('sync-source-adopt'),
          onPressed: () => _decide(SyncSourceDecision.adopt),
          child: Text(tr('Pobierz wersję z serwera', 'Fetch the server version')),
        ),
        FilledButton(
          key: const Key('sync-source-backup-adopt'),
          onPressed: () => _decide(SyncSourceDecision.backupAndAdopt),
          child: Text(tr('Zapisz kopię i pobierz', 'Save a copy and fetch')),
        ),
      ],
    );
  }
}

/// Opens the observable sync status dialog for [vault] and returns when it is
/// dismissed. All state and rendering come from the in-memory [Notebook] and its
/// storage; no network or filesystem work happens on open.
Future<void> showSyncStatusDialog(
  BuildContext context,
  Notebook notebook,
  Vault vault,
) =>
    showDialog<void>(
      context: context,
      builder: (_) => SyncStatusDialog(notebook: notebook, vault: vault),
    );

class SyncStatusDialog extends StatefulWidget {
  const SyncStatusDialog({
    super.key,
    required this.notebook,
    required this.vault,
  });
  final Notebook notebook;
  final Vault vault;
  @override
  State<SyncStatusDialog> createState() => _SyncStatusDialogState();
}

class _SyncStatusDialogState extends State<SyncStatusDialog> {
  _SyncAction? _busyAction;
  String? _result;

  Notebook get _notebook => widget.notebook;
  Vault get _vault => widget.vault;

  /// A sync is running (either a normal pass or one of our forced actions), a
  /// forced pass is already in flight, or a forced pass just produced a result:
  /// in every case the actions must not fire again until it settles.
  bool get _actionsDisabled => _notebook.syncing || _busyAction != null;

  /// Whether this vault is held pending an ownership decision on a newer
  /// source-of-truth marker.
  bool get _held => _notebook.syncStatus(_vault.id)?.held ?? false;

  /// The device named by the held marker (informational, for the banner).
  String get _holdDevice =>
      _notebook.syncStatus(_vault.id)?.sourceHoldDevice ??
      tr('inne urządzenie', 'another device');

  /// The most recent interrupted resumable journaled operation for this vault,
  /// or null when there is nothing to finish.
  SyncOperation? get _interruptedOperation {
    for (final op in _notebook.syncOperations()) {
      if (op.status != SyncOperation.statusInterrupted) continue;
      if (op.vaultId != _vault.id) continue;
      if (!op.resumable) continue;
      return op;
    }
    return null;
  }

  /// The marker's local "at" time, formatted for the banner.
  String get _holdTimeLabel {
    final at = _notebook.syncStatus(_vault.id)?.sourceHoldAt;
    if (at == null) return '';
    final t = DateTime.tryParse(at);
    if (t == null) return '';
    return t.toLocal().toString();
  }

  /// Notes this device would overwrite locally by adopting (its own local live
  /// notes), used only as an informational count.
  int get _localNotes => (_notebook.notes[_vault.id]?.values ?? const <Note>[])
      .where((n) => !n.deleted && !n.hidden)
      .length;

  /// Human-readable relative time for the last successful sync, or "never".
  String _relativeTime(DateTime? value) {
    if (value == null) {
      return tr('nigdy', 'never');
    }
    final diff = DateTime.now().toUtc().difference(value.toUtc());
    if (diff.inSeconds < 60) {
      return tr('przed chwilą', 'just now');
    }
    if (diff.inMinutes < 60) {
      final m = diff.inMinutes;
      return tr('$m min temu', '$m min ago');
    }
    if (diff.inHours < 24) {
      final h = diff.inHours;
      return tr('$h godz. temu', '$h h ago');
    }
    final d = diff.inDays;
    return tr('$d dni temu', '$d days ago');
  }

  Future<void> _run(_SyncAction action, Future<Object?> Function() body) async {
    if (_busyAction != null || _notebook.syncing) return;
    setState(() {
      _busyAction = action;
      _result = null;
    });
    try {
      await body();
      if (mounted && _result == null) {
        setState(() => _result = tr('Zakończono.', 'Done.'));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _result = '$error');
      }
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  /// Maps an interrupted operation kind back to the [_SyncAction] whose spinner
  /// should show while it is being finished.
  _SyncAction? _finishAction(SyncOperation? op) => switch (op?.kind) {
    SyncOperation.kindPull => _SyncAction.pull,
    SyncOperation.kindFlush => _SyncAction.flush,
    SyncOperation.kindReset => _SyncAction.reset,
    _ => null,
  };

  /// Re-runs the interrupted (idempotent) operation named by the banner. Adopt
  /// is deliberately absent: adoption always needs a fresh owner decision, so an
  /// interrupted adopt is surfaced in the banner but never offered here.
  Future<void> _finishOperation() async {
    final op = _interruptedOperation;
    if (op == null) return;
    switch (op.kind) {
      case SyncOperation.kindPull:
        await _run(
          _SyncAction.pull,
          () => _notebook.forceFullPull(vaultId: _vault.id),
        );
      case SyncOperation.kindFlush:
        await _run(
          _SyncAction.flush,
          () => _notebook.forceFlushPending(vaultId: _vault.id),
        );
      case SyncOperation.kindReset:
        await _run(
          _SyncAction.reset,
          () => _notebook.resetToLocalSourceOfTruth(_vault.id),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    Localizations.localeOf(context);
    final status = _notebook.syncStatus(_vault.id);
    final pending = _notebook.pendingCount(_vault.id);
    final diverged = _notebook.divergedNoteCount(_vault.id);
    final failing = status?.failing ?? false;
    return AlertDialog(
      title: Text(tr('Status synchronizacji', 'Sync status')),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _row(
              tr('Ostatnia synchronizacja', 'Last successful sync'),
              _relativeTime(status?.lastSuccessAt),
            ),
            _row(tr('Oczekujące zmiany', 'Pending changes'), '$pending'),
            _row(tr('Rozbieżne notatki', 'Diverged notes'), '$diverged'),
            if (_held) ...[
              const SizedBox(height: 10),
              _heldBanner(pending, diverged),
            ],
            if (_interruptedOperation != null) ...[
              const SizedBox(height: 10),
              Container(
                key: const Key('sync-interrupted-banner'),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: syncOff.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: syncOff),
                ),
                child: Text(
                  tr(
                    'Poprzednia operacja synchronizacji została przerwana.',
                    'A previous sync operation was interrupted.',
                  ),
                  style: const TextStyle(fontSize: 12, height: 1.35),
                ),
              ),
            ],
            const SizedBox(height: 8),
            if (status?.lastError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  tr('Ostatni błąd', 'Last error'),
                  style: const TextStyle(
                    fontSize: 11,
                    color: muted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            if (status?.lastError != null)
              SelectableText(
                '${status?.lastError}',
                contextMenuBuilder: siliqueTextContextMenu,
                style: TextStyle(
                  fontSize: 12,
                  color: failing ? syncOff : muted,
                ),
              ),
            if (_result != null) ...[
              const SizedBox(height: 10),
              SelectableText(
                '$_result',
                contextMenuBuilder: siliqueTextContextMenu,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('Zamknij', 'Close')),
        ),
        if (_interruptedOperation != null)
          FilledButton.icon(
            key: const Key('sync-finish-operation'),
            icon: _busyAction == _finishAction(_interruptedOperation)
                ? _spinner('sync-finish-operation-spinner')
                : const Icon(Icons.play_arrow_outlined, size: 18),
            label: Text(tr('Dokończ operację', 'Finish operation')),
            onPressed: _actionsDisabled ? null : () => _finishOperation(),
          ),
        TextButton.icon(
          key: const Key('sync-force-flush'),
          icon: _busyAction == _SyncAction.flush
              ? _spinner('sync-force-flush-spinner')
              : const Icon(Icons.upload_outlined, size: 18),
          label: Text(tr('Wyślij oczekujące zmiany', 'Send pending changes')),
          onPressed: _actionsDisabled
              ? null
              : () => _run(
                    _SyncAction.flush,
                    () => _notebook.forceFlushPending(vaultId: _vault.id),
                  ),
        ),
        FilledButton.icon(
          key: const Key('sync-force-pull'),
          icon: _busyAction == _SyncAction.pull
              ? _spinner('sync-force-pull-spinner')
              : const Icon(Icons.download_outlined, size: 18),
          label: Text(tr('Wymuś pełne ściągnięcie', 'Force full pull')),
          onPressed: _actionsDisabled
              ? null
              : () => _run(
                    _SyncAction.pull,
                    () => _notebook.forceFullPull(vaultId: _vault.id),
                  ),
        ),
        TextButton.icon(
          key: const Key('sync-reset-source'),
          icon: _busyAction == _SyncAction.reset
              ? _spinner('sync-reset-spinner')
              : const Icon(Icons.flood_outlined, size: 18),
          label: Text(
            tr(
              'Ustaw to urządzenie jako źródło prawdy…',
              'Set this device as the source of truth…',
            ),
            style: const TextStyle(color: syncOff),
          ),
          onPressed: _actionsDisabled ? null : () => _confirmReset(),
        ),
        if (_held)
          FilledButton.icon(
            key: const Key('sync-adopt'),
            icon: _busyAction == _SyncAction.adopt
                ? _spinner('sync-adopt-spinner')
                : const Icon(Icons.cloud_download_outlined, size: 18),
            label: Text(
              tr(
                'Pobierz wersję z serwera…',
                'Fetch the server version…',
              ),
            ),
            onPressed: _actionsDisabled ? null : () => _confirmAdopt(),
          ),
      ],
    );
  }

  /// The 18 px progress spinner shown inside the currently pressed action's
  /// button, keyed so a widget test can pinpoint which action is running.
  Widget _spinner(String key) => SizedBox(
    key: Key(key),
    width: 18,
    height: 18,
    child: const CircularProgressIndicator(strokeWidth: 2),
  );

  /// Second confirmation: lists the counts, states the consequences, offers the
  /// "keep losing versions as copies" checkbox (default on) and warns that
  /// hidden notes are not covered. Only a confirmed action performs IO.
  Future<void> _confirmReset() async {
    final pending = _notebook.pendingCount(_vault.id);
    final diverged = _notebook.divergedNoteCount(_vault.id);
    var keepCopies = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(
            tr(
              'Ustaw źródło prawdy',
              'Set source of truth',
            ),
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(
                    'To urządzenie nadpisze zdalne wersje notatek na serwerze. '
                    'Historia wersji pozostaje w bazie; przy zaznaczonej opcji '
                    'przegrywające wersje zostaną zachowane jako kopie.',
                    'This device will overwrite the remote note versions on '
                    'the server. Version history stays in the database; with '
                    'the option below, losing versions are kept as copies.',
                  ),
                ),
                const SizedBox(height: 12),
                _row(tr('Oczekujące zmiany', 'Pending changes'), '$pending'),
                _row(tr('Rozbieżne notatki', 'Diverged notes'), '$diverged'),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: keepCopies,
                  onChanged: (value) => setDialogState(
                    () => keepCopies = value ?? true,
                  ),
                  title: Text(
                    tr(
                      'zachowaj przegrywające wersje jako kopie',
                      'keep losing versions as copies',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  tr(
                    'Uwaga: ukryte notatki nie są objęte tą operacją.',
                    'Note: hidden notes are not covered by this operation.',
                  ),
                  style: const TextStyle(
                    fontSize: 11,
                    color: muted,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Anuluj', 'Cancel')),
            ),
            FilledButton(
              key: const Key('sync-reset-confirm'),
              style: FilledButton.styleFrom(backgroundColor: syncOff),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Ustaw źródło prawdy', 'Set source of truth')),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(
      _SyncAction.reset,
      () async {
        final report = await _notebook.resetToLocalSourceOfTruth(
          _vault.id,
          keepLosingCopies: keepCopies,
        );
        if (!mounted) return report;
        final complete =
            report.remainingDiverged == 0 && report.remainingPending == 0;
        setState(() => _result = complete
            ? tr(
                'Gotowe. Nadpisano: ${report.notesRewritten}, usunięto: '
                '${report.deletionsWritten}, kopie: ${report.copiesKept}, '
                'pominięte ukryte: ${report.hiddenSkipped}.',
                'Done. Rewritten: ${report.notesRewritten}, deleted: '
                '${report.deletionsWritten}, copies: ${report.copiesKept}, '
                'hidden skipped: ${report.hiddenSkipped}.',
              )
            : tr(
                'Operacja nieukończona. Nadpisano: ${report.notesRewritten}, '
                'usunięto: ${report.deletionsWritten}, kopie: '
                '${report.copiesKept}, pozostałe rozbieżne: '
                '${report.remainingDiverged}, pozostałe oczekujące: '
                '${report.remainingPending}, pominięte ukryte: '
                '${report.hiddenSkipped}.',
                'Incomplete. Rewritten: ${report.notesRewritten}, deleted: '
                '${report.deletionsWritten}, copies: ${report.copiesKept}, '
                'remaining diverged: ${report.remainingDiverged}, '
                'remaining pending: ${report.remainingPending}, '
                'hidden skipped: ${report.hiddenSkipped}.',
              ));
        return report;
      },
    );
  }

  /// Held banner: names the device and time and shows how many local notes and
  /// pending revisions would be replaced. It is not itself an action — the
  /// three-way decision (backup+adopt / adopt / later) lives in the adopt
  /// confirmation dialog, reached through the "Pobierz wersję z serwera…"
  /// button below.
  Widget _heldBanner(int pending, int diverged) {
    final count = tr(
      'Urządzenie „$_holdDevice” ustawiło się jako źródło prawdy '
      'dla tego vaulta ($_holdTimeLabel). Pobranie zastąpi $_localNotes '
      'lokalnych notatek i $pending oczekujących zmian wersją z serwera.',
      'Device “$_holdDevice” set itself as the source of truth for this vault '
      '($_holdTimeLabel). Fetching it will replace $_localNotes local notes '
      'and $pending pending changes with the server version.',
    );
    return Container(
      key: const Key('sync-hold-banner'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: syncOff.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: syncOff),
      ),
      child: Text(
        count,
        style: const TextStyle(fontSize: 12, height: 1.35),
      ),
    );
  }

  /// Opens the three-action decision dialog. "later" changes nothing (and the
  /// vault stays held); "adopt" and "backupAndAdopt" adopt the source of truth,
  /// the latter exporting a backup first. All IO runs inside `_run` so the
  /// adopt spinner shows and the other actions disable while it is in flight.
  Future<void> _confirmAdopt() async {
    if (!mounted) return;
    final decision = await showSyncSourceDecisionDialog(
      context,
      _notebook,
      _vault,
    );
    if (!mounted || decision == null || decision == SyncSourceDecision.later) {
      return;
    }
    await _run(
      _SyncAction.adopt,
      () => _notebook.adoptSourceOfTruth(
        _vault.id,
        backupFirst: decision == SyncSourceDecision.backupAndAdopt,
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: muted),
          ),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}