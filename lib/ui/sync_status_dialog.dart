import 'package:flutter/material.dart';

import '../core/models.dart';
import '../l10n/app_language.dart';
import '../services/notebook.dart';
import 'menus.dart';
import 'theme.dart';

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
  bool _busy = false;
  String? _result;

  Notebook get _notebook => widget.notebook;
  Vault get _vault => widget.vault;

  /// A sync is running (either a normal pass or one of our forced actions), a
  /// forced pass is already in flight, or a forced pass just produced a result:
  /// in every case the two actions must not fire again until it settles.
  bool get _actionsDisabled => _notebook.syncing || _busy;

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

  Future<void> _run(Future<Object?> Function() action) async {
    if (_busy || _notebook.syncing) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      await action();
      if (mounted) {
        setState(() => _result = tr('Zakończono.', 'Done.'));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _result = '$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
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
        TextButton.icon(
          key: const Key('sync-force-flush'),
          icon: const Icon(Icons.upload_outlined, size: 18),
          label: Text(tr('Wyślij oczekujące zmiany', 'Send pending changes')),
          onPressed: _actionsDisabled
              ? null
              : () => _run(
                    () => _notebook.forceFlushPending(vaultId: _vault.id),
                  ),
        ),
        FilledButton.icon(
          key: const Key('sync-force-pull'),
          icon: const Icon(Icons.download_outlined, size: 18),
          label: Text(tr('Wymuś pełne ściągnięcie', 'Force full pull')),
          onPressed: _actionsDisabled
              ? null
              : () => _run(
                    () => _notebook.forceFullPull(vaultId: _vault.id),
                  ),
        ),
        TextButton.icon(
          key: const Key('sync-reset-source'),
          icon: const Icon(Icons.flood_outlined, size: 18),
          label: Text(
            tr(
              'Ustaw to urządzenie jako źródło prawdy…',
              'Set this device as the source of truth…',
            ),
            style: const TextStyle(color: syncOff),
          ),
          onPressed: _actionsDisabled ? null : () => _confirmReset(),
        ),
      ],
    );
  }

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
      () async {
        final report = await _notebook.resetToLocalSourceOfTruth(
          _vault.id,
          keepLosingCopies: keepCopies,
        );
        if (!mounted) return report;
        setState(
          () => _result = tr(
            'Gotowe. Nadpisano: ${report.notesRewritten}, usunięto: '
            '${report.deletionsWritten}, kopie: ${report.copiesKept}, '
            'pozostałe rozbieżne: ${report.remainingDiverged}, '
            'pominięte ukryte: ${report.hiddenSkipped}.',
            'Done. Rewritten: ${report.notesRewritten}, deleted: '
            '${report.deletionsWritten}, copies: ${report.copiesKept}, '
            'remaining diverged: ${report.remainingDiverged}, '
            'hidden skipped: ${report.hiddenSkipped}.',
          ),
        );
        return report;
      },
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