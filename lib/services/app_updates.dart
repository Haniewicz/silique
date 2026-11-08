import '../l10n/strings.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/updates.dart';
import '../storage/native_updates.dart';

/// The only file extensions the updater writes: a native package for the
/// verified Android/Linux installers. Derived from the signed artifact URL so a
/// download's name always matches the manifest and a portable tar (`.gz`) is
/// never mistaken for an installable package.
const _installableExtensions = {'.apk', '.deb', '.rpm', '.exe'};

String artifactExtension(Uri url) {
  final path = url.path;
  final dot = path.lastIndexOf('.');
  final extension = dot < 0 ? '' : path.substring(dot);
  if (!_installableExtensions.contains(extension)) {
    throw FormatException(
      tr('Nieprawidłowy plik aktualizacji.', 'Invalid update file.'),
    );
  }
  return extension;
}

class UpdateClient {
  UpdateClient({
    http.Client Function()? clientFactory,
    this.publicKey = updatePublicKey,
  }) : _factory = clientFactory ?? http.Client.new;
  final http.Client Function() _factory;
  final String publicKey;

  Future<AppRelease> latest() async {
    final client = _factory();
    try {
      return await (() async {
        final response = await client.send(
          http.Request('GET', updateFeed)
            ..headers['Accept'] = 'application/json',
        );
        if (response.statusCode != 200) {
          throw HttpException(
            tr(
              'Brak informacji o wydaniu.',
              'No release information available.',
            ),
          );
        }
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          bytes.addAll(chunk);
          if (bytes.length > 128 * 1024) {
            throw FormatException(
              tr(
                'Nieprawidłowa informacja o wydaniu.',
                'Invalid release information.',
              ),
            );
          }
        }
        return AppRelease.verify(utf8.decode(bytes), publicKey: publicKey);
      })().timeout(const Duration(seconds: 20));
    } finally {
      client.close();
    }
  }

  Future<File> download(
    UpdateArtifact artifact,
    Directory directory, {
    required int build,
    required void Function(double) onProgress,
    required Future<void> cancelled,
  }) async {
    await directory.create(recursive: true);
    final target = File(
      '${directory.path}/Silique-$build${artifactExtension(artifact.url)}',
    );
    final partial = File('${target.path}.part');
    final client = _factory();
    IOSink? output;
    var stopped = false;
    var expired = false;
    cancelled.then((_) {
      stopped = true;
      client.close();
    });
    final deadline = Timer(const Duration(minutes: 10), () {
      expired = true;
      client.close();
    });
    try {
      if (await target.exists() && await target.length() == artifact.size) {
        final cachedHash = Sha256().newHashSink();
        await for (final chunk in target.openRead()) {
          if (stopped) throw const UpdateCancelled();
          cachedHash.add(chunk);
        }
        cachedHash.close();
        final cachedDigest = (await cachedHash.hash()).bytes
            .map((v) => v.toRadixString(16).padLeft(2, '0'))
            .join();
        if (cachedDigest == artifact.sha256) {
          if (stopped) throw const UpdateCancelled();
          onProgress(1);
          return target;
        }
      }
      final response = await client
          .send(
            http.Request('GET', artifact.url)
              ..headers['Accept-Encoding'] = 'identity',
          )
          .timeout(const Duration(seconds: 20));
      if (stopped) throw const UpdateCancelled();
      if (response.statusCode != 200 ||
          (response.contentLength != null &&
              response.contentLength != artifact.size)) {
        throw FormatException(
          tr(
            'Serwer zwrócił nieprawidłowy plik aktualizacji.',
            'The server returned an invalid update file.',
          ),
        );
      }
      output = partial.openWrite();
      final hash = Sha256().newHashSink();
      var received = 0;
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        if (stopped) throw const UpdateCancelled();
        if (expired) {
          throw TimeoutException(
            tr('Pobieranie trwało zbyt długo.', 'The download took too long.'),
          );
        }
        received += chunk.length;
        if (received > artifact.size) {
          throw FormatException(
            tr(
              'Plik aktualizacji jest zbyt duży.',
              'The update file is too large.',
            ),
          );
        }
        output.add(chunk);
        await output.flush();
        hash.add(chunk);
        onProgress(received / artifact.size);
      }
      await output.flush();
      await output.close();
      output = null;
      hash.close();
      final digest = (await hash.hash()).bytes
          .map((v) => v.toRadixString(16).padLeft(2, '0'))
          .join();
      if (stopped) throw const UpdateCancelled();
      if (expired) {
        throw TimeoutException(
          tr('Pobieranie trwało zbyt długo.', 'The download took too long.'),
        );
      }
      if (received != artifact.size || digest != artifact.sha256) {
        throw FormatException(
          tr(
            'Plik aktualizacji jest niekompletny lub uszkodzony.',
            'The update file is incomplete or corrupted.',
          ),
        );
      }
      if (await target.exists()) await target.delete();
      return await partial.rename(target.path);
    } catch (_) {
      if (stopped) throw const UpdateCancelled();
      rethrow;
    } finally {
      deadline.cancel();
      client.close();
      await output?.close();
      if (await partial.exists()) await partial.delete();
    }
  }
}

class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

enum UpdateStage { idle, checking, downloading, installing, closeRequired }

class AppUpdater extends ChangeNotifier {
  AppUpdater({
    UpdateClient? client,
    UpdateInstaller? installer,
    this.prepareWindowsInstall,
    this.restartAfterInstall,
  }) : _client = client ?? UpdateClient(),
       _installer = installer ?? NativeUpdateInstaller();
  final UpdateClient _client;
  final UpdateInstaller _installer;
  Future<WindowsUpdateHandoff> Function()? prepareWindowsInstall;
  Future<void> Function()? restartAfterInstall;
  InstalledApp? installed;
  AppRelease? release;
  UpdateStage stage = UpdateStage.idle;
  String Function()? _message;

  /// Resolve app-owned copy on read so an existing result follows UI language
  /// changes without repeating an update check, download, or installation.
  String? get message => _message?.call();

  /// Preserve the public nullable-string API for callers supplying literal copy.
  set message(String? value) => _message = value == null ? null : () => value;
  double progress = 0;
  Timer? _poll, _firstCheck;
  Completer<void>? _cancel;
  bool _disposed = false;
  WindowsUpdateHandoff? _launchedWindowsHandoff;
  bool _restartStarted = false;
  bool get busy => stage != UpdateStage.idle;
  bool get available =>
      installed != null &&
      installed!.supported &&
      release != null &&
      release!.build > installed!.build &&
      (installed!.platform != 'windows' ||
          _notOlderVersion(release!.version, installed!.version)) &&
      release!.artifacts.containsKey(installed!.platform);

  static bool _notOlderVersion(String next, String current) {
    final pattern = RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}$');
    if (!pattern.hasMatch(next) || !pattern.hasMatch(current)) return false;
    final a = next.split('.').map(int.parse).toList();
    final b = current.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return true;
  }

  Future<void> initialize() async {
    try {
      installed = await _installer.info();
    } catch (_) {
      return;
    }
    if (_disposed) return;
    _changed();
    if (installed?.supported != true) return;
    _firstCheck = Timer(
      const Duration(seconds: 8),
      () => unawaited(check(quiet: true)),
    );
    _poll = Timer.periodic(
      const Duration(hours: 6),
      (_) => unawaited(check(quiet: true)),
    );
  }

  Future<void> check({bool quiet = false}) async {
    if (_disposed || busy || installed?.supported != true) return;
    stage = UpdateStage.checking;
    message = null;
    _changed();
    try {
      final found = await _client.latest();
      if (_disposed) return;
      release = found;
      if (!quiet) {
        _message = available
            ? () => tr(
                'Dostępna jest wersja ${found.version}.',
                'Version ${found.version} is available.',
              )
            : () =>
                  tr('Masz najnowszą wersję.', 'You have the latest version.');
      }
    } catch (_) {
      if (!quiet && !_disposed) {
        _message = () => tr(
          'Nie udało się sprawdzić aktualizacji. Sprawdź połączenie i spróbuj ponownie.',
          'Could not check for updates. Check your connection and try again.',
        );
      }
    } finally {
      stage = UpdateStage.idle;
      _changed();
    }
  }

  Future<void> install({required Future<void> Function() beforeInstall}) async {
    if (_disposed || busy || !available) return;
    final selected = release!;
    final app = installed!;
    message = null;
    _cancel = Completer<void>();
    try {
      if (app.platform == 'macos') {
        stage = UpdateStage.installing;
        _changed();
        await beforeInstall();
        await _installer.installMac();
        if (!_disposed) {
          _message = () => tr(
            'Aktualizację obsługuje okno instalatora Silique.',
            'The Silique installer window handles the update.',
          );
        }
      } else if (app.platform == 'android') {
        final file = await _download(selected, selected.artifacts['android']!);
        if (_disposed || _cancel!.isCompleted) return;
        stage = UpdateStage.installing;
        _changed();
        await beforeInstall();
        if (_disposed || _cancel!.isCompleted) return;
        final result = await _installer.installAndroid(file.path);
        if (!_disposed) {
          _message = () => result == 'permission_required'
              ? tr(
                  'Zezwól Silique na instalowanie aktualizacji, wróć tutaj i naciśnij „Zainstaluj aktualizację” ponownie.',
                  'Allow Silique to install updates, return here and press “Install update” again.',
                )
              : tr(
                  'Potwierdź aktualizację w systemowym instalatorze.',
                  'Confirm the update in the system installer.',
                );
        }
      } else if (InstalledApp.packagedLinux.contains(app.platform)) {
        await _installLinux(selected, app, beforeInstall);
      } else if (app.platform == 'windows') {
        final installer = _installer;
        final prepare = prepareWindowsInstall;
        if (installer is! WindowsUpdateInstaller || prepare == null) return;
        final artifact = selected.artifacts['windows']!;
        final file = await _download(selected, artifact);
        if (_disposed || _cancel!.isCompleted) return;
        stage = UpdateStage.installing;
        _changed();
        await beforeInstall();
        if (_disposed || _cancel!.isCompleted) return;
        final handoff = await prepare();
        var launched = false;
        try {
          if (_disposed || _cancel!.isCompleted) return;
          final outcome = await (installer as WindowsUpdateInstaller)
              .installWindows(file.path, selected, artifact);
          // After a successful launch the prepared session must commit even if
          // the settings/updater was disposed while the native UAC was open.
          if (outcome == WindowsInstallOutcome.launched) {
            // Latch before awaiting close: native launch cannot be undone by
            // abort, disposal, or a window-destruction error.
            launched = true;
            _launchedWindowsHandoff = handoff;
            await _closeLaunchedWindowsUpdate();
          }
          if (!_disposed && !launched) {
            _message = () => switch (outcome) {
              WindowsInstallOutcome.launched => tr(
                'Uruchomiono instalator. Potwierdź instalację w jego oknie, a następnie uruchom Silique ze skrótu.',
                'The installer has started. Confirm installation in its window, then launch Silique from its shortcut.',
              ),
              WindowsInstallOutcome.cancelled => tr(
                'Instalacja anulowana. Silique pozostaje otwarte.',
                'Installation cancelled. Silique remains open.',
              ),
              WindowsInstallOutcome.failed => tr(
                'Nie udało się uruchomić instalatora. Silique pozostaje otwarte.',
                'Could not start the installer. Silique remains open.',
              ),
            };
          }
        } finally {
          if (!launched) await handoff.abort();
        }
      } else {
        // A portable tar or any unknown format is never installed from here.
        return;
      }
    } on UpdateCancelled {
      if (!_disposed) {
        _message = () => tr('Pobieranie anulowane.', 'Download cancelled.');
      }
    } catch (_) {
      if (!_disposed) {
        _message = () => tr(
          'Nie udało się przygotować aktualizacji. Sprawdź zapis notatek i spróbuj ponownie.',
          'Could not prepare the update. Check that your notes are saved and try again.',
        );
      }
    } finally {
      _cancel = null;
      if (_launchedWindowsHandoff == null) stage = UpdateStage.idle;
      _changed();
    }
  }

  /// Retry only the prepared window close, never the download or native launch.
  Future<void> retryWindowsClose() async {
    if (_disposed || stage != UpdateStage.closeRequired) return;
    await _closeLaunchedWindowsUpdate();
  }

  Future<void> _closeLaunchedWindowsUpdate() async {
    stage = UpdateStage.installing;
    _message = () => tr(
      'Instalator został uruchomiony. Zamykanie Silique…',
      'The installer has started. Closing Silique…',
    );
    _changed();
    try {
      await _launchedWindowsHandoff!.commit();
      _message = () => tr(
        'Uruchomiono instalator. Potwierdź instalację w jego oknie, a następnie uruchom Silique ze skrótu.',
        'The installer has started. Confirm installation in its window, then launch Silique from its shortcut.',
      );
    } catch (_) {
      stage = UpdateStage.closeRequired;
      _message = () => tr(
        'Instalator został uruchomiony, ale nie udało się zamknąć Silique. Notatki pozostają zablokowane dla bezpieczeństwa. Ponów zamknięcie; instalator nie zostanie uruchomiony ponownie. Jeśli problem się powtarza, zakończ Silique w Menedżerze zadań i dokończ instalację w otwartym oknie instalatora.',
        'The installer has started, but Silique could not close. Notes remain locked for safety. Retry closing; the installer will not be started again. If the problem persists, end Silique in Task Manager and finish installation in the open installer window.',
      );
    }
    _changed();
  }

  Future<File> _download(AppRelease release, UpdateArtifact artifact) async {
    stage = UpdateStage.downloading;
    progress = 0;
    _changed();
    return _client.download(
      artifact,
      Directory(await _installer.downloadDirectory()),
      build: release.build,
      onProgress: (value) {
        progress = value;
        _changed();
      },
      cancelled: _cancel!.future,
    );
  }

  /// Confirmed RPM/DEB installation: download and verify, flush the notes,
  /// then hand only the absolute verified path to the system pkexec installer.
  Future<void> _installLinux(
    AppRelease release,
    InstalledApp app,
    Future<void> Function() beforeInstall,
  ) async {
    final linux = _installer;
    if (linux is! LinuxUpdateInstaller) {
      _message = () => tr(
        'Ten system nie obsługuje automatycznej instalacji. Pobierz nową wersję ze strony wydań.',
        'This system does not support automatic installation. Download the new version from the releases page.',
      );
      return;
    }
    final file = await _download(release, release.artifacts[app.platform]!);
    if (_disposed || _cancel!.isCompleted) return;
    stage = UpdateStage.installing;
    _changed();
    await beforeInstall();
    if (_disposed || _cancel!.isCompleted) return;
    final outcome = await (linux as LinuxUpdateInstaller).installLinux(
      app.platform,
      file.path,
    );
    if (_disposed) return;
    if (outcome == LinuxInstallOutcome.installed &&
        restartAfterInstall != null &&
        !_restartStarted) {
      _restartStarted = true;
      try {
        await restartAfterInstall!();
        if (_disposed) return;
        _message = () => tr(
          'Zainstalowano wersję ${release.version}. Nowa wersja uruchamia się ponownie.',
          'Version ${release.version} has been installed. The new version is restarting.',
        );
      } catch (_) {
        if (_disposed) return;
        _message = () => tr(
          'Zainstalowano wersję ${release.version}. Uruchom Silique ponownie, aby korzystać z nowej wersji.',
          'Version ${release.version} has been installed. Restart Silique to use the new version.',
        );
      }
      return;
    }
    _message = () => switch (outcome) {
      LinuxInstallOutcome.installed => tr(
        'Zainstalowano wersję ${release.version}. Uruchom Silique ponownie, aby korzystać z nowej wersji.',
        'Version ${release.version} has been installed. Restart Silique to use the new version.',
      ),
      LinuxInstallOutcome.cancelled => tr(
        'Instalacja anulowana — autoryzacja administratora została odrzucona. Nic nie zostało zmienione.',
        'Installation cancelled — administrator authorization was denied. Nothing was changed.',
      ),
      LinuxInstallOutcome.failed => tr(
        'Nie udało się zainstalować aktualizacji. Pobierz nową wersję ze strony wydań.',
        'Could not install the update. Download the new version from the releases page.',
      ),
    };
  }

  void cancelDownload() {
    if (_cancel?.isCompleted == false) _cancel!.complete();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _firstCheck?.cancel();
    cancelDownload();
    super.dispose();
  }
}
