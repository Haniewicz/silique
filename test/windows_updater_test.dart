import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/core/updates.dart';
import 'package:silique/services/app_updates.dart';
import 'package:silique/services/windows_update_handoff.dart';
import 'package:silique/storage/startup_notebook.dart';

import 'update_quiescence_test.dart' show Keys;

import 'package:silique/storage/native_updates.dart';
import 'package:flutter/material.dart';
import 'package:silique/ui/updates_panel.dart';

class WindowsInstaller implements UpdateInstaller, WindowsUpdateInstaller {
  WindowsInstaller(this.directory, this.events, {this.platform = 'windows'});
  final String directory;
  final String platform;
  final List<String> events;
  WindowsInstallOutcome outcome = WindowsInstallOutcome.launched;
  Future<void> Function()? onNative;
  @override
  Future<InstalledApp?> info() async => InstalledApp('0.2.31', 40, platform);
  @override
  Future<String> downloadDirectory() async => directory;
  @override
  Future<void> installMac() async => throw StateError('wrong installer');
  @override
  Future<String> installAndroid(String path) async =>
      throw StateError('wrong installer');
  @override
  Future<WindowsInstallOutcome> installWindows(
    String path,
    AppRelease release,
    UpdateArtifact artifact,
  ) async {
    expectSync(File(path).readAsBytesSync(), [1, 2, 3]);
    expectSync(release.build, 41);
    expectSync(artifact.size, 3);
    events.add('native');
    await onNative?.call();
    return outcome;
  }
}

class Handoff implements WindowsUpdateHandoff {
  Handoff(this.events);
  final List<String> events;
  @override
  Future<void> commit() async => events.add('commit');
  @override
  Future<void> abort() async => events.add('abort');
}

Future<({AppUpdater updater, WindowsInstaller installer, List<String> events})>
fixture({
  String platform = 'windows',
  List<int> body = const [1, 2, 3],
  int build = 41,
  bool tampered = false,
  String? url,
}) async {
  final directory = Directory.systemTemp.createTempSync(
    'silique-windows-signed-',
  );
  addTearDown(() => directory.deleteSync(recursive: true));
  final events = <String>[];
  final installer = WindowsInstaller(
    directory.path,
    events,
    platform: platform,
  );
  final pair = await Ed25519().newKeyPair();
  final hash = (await Sha256().hash([1, 2, 3])).bytes
      .map((v) => v.toRadixString(16).padLeft(2, '0'))
      .join();
  final payload = utf8.encode(
    jsonEncode({
      'schema': 1,
      'version': '0.2.32',
      'build': build,
      'notes': '',
      'platforms': {
        'windows': {
          'url':
              url ??
              'https://github.com/$updateRepository/releases/download/v0.2.32/Silique-0.2.32-Setup-Windows-x64.exe',
          'sha256': hash,
          'size': 3,
        },
      },
    }),
  );
  final signature = (await Ed25519().sign(
    payload,
    keyPair: pair,
  )).bytes.toList();
  if (tampered) signature[0] ^= 1;
  final envelope = jsonEncode({
    'payload': base64Encode(payload),
    'signature': base64Encode(signature),
  });
  final updater = AppUpdater(
    installer: installer,
    client: UpdateClient(
      publicKey: base64Encode((await pair.extractPublicKey()).bytes),
      clientFactory: () => MockClient((request) async {
        expect(request.headers.keys, isNot(contains('authorization')));
        if (request.url == updateFeed) return http.Response(envelope, 200);
        events.add('download');
        return http.Response.bytes(body, 200);
      }),
    ),
    prepareWindowsInstall: () async {
      events.add('prepare');
      return Handoff(events);
    },
  );
  await updater.initialize();
  await updater.check();
  return (updater: updater, installer: installer, events: events);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final disposeDuringLaunch in [false, true]) {
    test(
      'launched Setup with failed close keeps real notebook and input fenced (disposed=$disposeDuringLaunch)',
      () async {
        final f = await fixture();
        if (!disposeDuringLaunch) addTearDown(f.updater.dispose);
        final repo = await openStartupNotebook(
          f.installer.directory,
          keys: Keys(),
        );
        addTearDown(repo.close);
        final blocked = <bool>[];
        var closes = 0;
        f.updater.prepareWindowsInstall = () async {
          f.events.add('prepare');
          return PreparedWindowsUpdate.prepare(
            notebook: repo,
            blockInput: blocked.add,
            beforeClose: () async {},
            close: () async {
              closes++;
              if (closes == 1) throw StateError('window close failed');
            },
          );
        };
        if (disposeDuringLaunch) {
          f.installer.onNative = () async => f.updater.dispose();
        }
        await f.updater.install(beforeInstall: () async {});
        expect(f.updater.stage.name, 'closeRequired');
        expect(blocked, [true]);
        await expectLater(
          repo.createVault('Rejected after launch'),
          throwsStateError,
        );
        await f.updater.install(
          beforeInstall: () async => fail('must not reprepare'),
        );
        await f.updater.check();
        expect(f.events, ['download', 'prepare', 'native']);
        if (!disposeDuringLaunch) {
          expect(f.updater.message, contains('Instalator został uruchomiony'));
          await f.updater.retryWindowsClose();
          expect(closes, 2);
          expect(f.updater.stage, UpdateStage.installing);
          await f.updater.install(
            beforeInstall: () async => fail('must not relaunch'),
          );
          expect(f.events, ['download', 'prepare', 'native']);
          expect(blocked, [true]);
          await expectLater(
            repo.createVault('Rejected after close retry'),
            throwsStateError,
          );
        }
      },
    );
  }

  test('download cancellation never prepares or launches Setup', () async {
    final f = await fixture();
    addTearDown(f.updater.dispose);
    f.updater.addListener(() {
      if (f.updater.stage == UpdateStage.downloading) {
        f.updater.cancelDownload();
      }
    });
    await f.updater.install(beforeInstall: () async {});
    expect(f.events, isNot(contains('prepare')));
    expect(f.events, isNot(contains('native')));
    expect(Directory(f.installer.directory).listSync(), isEmpty);
  });
  test(
    'successful launch still commits a prepared session after updater disposal',
    () async {
      final f = await fixture();
      final entered = Completer<void>(), release = Completer<void>();
      f.installer.onNative = () async {
        entered.complete();
        await release.future;
      };
      final task = f.updater.install(beforeInstall: () async {});
      await entered.future;
      f.updater.dispose();
      release.complete();
      await task;
      expect(f.events, ['download', 'prepare', 'native', 'commit']);
    },
  );
  test(
    'Windows save failure never enters native installer or closes the app',
    () async {
      final f = await fixture();
      addTearDown(f.updater.dispose);
      await f.updater.install(
        beforeInstall: () async {
          throw StateError('save failed');
        },
      );
      expect(f.events, ['download']);
      expect(f.updater.busy, isFalse);
    },
  );
  test('UAC cancellation and native failure abort preparation without commit or silent retry', () async {
    for (final outcome in [
      WindowsInstallOutcome.cancelled,
      WindowsInstallOutcome.failed,
    ]) {
      final f = await fixture();
      f.installer.outcome = outcome;
      await f.updater.install(beforeInstall: () async {});
      expect(f.events, ['download', 'prepare', 'native', 'abort']);
      expect(f.updater.message, contains('pozostaje otwarte'));
      f.updater.dispose();
    }
  });
  test('forged manifest, wrong bytes and a ZIP substituted for Setup never reach native', () async {
    for (final args in [
      (forged: true, body: <int>[1, 2, 3], url: null),
      (forged: false, body: <int>[3, 2, 1], url: null),
      (
        forged: false,
        body: <int>[1, 2, 3],
        url:
            'https://github.com/$updateRepository/releases/download/v0.2.32/Silique-0.2.32-Windows-x64.zip',
      ),
    ]) {
      final f = await fixture(
        tampered: args.forged,
        body: args.body,
        url: args.url,
      );
      await f.updater.install(beforeInstall: () async {});
      expect(f.events, isNot(contains('native')));
      expect(f.events, isNot(contains('prepare')));
      f.updater.dispose();
    }
  });
  test('portable and older/equal builds never download or install', () async {
    for (final selection in [
      (platform: 'windows-portable', build: 41),
      (platform: 'windows', build: 40),
      (platform: 'windows', build: 39),
    ]) {
      final f = await fixture(
        platform: selection.platform,
        build: selection.build,
      );
      await f.updater.install(beforeInstall: () async {});
      expect(f.updater.available, isFalse);
      expect(f.events, isEmpty);
      f.updater.dispose();
    }
  });
  test(
    'dispose while preparation is pending aborts and never launches native',
    () async {
      final f = await fixture();
      final entered = Completer<void>(), release = Completer<void>();
      f.updater.prepareWindowsInstall = () async {
        entered.complete();
        await release.future;
        return Handoff(f.events);
      };
      final task = f.updater.install(beforeInstall: () async {});
      await entered.future;
      f.updater.dispose();
      release.complete();
      await task;
      expect(f.events, ['download', 'abort']);
    },
  );
  test(
    'Windows package metadata comes from the native machine-install identity',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeUpdateInstaller.channel, (
            call,
          ) async {
            expect(call.method, 'info');
            return {
              'version': '0.2.32',
              'build': 41,
              'platform': 'windows-portable',
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeUpdateInstaller.channel, null),
      );
      final dynamic installer = NativeUpdateInstaller();
      final InstalledApp app = await installer.windowsInfo();
      expect(app.version, '0.2.32');
      expect(app.supported, isFalse);
    },
  );
  test('native Windows bridge passes verification metadata, never a shell command', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeUpdateInstaller.channel, (call) async {
          calls.add(call);
          return 'cancelled';
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeUpdateInstaller.channel, null),
    );
    final artifact = UpdateArtifact(
      url: Uri.parse(
        'https://github.com/$updateRepository/releases/download/v0.2.32/Silique-0.2.32-Setup-Windows-x64.exe',
      ),
      sha256: 'a' * 64,
      size: 10,
    );
    final release = AppRelease(
      version: '0.2.32',
      build: 41,
      notes: '',
      artifacts: {'windows': artifact},
    );
    final dynamic installer = NativeUpdateInstaller();
    expect(
      await installer.installWindows(
        r'C:\cache & literal\Silique-41.exe',
        release,
        artifact,
      ),
      WindowsInstallOutcome.cancelled,
    );
    expect(calls.single.method, 'installWindows');
    expect(calls.single.arguments, {
      'path': r'C:\cache & literal\Silique-41.exe',
      'version': '0.2.32',
      'build': 41,
      'sha256': 'a' * 64,
      'size': 10,
    });
  });
  test('verified Setup waits for reversible save barrier before native launch and commit', () async {
    final directory = Directory.systemTemp.createTempSync('silique-win-flow-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final events = <String>[];
    final installer = WindowsInstaller(directory.path, events);
    final updater = AppUpdater(
      installer: installer,
      client: UpdateClient(
        clientFactory: () => MockClient((_) async {
          events.add('download');
          return http.Response.bytes([1, 2, 3], 200);
        }),
      ),
      prepareWindowsInstall: () async {
        events.add('prepare');
        return Handoff(events);
      },
    );
    addTearDown(updater.dispose);
    await updater.initialize();
    updater.release = AppRelease(
      version: '0.2.32',
      build: 41,
      notes: '',
      artifacts: {
        'windows': UpdateArtifact(
          url: Uri.parse(
            'https://github.com/$updateRepository/releases/download/v0.2.32/Silique-0.2.32-Setup-Windows-x64.exe',
          ),
          sha256: (await Sha256().hash([1, 2, 3])).bytes
              .map((v) => v.toRadixString(16).padLeft(2, '0'))
              .join(),
          size: 3,
        ),
      },
    );
    await updater.install(beforeInstall: () async => events.add('save'));
    expect(events, ['download', 'save', 'prepare', 'native', 'commit']);
    expect(updater.message, isNot(contains('Zainstalowano')));
  });
  test('Windows EXE download verifies bytes before publishing the final file', () async {
    final directory = Directory.systemTemp.createTempSync(
      'silique-win-update-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final bytes = [1, 2, 3];
    final digest = (await Sha256().hash(bytes)).bytes
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
    final client = UpdateClient(
      clientFactory: () =>
          MockClient((_) async => http.Response.bytes(bytes, 200)),
    );
    final file = await client.download(
      UpdateArtifact(
        url: Uri.parse(
          'https://github.com/$updateRepository/releases/download/v0.2.32/Silique-0.2.32-Setup-Windows-x64.exe',
        ),
        sha256: digest,
        size: bytes.length,
      ),
      directory,
      build: 41,
      onProgress: (_) {},
      cancelled: Completer<void>().future,
    );
    expect(file.path, endsWith('Silique-41.exe'));
    expect(file.readAsBytesSync(), bytes);
    expect(directory.listSync().length, 1);
  });
  test('signed Windows Setup is canonical, ZIP remains a manual artifact', () async {
    final pair = await Ed25519().newKeyPair();
    final payload = utf8.encode(
      jsonEncode({
        'schema': 1,
        'version': '0.2.32',
        'build': 41,
        'notes': '',
        'platforms': {
          'windows': {
            'url':
                'https://github.com/$updateRepository/releases/download/v0.2.32/Silique-0.2.32-Setup-Windows-x64.exe',
            'sha256': 'a' * 64,
            'size': 10,
          },
        },
      }),
    );
    final signature = await Ed25519().sign(payload, keyPair: pair);
    final release = await AppRelease.verify(
      jsonEncode({
        'payload': base64Encode(payload),
        'signature': base64Encode(signature.bytes),
      }),
      publicKey: base64Encode((await pair.extractPublicKey()).bytes),
    );
    expect(release.artifacts['windows']?.size, 10);
    expect(const InstalledApp('0.2.31', 40, 'windows').supported, isTrue);
    expect(
      const InstalledApp('0.2.31', 40, 'windows-portable').supported,
      isFalse,
    );
  });

  test('higher build cannot offer an older Windows version', () {
    final updater = AppUpdater();
    addTearDown(updater.dispose);
    updater.installed = const InstalledApp('0.2.32', 41, 'windows');
    updater.release = AppRelease(
      version: '0.2.31',
      build: 42,
      notes: '',
      artifacts: {
        'windows': UpdateArtifact(
          url: Uri.parse('https://example.invalid'),
          sha256: 'a' * 64,
          size: 1,
        ),
      },
    );
    expect(updater.available, isFalse);
  });

  testWidgets(
    'Windows explains UAC unknown publisher before explicit install',
    (tester) async {
      final updater = AppUpdater();
      updater.installed = const InstalledApp('0.2.31', 40, 'windows');
      updater.release = AppRelease(
        version: '0.2.32',
        build: 41,
        notes: '',
        artifacts: {
          'windows': UpdateArtifact(
            url: Uri.parse('https://example.invalid'),
            sha256: 'a' * 64,
            size: 1,
          ),
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UpdatesPanel(updater: updater, beforeInstall: () async {}),
          ),
        ),
      );
      expect(find.textContaining('nieznany wydawca'), findsOneWidget);
      expect(find.textContaining('Silique zostanie zamknięte'), findsOneWidget);
      updater.dispose();
    },
  );
}
