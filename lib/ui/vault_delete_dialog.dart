import '../l10n/app_language.dart';

import 'package:flutter/material.dart';

import '../core/models.dart';
import 'menus.dart';

Future<bool> deleteVaultDialog(
  BuildContext context,
  Vault vault,
  Future<void> Function(String confirmation) remove,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => VaultDeleteDialog(vault: vault, remove: remove),
    ) ??
    false;

/// Confirmation is a separate route, never a destructive menu-row callback.
class VaultDeleteDialog extends StatefulWidget {
  const VaultDeleteDialog({
    super.key,
    required this.vault,
    required this.remove,
  });
  final Vault vault;
  final Future<void> Function(String confirmation) remove;
  @override
  State<VaultDeleteDialog> createState() => _VaultDeleteDialogState();
}

class _VaultDeleteDialogState extends State<VaultDeleteDialog> {
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _name.clear();
    _name.dispose();
    super.dispose();
  }

  Future<void> _remove() async {
    if (_busy || _name.text != widget.vault.name) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.remove(_name.text);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Localizations.localeOf(context);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        scrollable: true,
        title: Text(
          tr('Usuń vault wraz z zawartością', 'Delete vault and its contents'),
        ),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Vault: ${widget.vault.name}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                tr(
                  'Identyfikator: ${widget.vault.id}',
                  'ID: ${widget.vault.id}',
                ),
              ),
              const SizedBox(height: 12),
              Text(
                tr(
                  'Usunięcie jest nieodwracalne.',
                  'Deletion is irreversible.',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.vault.owner == null
                    ? tr(
                        'Zakres: bieżący magazyn na tym urządzeniu. Ten vault nie jest przypisany do konta synchronizacji.',
                        'Scope: the current store on this device. This vault is not linked to a sync account.',
                      )
                    : tr(
                        'Zakres: ten vault na koncie ${widget.vault.owner}, na serwerze i w bieżącym magazynie. Zgodne urządzenia usuną swoje kopie po połączeniu.',
                        'Scope: this vault on account ${widget.vault.owner}, on the server and in the current store. Compatible devices will delete their copies when they connect.',
                      ),
              ),
              const SizedBox(height: 8),
              Text(
                tr(
                  'Usunięte zostaną wszystkie notatki, także ukryte i z kosza, foldery, historia, załączniki oraz oczekujące zmiany.',
                  'All notes, including hidden and trashed notes, folders, history, attachments and pending changes will be deleted.',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                tr(
                  'Nie usuwa eksportów, kopii zapasowych, poprzednich miejsc zapisu ani kopii na starszych lub odłączonych urządzeniach. Nie gwarantuje fizycznego wymazania nośnika.',
                  'This does not delete exports, backups, previous storage locations or copies on older or disconnected devices. It does not guarantee physical erasure of the storage medium.',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('vault-delete-name'),
                controller: _name,
                enabled: !_busy,
                contextMenuBuilder: siliqueTextContextMenu,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: tr(
                    'Wpisz dokładną nazwę vaulta',
                    'Type the exact vault name',
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    tr(
                      '$_error\nJeśli serwer mógł już usunąć vault, zapisy pozostają zablokowane. Ponów dokończenie tutaj lub w zarządzaniu vaultami.',
                      '$_error\nIf the server may have already deleted the vault, writes remain blocked. Retry completion here or in vault management.',
                    ),
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context, false),
            child: Text(tr('Anuluj', 'Cancel')),
          ),
          FilledButton(
            key: const ValueKey('vault-delete-confirm'),
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade800),
            onPressed: !_busy && _name.text == widget.vault.name
                ? _remove
                : null,
            child: Text(
              _busy
                  ? tr('Usuwanie…', 'Deleting…')
                  : _error != null
                  ? tr('Ponów / dokończ usuwanie', 'Retry / finish deletion')
                  : tr('Usuń nieodwracalnie', 'Delete permanently'),
            ),
          ),
        ],
      ),
    );
  }
}
