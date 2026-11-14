import '../l10n/app_language.dart';

import 'dart:io';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../services/notebook.dart';
import '../storage/native_files.dart';
import '../storage/vault_export.dart';
import 'menus.dart';
import 'theme.dart';

/// Result of a completed vault export.
class VaultExportDialogResult {
  VaultExportDialogResult({required this.stats, this.directory, this.zipReady = false});
  final VaultExportStats stats;

  /// Absolute destination directory (desktop) — may be null on mobile.
  final String? directory;
  final bool zipReady;
}

/// Opens the vault export dialog and returns the final result, or null on cancel.
Future<VaultExportDialogResult?> showVaultExportDialog(
  BuildContext context,
  Notebook notebook,
  Vault vault,
) =>
    showDialog<VaultExportDialogResult>(
      context: context,
      builder: (_) => VaultExportDialog(notebook: notebook, vault: vault),
    );

class VaultExportDialog extends StatefulWidget {
  const VaultExportDialog({
    super.key,
    required this.notebook,
    required this.vault,
  });
  final Notebook notebook;
  final Vault vault;
  @override
  State<VaultExportDialog> createState() => _VaultExportDialogState();
}

class _VaultExportDialogState extends State<VaultExportDialog> {
  final _password = TextEditingController();
  bool _includeHidden = false;
  bool _busy = false;
  bool _done = false;
  String? _error;
  String? _directory;
  VaultExportStats? _stats;
  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  Future<void> _choose() async {
    setState(() {
      _error = null;
      _directory = null;
    });
    final dir = await chooseExportDirectory();
    if (dir == null) return;
    if (mounted) setState(() => _directory = dir);
  }

  Future<void> _export() async {
    if (_busy) return;
    // Fail fast on the destination before any decryption or IO: the picker
    // check must not depend on a prepared plan, and a widget test can assert
    // it without touching the filesystem.
    if (!_isMobile && _directory == null) {
      setState(() {
        _error = tr(
          'Wybierz katalog docelowy.',
          'Choose a destination directory.',
        );
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var includeHidden = _includeHidden;
      if (includeHidden && !widget.notebook.hiddenUnlocked) {
        final ok = await widget.notebook.unlockHidden(_password.text);
        if (!ok) {
          if (mounted) {
            setState(() {
              _error = tr(
                'Błędne hasło do ukrytych notatek. Eksport anulowany.',
                'Incorrect hidden notes password. Export cancelled.',
              );
              _busy = false;
            });
          }
          return;
        }
      }
      final data = await widget.notebook.prepareVaultExport(
        widget.vault.id,
        includeHidden: includeHidden,
      );
      final plan = buildVaultExportPlan(
        data.notes,
        images: data.images,
        folders: data.folders,
      );
      if (_isMobile) {
        final zip = buildVaultExportZip(plan);
        await shareExportZip(
          bytes: zip,
          name: safeVaultZipName(widget.vault.name),
        );
        if (mounted) {
          setState(() {
            _stats = VaultExportStats(
              notes: plan.notes.length,
              hidden: plan.hiddenCount,
              folders: plan.folders.length,
              images: plan.images.length,
              skippedImages: plan.skippedImageCount,
            );
            _done = true;
            _busy = false;
          });
        }
      } else {
        final writer = ExportVaultWriter(Directory(_directory!));
        final stats = await writer.write(plan);
        if (mounted) {
          setState(() {
            _stats = stats;
            _done = true;
            _busy = false;
          });
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = tr(
            'Eksport nie powiódł się: $error',
            'Export failed: $error',
          );
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Localizations.localeOf(context);
    final canExport = !_busy && !_done;
    final stats = _stats;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        scrollable: true,
        title: Text(tr('Eksportuj vault', 'Export vault')),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Vault: ${widget.vault.name}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text(
                tr(
                  'Eksportuje wszystkie notatki (oprócz kosza) do plików Markdown, odtwarzając strukturę folderów. Zdjęcia trafiają do folderu „_images”, a ukryte notatki do „_hidden”.',
                  'Exports all notes (except the trash) to Markdown files, mirroring the folder structure. Images go to “_images” and hidden notes to “_hidden”.',
                ),
              ),
              if (!_isMobile) ...[
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  key: const Key('choose-export-directory'),
                  onPressed: _busy ? null : _choose,
                  icon: const Icon(Icons.folder_open),
                  label: Text(
                    tr('Wybierz katalog docelowy', 'Choose destination folder'),
                  ),
                ),
                if (_directory != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _directory!,
                      style: const TextStyle(color: muted, fontSize: 12),
                    ),
                  ),
              ] else ...[
                const SizedBox(height: 8),
                Text(
                  tr(
                    'Zostanie utworzony plik ZIP i udostępniony do zapisania lub wysłania.',
                    'A ZIP file will be created and shared for saving or sending.',
                  ),
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              ],
              if (widget.notebook.hiddenPasswordSet) ...[
                const SizedBox(height: 16),
                CheckboxListTile(
                  key: const Key('include-hidden-notes'),
                  contentPadding: EdgeInsets.zero,
                  value: _includeHidden,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() {
                          _includeHidden = value ?? false;
                          _error = null;
                        }),
                  title: Text(
                    tr(
                      'Dołącz ukryte notatki (wymaga hasła)',
                      'Include hidden notes (requires password)',
                    ),
                  ),
                ),
                if (_includeHidden && !widget.notebook.hiddenUnlocked) ...[
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('hidden-notes-password'),
                    controller: _password,
                    enabled: !_busy,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    contextMenuBuilder: siliqueTextContextMenu,
                    decoration: InputDecoration(
                      labelText: tr(
                        'Hasło do ukrytych notatek',
                        'Hidden notes password',
                      ),
                    ),
                  ),
                ],
              ],
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(),
                ),
              if (stats != null && _done) ...[
                const SizedBox(height: 12),
                Text(
                  _summary(stats),
                  key: const Key('vault-export-summary'),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  key: const Key('vault-export-error'),
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(tr('Zamknij', 'Close')),
          ),
          if (!_done)
            FilledButton(
              key: const Key('confirm-vault-export'),
              onPressed: canExport ? _export : null,
              child: Text(tr('Eksportuj', 'Export')),
            ),
        ],
      ),
    );
  }

  String _summary(VaultExportStats stats) {
    if (_isMobile) {
      return tr(
        'ZIP gotowy: ${stats.notes} notatek, ${stats.hidden} ukrytych, ${stats.images} obrazków, ${stats.skippedImages} pominiętych.',
        'ZIP ready: ${stats.notes} notes, ${stats.hidden} hidden, ${stats.images} images, ${stats.skippedImages} skipped.',
      );
    }
    return tr(
      'Wyeksportowano do $_directory: ${stats.notes} notatek, ${stats.hidden} ukrytych, ${stats.folders} folderów, ${stats.images} obrazków, ${stats.skippedImages} pominiętych.',
      'Exported to $_directory: ${stats.notes} notes, ${stats.hidden} hidden, ${stats.folders} folders, ${stats.images} images, ${stats.skippedImages} skipped.',
    );
  }
}