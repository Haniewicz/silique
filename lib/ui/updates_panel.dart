import '../l10n/app_language.dart';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/updates.dart';
import '../services/app_updates.dart';
import 'theme.dart';

class UpdatesPanel extends StatelessWidget {
  const UpdatesPanel({
    super.key,
    required this.updater,
    required this.beforeInstall,
  });
  final AppUpdater updater;
  final Future<void> Function() beforeInstall;
  @override
  Widget build(BuildContext context) {
    Localizations.localeOf(context);
    return AnimatedBuilder(
      animation: updater,
      builder: (context, _) {
        final installed = updater.installed;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('AKTUALIZACJE', 'UPDATES'),
              style: TextStyle(fontSize: 11, letterSpacing: 1.3, color: muted),
            ),
            const SizedBox(height: 8),
            Text(
              installed == null
                  ? 'Silique'
                  : 'Silique ${installed.version} (build ${installed.build})',
              key: const Key('installed-version'),
            ),
            const SizedBox(height: 10),
            if (updater.available) ...[
              if (installed?.platform == 'windows')
                Text(
                  tr(
                    'Instalator wymaga zgody administratora (UAC: nieznany wydawca — brak podpisu Authenticode). Po zapisaniu notatek i uruchomieniu instalatora Silique zostanie zamknięte. Potwierdź instalację w jego oknie; potem uruchom aplikację ze skrótu.',
                    'The installer requires administrator permission (UAC: unknown publisher — no Authenticode signature). Silique will close after saving notes and launching the installer. Confirm installation in its window, then launch the app from its shortcut.',
                  ),
                  style: TextStyle(fontSize: 11, color: muted, height: 1.5),
                ),
              Text(
                tr(
                  'Dostępna wersja ${updater.release!.version}',
                  'Version ${updater.release!.version} available',
                ),
                key: const Key('available-update'),
                style: const TextStyle(color: accent),
              ),
              if (updater.release!.notes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    updater.release!.notes,
                    maxLines: 12,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, height: 1.5),
                  ),
                ),
              const SizedBox(height: 10),
              FilledButton.icon(
                key: const Key('install-update'),
                onPressed: updater.busy
                    ? null
                    : () => updater.install(beforeInstall: beforeInstall),
                icon: const Icon(Icons.system_update_outlined, size: 18),
                label: Text(tr('Zainstaluj aktualizację', 'Install update')),
              ),
            ],
            if (updater.stage == UpdateStage.downloading) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: updater.progress),
              Text(
                tr(
                  'Pobieranie: ${(updater.progress * 100).round()}%',
                  'Downloading: ${(updater.progress * 100).round()}%',
                ),
                style: const TextStyle(fontSize: 12),
              ),
              TextButton(
                onPressed: updater.cancelDownload,
                child: Text(tr('Anuluj pobieranie', 'Cancel download')),
              ),
            ],
            if (updater.message != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  updater.message!,
                  key: const Key('update-message'),
                  style: const TextStyle(fontSize: 12, height: 1.5),
                ),
              ),
            if (installed?.supported == true)
              OutlinedButton.icon(
                key: const Key('check-updates'),
                onPressed: updater.busy ? null : () => updater.check(),
                icon: updater.stage == UpdateStage.checking
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 17),
                label: Text(
                  updater.stage == UpdateStage.checking
                      ? tr('Sprawdzanie…', 'Checking…')
                      : tr('Sprawdź aktualizacje', 'Check for updates'),
                ),
              ),
            TextButton(
              onPressed: () => launchUrl(
                publicReleasesPage,
                mode: LaunchMode.externalApplication,
              ),
              child: Text(tr('Otwórz stronę wydań', 'Open releases page')),
            ),
            Text(
              installed?.supported == true
                  ? tr(
                      'Aktualizacje sprawdzają się automatycznie po uruchomieniu i co 6 godzin. Pobranie i instalacja rozpoczynają się po Twoim wyborze.',
                      'Updates are checked automatically at startup and every 6 hours. Download and installation start only when you choose.',
                    )
                  : tr(
                      'Nowe wersje dla tego systemu pobierzesz ze strony wydań.',
                      'Download new versions for this system from the releases page.',
                    ),
              style: const TextStyle(fontSize: 11, color: muted, height: 1.5),
            ),
          ],
        );
      },
    );
  }
}
