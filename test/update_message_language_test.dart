import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/updates.dart';
import 'package:silique/l10n/app_language.dart';
import 'package:silique/services/app_updates.dart';
import 'package:silique/ui/updates_panel.dart';

class _UpdateClient extends UpdateClient {
  int checks = 0;
  int downloads = 0;
  bool offline = false;
  bool cancel = false;
  int build = 43;

  @override
  Future<AppRelease> latest() async {
    checks++;
    if (offline) throw const SocketException('offline');
    return AppRelease(
      version: '0.2.34',
      build: build,
      notes: 'User-authored release notes: Żółć',
      artifacts: {
        for (final platform in ['macos', 'android', 'windows', 'linux-deb'])
          platform: UpdateArtifact(
            url: Uri.https('example.invalid', '/verified-update'),
            sha256: '0' * 64,
            size: 1,
          ),
      },
    );
  }

  @override
  Future<File> download(
    UpdateArtifact artifact,
    Directory directory, {
    required int build,
    required void Function(double) onProgress,
    required Future<void> cancelled,
  }) async {
    downloads++;
    if (cancel) throw const UpdateCancelled();
    onProgress(1);
    // This seam returns a verified-file stand-in without network or disk writes.
    return File('${directory.path}/verified-update');
  }
}

class _Installer
    implements UpdateInstaller, LinuxUpdateInstaller, WindowsUpdateInstaller {
  int installs = 0;
  String androidResult = 'started';
  LinuxInstallOutcome linuxResult = LinuxInstallOutcome.installed;
  WindowsInstallOutcome windowsResult = WindowsInstallOutcome.launched;

  @override
  Future<InstalledApp?> info() async => null;
  @override
  Future<String> downloadDirectory() async => '/fixture/update-cache';
  @override
  Future<void> installMac() async => installs++;
  @override
  Future<String> installAndroid(String path) async {
    installs++;
    return androidResult;
  }

  @override
  Future<LinuxInstallOutcome> installLinux(String platform, String path) async {
    installs++;
    return linuxResult;
  }

  @override
  Future<WindowsInstallOutcome> installWindows(
    String path,
    AppRelease release,
    UpdateArtifact artifact,
  ) async {
    installs++;
    return windowsResult;
  }
}

class _Handoff implements WindowsUpdateHandoff {
  int commits = 0;
  int aborts = 0;
  bool failClose = false;

  @override
  Future<void> commit() async {
    commits++;
    if (failClose) throw StateError('window close failed');
  }

  @override
  Future<void> abort() async => aborts++;
}

void main() {
  setUp(() => appLanguage.setLanguage('en'));
  tearDown(() => appLanguage.setLanguage('pl'));

  test(
    'public message API preserves literal strings and null clearing',
    () async {
      final updater = AppUpdater();
      addTearDown(updater.dispose);
      expect(updater.message, isNull);
      updater.message = 'Literal: Żółć / Version 0.2.34 is available.';
      for (final code in ['en', 'pl', 'en']) {
        await appLanguage.setLanguage(code);
        expect(updater.message, 'Literal: Żółć / Version 0.2.34 is available.');
      }
      updater.message = null;
      expect(updater.message, isNull);
    },
  );

  final cases = <({String name, String en, String pl})>[
    (
      name: 'check available',
      en: 'Version 0.2.34 is available.',
      pl: 'Dostępna jest wersja 0.2.34.',
    ),
    (
      name: 'check latest',
      en: 'You have the latest version.',
      pl: 'Masz najnowszą wersję.',
    ),
    (
      name: 'check error',
      en: 'Could not check for updates. Check your connection and try again.',
      pl: 'Nie udało się sprawdzić aktualizacji. Sprawdź połączenie i spróbuj ponownie.',
    ),
    (
      name: 'macos action',
      en: 'The Silique installer window handles the update.',
      pl: 'Aktualizację obsługuje okno instalatora Silique.',
    ),
    (
      name: 'android action',
      en: 'Confirm the update in the system installer.',
      pl: 'Potwierdź aktualizację w systemowym instalatorze.',
    ),
    (
      name: 'android permission',
      en: 'Allow Silique to install updates, return here and press “Install update” again.',
      pl: 'Zezwól Silique na instalowanie aktualizacji, wróć tutaj i naciśnij „Zainstaluj aktualizację” ponownie.',
    ),
    (
      name: 'install error',
      en: 'Could not prepare the update. Check that your notes are saved and try again.',
      pl: 'Nie udało się przygotować aktualizacji. Sprawdź zapis notatek i spróbuj ponownie.',
    ),
    (
      name: 'download cancelled',
      en: 'Download cancelled.',
      pl: 'Pobieranie anulowane.',
    ),
    (
      name: 'linux installed',
      en: 'Version 0.2.34 has been installed. Restart Silique to use the new version.',
      pl: 'Zainstalowano wersję 0.2.34. Uruchom Silique ponownie, aby korzystać z nowej wersji.',
    ),
    (
      name: 'linux cancelled',
      en: 'Installation cancelled — administrator authorization was denied. Nothing was changed.',
      pl: 'Instalacja anulowana — autoryzacja administratora została odrzucona. Nic nie zostało zmienione.',
    ),
    (
      name: 'linux failed',
      en: 'Could not install the update. Download the new version from the releases page.',
      pl: 'Nie udało się zainstalować aktualizacji. Pobierz nową wersję ze strony wydań.',
    ),
    (
      name: 'windows launched',
      en: 'The installer has started. Confirm installation in its window, then launch Silique from its shortcut.',
      pl: 'Uruchomiono instalator. Potwierdź instalację w jego oknie, a następnie uruchom Silique ze skrótu.',
    ),
    (
      name: 'windows cancelled',
      en: 'Installation cancelled. Silique remains open.',
      pl: 'Instalacja anulowana. Silique pozostaje otwarte.',
    ),
    (
      name: 'windows failed',
      en: 'Could not start the installer. Silique remains open.',
      pl: 'Nie udało się uruchomić instalatora. Silique pozostaje otwarte.',
    ),
    (
      name: 'windows close error',
      en: 'The installer has started, but Silique could not close. Notes remain locked for safety. Retry closing; the installer will not be started again. If the problem persists, end Silique in Task Manager and finish installation in the open installer window.',
      pl: 'Instalator został uruchomiony, ale nie udało się zamknąć Silique. Notatki pozostają zablokowane dla bezpieczeństwa. Ponów zamknięcie; instalator nie zostanie uruchomiony ponownie. Jeśli problem się powtarza, zakończ Silique w Menedżerze zadań i dokończ instalację w otwartym oknie instalatora.',
    ),
  ];

  for (final scenario in cases) {
    testWidgets('${scenario.name} message follows EN→PL→EN without replay', (
      tester,
    ) async {
      final client = _UpdateClient()
        ..offline = scenario.name == 'check error'
        ..cancel = scenario.name == 'download cancelled'
        ..build = scenario.name == 'check latest' ? 42 : 43;
      final installer = _Installer()
        ..androidResult = scenario.name == 'android permission'
            ? 'permission_required'
            : 'started'
        ..linuxResult = switch (scenario.name) {
          'linux cancelled' => LinuxInstallOutcome.cancelled,
          'linux failed' => LinuxInstallOutcome.failed,
          _ => LinuxInstallOutcome.installed,
        }
        ..windowsResult = switch (scenario.name) {
          'windows cancelled' => WindowsInstallOutcome.cancelled,
          'windows failed' => WindowsInstallOutcome.failed,
          _ => WindowsInstallOutcome.launched,
        };
      final handoff = _Handoff()
        ..failClose = scenario.name == 'windows close error';
      var preparations = 0;
      var saves = 0;
      final updater =
          AppUpdater(
              client: client,
              installer: installer,
              prepareWindowsInstall: () async {
                preparations++;
                return handoff;
              },
            )
            ..installed = InstalledApp(
              '0.2.33',
              42,
              scenario.name.startsWith('windows')
                  ? 'windows'
                  : scenario.name.startsWith('linux')
                  ? 'linux-deb'
                  : scenario.name.startsWith('macos')
                  ? 'macos'
                  : 'android',
            );
      addTearDown(updater.dispose);
      Future<void> beforeInstall() async {
        saves++;
        if (scenario.name == 'install error') throw StateError('save failed');
      }

      await tester.pumpWidget(
        SiliqueMaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: UpdatesPanel(
                updater: updater,
                beforeInstall: beforeInstall,
              ),
            ),
          ),
        ),
      );
      await updater.check();
      if (!scenario.name.startsWith('check')) {
        await updater.install(beforeInstall: beforeInstall);
      }
      await tester.pumpAndSettle();
      expect(updater.message, scenario.en);
      expect(client.checks, 1);
      final release = updater.release;
      final installed = updater.installed;
      final stage = updater.stage;
      final progress = updater.progress;
      final available = updater.available;
      final busy = updater.busy;
      final calls = (
        client.checks,
        client.downloads,
        installer.installs,
        preparations,
        saves,
        handoff.commits,
        handoff.aborts,
      );
      var notifications = 0;
      updater.addListener(() => notifications++);

      for (final code in ['en', 'pl', 'en']) {
        await tester.runAsync(() => appLanguage.setLanguage(code));
        await tester.pumpAndSettle();
        final expected = code == 'en' ? scenario.en : scenario.pl;
        expect(updater.message, expected);
        expect(
          tester.widget<Text>(find.byKey(const Key('update-message'))).data,
          expected,
        );
        expect(updater.release, same(release));
        expect(updater.installed, same(installed));
        expect(updater.stage, stage);
        expect(updater.progress, progress);
        expect(updater.available, available);
        expect(updater.busy, busy);
        expect((
          client.checks,
          client.downloads,
          installer.installs,
          preparations,
          saves,
          handoff.commits,
          handoff.aborts,
        ), calls);
        expect(notifications, 0);
        if (updater.available) {
          expect(find.text(release!.notes), findsOneWidget);
        }
      }
      if (scenario.name == 'install error') expect(installer.installs, 0);
      if (scenario.name == 'windows close error') {
        expect(updater.stage, UpdateStage.closeRequired);
        expect(updater.busy, isTrue);
        await updater.check();
        await updater.install(beforeInstall: beforeInstall);
        expect(client.checks, 1);
        expect(client.downloads, 1);
        expect(installer.installs, 1);
        expect(preparations, 1);
        expect(handoff.commits, 1);
        expect(handoff.aborts, 0);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
