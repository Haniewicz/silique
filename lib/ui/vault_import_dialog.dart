import '../l10n/app_language.dart';

import 'package:flutter/material.dart';

import '../core/workspace.dart';
import '../services/notebook.dart';
import '../storage/vault_import.dart';
import 'theme.dart';
import 'menus.dart';

class VaultImportDialog extends StatefulWidget {
  const VaultImportDialog({
    super.key,
    required this.notebook,
    required this.vaultId,
    this.initialFolder = '',
  });
  final Notebook notebook;
  final String vaultId, initialFolder;
  @override
  State<VaultImportDialog> createState() => _VaultImportDialogState();
}

class _VaultImportDialogState extends State<VaultImportDialog> {
  static const _newFolder = '\u0000new';
  final _name = TextEditingController();
  VaultImportPlan? _plan;
  String? _error;
  late String _folder = widget.initialFolder;
  bool _scanning = false, _importing = false;
  int _done = 0, _total = 0;
  String get _destination =>
      _folder == _newFolder ? _name.text.trim() : _folder;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _choose({bool file = false}) async {
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final source = file
          ? await pickMarkdownImportSource()
          : await pickVaultImportSource();
      if (source == null) return;
      final plan = await scanVaultImport(source);
      if (mounted) setState(() => _plan = plan);
    } catch (error) {
      if (mounted) {
        setState(() {
          _plan = null;
          _error = '$error';
        });
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _import() async {
    if (_plan == null) return;
    if ((_folder == _newFolder && _destination.isEmpty) ||
        (_destination.isNotEmpty &&
            normalizeFolderPath(_destination) != _destination)) {
      setState(
        () => _error =
            folderPathError(_destination) ??
            tr('Podaj nazwę folderu.', 'Enter a folder name.'),
      );
      return;
    }
    setState(() {
      _importing = true;
      _error = null;
    });
    try {
      final result = await widget.notebook.importVault(
        widget.vaultId,
        _plan!,
        destination: _destination,
        onProgress: (done, total) {
          if (mounted) {
            setState(() {
              _done = done;
              _total = total;
            });
          }
        },
      );
      if (mounted) Navigator.pop(context, result);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _importing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Localizations.localeOf(context);
    final folders = widget.notebook.allFolders(widget.vaultId).toList()..sort();
    final busy = _scanning || _importing;
    return PopScope(
      canPop: !_importing,
      child: AlertDialog(
        title: Text(tr('Importuj notatki', 'Import notes')),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(
                    'Wybierz plik Markdown lub TXT albo cały folder. Przy imporcie folderu zachowamy podfoldery i zdjęcia. Pojedynczy plik zachowa treść i odnośniki. Pliki źródłowe pozostaną bez zmian.',
                    'Choose a Markdown or TXT file, or a whole folder. Folder imports preserve subfolders and images. A single file keeps its text and links. Source files remain unchanged.',
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  key: const Key('choose-import-file'),
                  onPressed: busy ? null : () => _choose(file: true),
                  icon: const Icon(Icons.description_outlined),
                  label: Text(
                    tr(
                      'Wybierz plik Markdown lub TXT',
                      'Choose Markdown or TXT file',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('choose-import-vault'),
                  onPressed: busy ? null : _choose,
                  icon: const Icon(Icons.folder_open),
                  label: Text(
                    tr('Wybierz folder z notatkami', 'Choose notes folder'),
                  ),
                ),
                if (_scanning) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(tr('Sprawdzanie plików…', 'Scanning files…')),
                ],
                if (_plan case final plan?) ...[
                  const SizedBox(height: 12),
                  Text(plan.source.label),
                  Text(
                    tr(
                      'Notatki: ${plan.notes.length} • Foldery: ${plan.folders.length}',
                      'Notes: ${plan.notes.length} • Folders: ${plan.folders.length}',
                    ),
                    key: const Key('vault-import-summary'),
                  ),
                  const SizedBox(height: 16),
                  SiliqueChoice<String>(
                    key: const Key('vault-import-destination'),
                    value: _folder,
                    decoration: InputDecoration(
                      labelText: tr(
                        'Folder docelowy w bieżącym vaulcie',
                        'Destination folder in the current vault',
                      ),
                    ),
                    items: [
                      SiliqueChoiceItem(
                        value: '',
                        icon: Icons.home_outlined,
                        child: Text(
                          tr(
                            'Bez folderu — katalog główny vaulta',
                            'No folder — vault root',
                          ),
                        ),
                      ),
                      for (final folder in folders)
                        SiliqueChoiceItem(
                          value: folder,
                          child: Text(folder, overflow: TextOverflow.ellipsis),
                        ),
                      SiliqueChoiceItem(
                        value: _newFolder,
                        icon: Icons.create_new_folder_outlined,
                        separatorBefore: true,
                        child: Text(
                          tr('Utwórz nowy folder…', 'Create new folder…'),
                        ),
                      ),
                    ],
                    onChanged: busy
                        ? null
                        : (value) => setState(() {
                            _folder = value;
                            _error = null;
                          }),
                  ),
                  if (_folder == _newFolder) ...[
                    const SizedBox(height: 12),
                    TextField(
                      contextMenuBuilder: siliqueTextContextMenu,
                      key: const Key('vault-import-new-folder'),
                      controller: _name,
                      enabled: !busy,
                      decoration: InputDecoration(
                        labelText: tr(
                          'Nazwa nowego folderu',
                          'New folder name',
                        ),
                        hintText: tr(
                          'Np. Import/Obsidian',
                          'e.g. Import/Obsidian',
                        ),
                      ),
                    ),
                  ],
                  if (plan.unsupported.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      tr(
                        'Inne pliki nie będą importowane (${plan.unsupported.length}):',
                        'Other files will not be imported (${plan.unsupported.length}):',
                      ),
                      style: const TextStyle(color: muted),
                    ),
                    for (final path in plan.unsupported.take(6))
                      Text(
                        path,
                        style: const TextStyle(color: muted, fontSize: 12),
                      ),
                    if (plan.unsupported.length > 6)
                      const Text('…', style: TextStyle(color: muted)),
                    const SizedBox(height: 4),
                    Text(
                      tr(
                        'Odnośniki do tych plików pozostaną w treści notatek, ale same załączniki nie zostaną skopiowane.',
                        'Links to these files will remain in the notes, but the attachments themselves will not be copied.',
                      ),
                      style: TextStyle(color: muted, fontSize: 12),
                    ),
                  ],
                ],
                if (_importing) ...[
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    value: _total == 0 ? null : _done / _total,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr(
                      'Importowanie notatek: $_done / $_total',
                      'Importing notes: $_done / $_total',
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    key: const Key('vault-import-error'),
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _importing ? null : () => Navigator.pop(context),
            child: Text(tr('Anuluj', 'Cancel')),
          ),
          FilledButton(
            key: const Key('confirm-vault-import'),
            onPressed: busy || _plan == null ? null : _import,
            child: Text(tr('Importuj', 'Import')),
          ),
        ],
      ),
    );
  }
}
