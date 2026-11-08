import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:silique/ui/updates_panel.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/core/updates.dart';
import 'package:silique/services/app_updates.dart';

class FakeInstaller implements UpdateInstaller {
  FakeInstaller(this.directory, {this.platform = 'android', this.build = 8});
  final String directory, platform;
  final int build;
  int installs = 0;
  String result = 'started';
  @override
  Future<InstalledApp?> info() async => InstalledApp('0.2.4', build, platform);
  @override
  Future<String> downloadDirectory() async => directory;
  @override
  Future<String> installAndroid(String path) async {
    installs++;
    return result;
  }

  @override
  Future<void> installMac() async {
    installs++;
  }
}

class LinuxFakeInstaller implements UpdateInstaller, LinuxUpdateInstaller {
  LinuxFakeInstaller(
    this.directory, {
    this.platform = 'linux-rpm',
    this.build = 8,
  });
  final String directory, platform;
  final int build;
  int installs = 0;
  String? lastPlatform, lastPath;
  LinuxInstallOutcome outcome = LinuxInstallOutcome.installed;
  @override
  Future<InstalledApp?> info() async => InstalledApp('0.2.5', build, platform);
  @override
  Future<String> downloadDirectory() async => directory;
  @override
  Future<String> installAndroid(String path) async => 'started';
  @override
  Future<void> installMac() async {}
  @override
  Future<LinuxInstallOutcome> installLinux(String platform, String path) async {
    installs++;
    lastPlatform = platform;
    lastPath = path;
    return outcome;
  }
}

void main() {
  final algorithm = Ed25519();
  late SimpleKeyPair pair;
  late String publicKey;
  const bytes = [1, 2, 3, 4, 5, 6];
  late String digest;
  late Directory directory;
  setUp(() async {
    pair = await algorithm.newKeyPair();
    publicKey = base64Encode((await pair.extractPublicKey()).bytes);
    digest = (await Sha256().hash(bytes)).bytes
        .map((n) => n.toRadixString(16).padLeft(2, '0'))
        .join();
    directory = Directory.systemTemp.createTempSync('silique-update-test-');
  });
  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<String> signed({
    int build = 9,
    String? url,
    String? hash,
    int? size,
  }) async {
    final payload = utf8.encode(
      jsonEncode({
        'schema': 1,
        'version': '0.2.5',
        'build': build,
        'notes': 'Nowa wersja',
        'platforms': {
          'android': {
            'url':
                url ??
                'https://github.com/$updateRepository/releases/download/v0.2.5/Silique-0.2.5.apk',
            'sha256': hash ?? digest,
            'size': size ?? bytes.length,
          },
        },
      }),
    );
    final signature = await algorithm.sign(payload, keyPair: pair);
    return jsonEncode({
      'payload': base64Encode(payload),
      'signature': base64Encode(signature.bytes),
    });
  }

  Future<String> signedData(Map<String, dynamic> data) async {
    final payload = utf8.encode(
      jsonEncode({
        'schema': 1,
        'version': '0.2.5',
        'build': 9,
        'notes': 'Nowa wersja',
        ...data,
      }),
    );
    final signature = await algorithm.sign(payload, keyPair: pair);
    return jsonEncode({
      'payload': base64Encode(payload),
      'signature': base64Encode(signature.bytes),
    });
  }

  String linuxUrl(String suffix) =>
      'https://github.com/$updateRepository/releases/download/v0.2.5/Silique-0.2.5$suffix';

  test(
    'a signed release is verified and binds version to its official download',
    () async {
      final release = await AppRelease.verify(
        await signed(),
        publicKey: publicKey,
      );
      expect(release.build, 9);
      expect(release.artifacts['android']!.sha256, digest);
    },
  );
  test('tampered metadata or another signing key is rejected', () async {
    final value = jsonDecode(await signed()) as Map<String, dynamic>;
    value['payload'] = base64Encode(utf8.encode('{}'));
    await expectLater(
      AppRelease.verify(jsonEncode(value), publicKey: publicKey),
      throwsFormatException,
    );
    await expectLater(AppRelease.verify(await signed()), throwsFormatException);
  });
  test('even signed metadata cannot select another host, repository or tag', () async {
    for (final url in [
      'http://github.com/$updateRepository/releases/download/v0.2.5/Silique-0.2.5.apk',
      'https://evil.example/Silique.apk',
      'https://github.com/attacker/releases/download/v0.2.5/Silique-0.2.5.apk',
      'https://github.com/$updateRepository/releases/download/v0.2.4/Silique-0.2.5.apk',
    ]) {
      await expectLater(
        AppRelease.verify(await signed(url: url), publicKey: publicKey),
        throwsFormatException,
      );
    }
  });
  test(
    'invalid hashes, unbounded files and oversized metadata are rejected',
    () async {
      await expectLater(
        AppRelease.verify(await signed(hash: 'bad'), publicKey: publicKey),
        throwsFormatException,
      );
      await expectLater(
        AppRelease.verify(
          await signed(size: 513 * 1024 * 1024),
          publicKey: publicKey,
        ),
        throwsFormatException,
      );
      await expectLater(
        AppRelease.verify(' ' * (128 * 1024 + 1), publicKey: publicKey),
        throwsFormatException,
      );
    },
  );
  test('signed RPM, DEB and portable Linux packages keep their canonical names', () async {
    final linux = {
      'linux-deb':
          'https://github.com/$updateRepository/releases/download/v0.2.5/Silique-0.2.5-Linux-GTK4-amd64.deb',
      'linux-rpm':
          'https://github.com/$updateRepository/releases/download/v0.2.5/Silique-0.2.5-Linux-GTK4-x86_64.rpm',
      'linux':
          'https://github.com/$updateRepository/releases/download/v0.2.5/Silique-0.2.5-Linux-GTK4-x64.tar.gz',
    };
    final release = await AppRelease.verify(
      await signedData({
        'platforms': {
          for (final entry in linux.entries)
            entry.key: {
              'url': entry.value,
              'sha256': digest,
              'size': bytes.length,
            },
        },
      }),
      publicKey: publicKey,
    );
    expect(release.artifacts.keys, containsAll(linux.keys));
  });
  test('a signed Linux package cannot point at another host, tag or suffix', () async {
    final canonical =
        'https://github.com/$updateRepository/releases/download/v0.2.5/Silique-0.2.5-Linux-GTK4-x86_64.rpm';
    for (final url in [
      canonical.replaceFirst('https://github.com', 'https://evil.example'),
      canonical.replaceFirst('v0.2.5', 'v0.2.4'),
      'https://github.com/$updateRepository/releases/download/v0.2.5/Silique-0.2.5-Linux-GTK4-amd64.deb',
    ]) {
      await expectLater(
        AppRelease.verify(
          await signedData({
            'platforms': {
              'linux-rpm': {'url': url, 'sha256': digest, 'size': bytes.length},
            },
          }),
          publicKey: publicKey,
        ),
        throwsFormatException,
      );
    }
  });
  test('packaged Linux platforms are supported while the portable tar stays manual', () {
    expect(InstalledApp('0.2.5', 10, 'linux-rpm').supported, true);
    expect(InstalledApp('0.2.5', 10, 'linux-deb').supported, true);
    expect(InstalledApp('0.2.5', 10, 'linux').supported, false);
    expect(InstalledApp('0.2.5', 10, 'windows-portable').supported, false);
  });

  UpdateArtifact artifact() => UpdateArtifact(
    url: Uri.parse(
      'https://github.com/$updateRepository/releases/download/v0.2.5/Silique-0.2.5.apk',
    ),
    sha256: digest,
    size: bytes.length,
  );
  test('download verifies all bytes before an atomic rename, and reuses verified cache', () async {
    var requests = 0;
    final client = UpdateClient(
      clientFactory: () => MockClient((_) async {
        requests++;
        return http.Response.bytes(bytes, 200);
      }),
    );
    final cancel = Completer<void>();
    final target = await client.download(
      artifact(),
      directory,
      build: 9,
      onProgress: (_) {},
      cancelled: cancel.future,
    );
    expect(target.readAsBytesSync(), bytes);
    expect(File('${target.path}.part').existsSync(), false);
    await client.download(
      artifact(),
      directory,
      build: 9,
      onProgress: (_) {},
      cancelled: cancel.future,
    );
    expect(requests, 1);
    // A modified cache is not trusted just because its name matches.
    target.writeAsBytesSync([6, 5, 4, 3, 2, 1]);
    await client.download(
      artifact(),
      directory,
      build: 9,
      onProgress: (_) {},
      cancelled: cancel.future,
    );
    expect(requests, 2);
    expect(target.readAsBytesSync(), bytes);
  });
  test(
    'corrupt, truncated and oversized downloads never become installers',
    () async {
      for (final body in [
        [6, 5, 4, 3, 2, 1],
        [1],
        [...bytes, 7],
      ]) {
        final client = UpdateClient(
          clientFactory: () =>
              MockClient((_) async => http.Response.bytes(body, 200)),
        );
        await expectLater(
          client.download(
            artifact(),
            directory,
            build: 9,
            onProgress: (_) {},
            cancelled: Completer<void>().future,
          ),
          throwsFormatException,
        );
        expect(directory.listSync(), isEmpty);
      }
    },
  );
  test('cancelled download leaves no partial installer', () async {
    final client = UpdateClient(
      clientFactory: () =>
          MockClient((_) async => http.Response.bytes(bytes, 200)),
    );
    final cancel = Completer<void>()..complete();
    await expectLater(
      client.download(
        artifact(),
        directory,
        build: 9,
        onProgress: (_) {},
        cancelled: cancel.future,
      ),
      throwsA(isA<UpdateCancelled>()),
    );
    expect(directory.listSync(), isEmpty);
  });
  test(
    'discovery uses no authorization and ignores equal/older builds',
    () async {
      final content = await signed(build: 8);
      final installer = FakeInstaller(directory.path);
      final updater = AppUpdater(
        installer: installer,
        client: UpdateClient(
          publicKey: publicKey,
          clientFactory: () => MockClient((request) async {
            expect(request.url, updateFeed);
            expect(request.headers.keys, isNot(contains('authorization')));
            return http.Response(content, 200);
          }),
        ),
      );
      addTearDown(updater.dispose);
      await updater.initialize();
      await updater.check();
      expect(updater.available, false);
      expect(updater.message, 'Masz najnowszą wersję.');
      await updater.install(beforeInstall: () async {});
      expect(installer.installs, 0);
    },
  );
  test(
    'installation waits for save; save failure cannot launch installer',
    () async {
      final content = await signed();
      final installer = FakeInstaller(directory.path);
      final updater = AppUpdater(
        installer: installer,
        client: UpdateClient(
          publicKey: publicKey,
          clientFactory: () => MockClient(
            (request) async => request.url == updateFeed
                ? http.Response(content, 200)
                : http.Response.bytes(bytes, 200),
          ),
        ),
      );
      addTearDown(updater.dispose);
      await updater.initialize();
      await updater.check();
      expect(updater.available, true);
      await updater.install(
        beforeInstall: () async {
          throw StateError('disk unavailable');
        },
      );
      expect(installer.installs, 0);
      expect(updater.message, contains('Nie udało się'));
      var saved = false;
      await updater.install(
        beforeInstall: () async {
          saved = true;
        },
      );
      expect(saved, true);
      expect(installer.installs, 1);
    },
  );
  test('permission request explains the next step and retry reuses the verified file', () async {
    final content = await signed();
    var downloads = 0;
    final installer = FakeInstaller(directory.path)
      ..result = 'permission_required';
    final updater = AppUpdater(
      installer: installer,
      client: UpdateClient(
        publicKey: publicKey,
        clientFactory: () => MockClient((request) async {
          if (request.url == updateFeed) return http.Response(content, 200);
          downloads++;
          return http.Response.bytes(bytes, 200);
        }),
      ),
    );
    addTearDown(updater.dispose);
    await updater.initialize();
    await updater.check();
    await updater.install(beforeInstall: () async {});
    expect(updater.message, contains('Zezwól Silique'));
    installer.result = 'started';
    await updater.install(beforeInstall: () async {});
    expect(downloads, 1);
    expect(installer.installs, 2);
  });
  test(
    'desktop packages show their version without trying the Android installer',
    () async {
      var requests = 0;
      final installer = FakeInstaller(directory.path, platform: 'linux');
      final updater = AppUpdater(
        installer: installer,
        client: UpdateClient(
          clientFactory: () => MockClient((_) async {
            requests++;
            throw StateError('Desktop packages use the release page');
          }),
        ),
      );
      addTearDown(updater.dispose);
      await updater.initialize();
      await updater.check();
      await updater.install(beforeInstall: () async {});
      expect(updater.installed?.version, '0.2.4');
      expect(requests, 0);
      expect(installer.installs, 0);
    },
  );
  test(
    'offline checks keep the app usable and never offer an unverified update',
    () async {
      final updater = AppUpdater(
        installer: FakeInstaller(directory.path),
        client: UpdateClient(
          clientFactory: () =>
              MockClient((_) async => throw const SocketException('offline')),
        ),
      );
      addTearDown(updater.dispose);
      await updater.initialize();
      await updater.check(quiet: true);
      expect(updater.available, false);
      expect(updater.message, isNull);
      expect(updater.busy, false);
      await updater.check();
      expect(updater.message, contains('Sprawdź połączenie'));
    },
  );
  testWidgets(
    'startup check detects a new version and settings offer installation',
    (tester) async {
      final content = await signed();
      var checks = 0;
      final updater = AppUpdater(
        installer: FakeInstaller(directory.path),
        client: UpdateClient(
          publicKey: publicKey,
          clientFactory: () => MockClient((_) async {
            checks++;
            return http.Response(content, 200);
          }),
        ),
      );
      await updater.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: UpdatesPanel(updater: updater, beforeInstall: () async {}),
            ),
          ),
        ),
      );
      expect(find.text('Silique 0.2.4 (build 8)'), findsOneWidget);
      expect(find.byKey(const Key('available-update')), findsNothing);
      await tester.pump(const Duration(seconds: 8));
      await tester.pumpAndSettle();
      expect(checks, 1);
      expect(find.text('Dostępna wersja 0.2.5'), findsOneWidget);
      expect(find.byKey(const Key('install-update')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      updater.dispose();
    },
  );

  UpdateArtifact linuxArtifact(String suffix) => UpdateArtifact(
    url: Uri.parse(linuxUrl(suffix)),
    sha256: digest,
    size: bytes.length,
  );

  test('the matching Linux package is selected and installed only after the save', () async {
    final content = await signedData({
      'platforms': {
        'android': {
          'url':
              'https://github.com/$updateRepository/releases/download/v0.2.5/Silique-0.2.5.apk',
          'sha256': digest,
          'size': bytes.length,
        },
        'linux-rpm': {
          'url': linuxUrl('-Linux-GTK4-x86_64.rpm'),
          'sha256': digest,
          'size': bytes.length,
        },
        'linux-deb': {
          'url': linuxUrl('-Linux-GTK4-amd64.deb'),
          'sha256': digest,
          'size': bytes.length,
        },
        'linux': {
          'url': linuxUrl('-Linux-GTK4-x64.tar.gz'),
          'sha256': digest,
          'size': bytes.length,
        },
      },
    });
    String? requested;
    final installer = LinuxFakeInstaller(directory.path, platform: 'linux-rpm');
    final updater = AppUpdater(
      installer: installer,
      client: UpdateClient(
        publicKey: publicKey,
        clientFactory: () => MockClient((request) async {
          if (request.url == updateFeed) return http.Response(content, 200);
          requested = request.url.path;
          return http.Response.bytes(bytes, 200);
        }),
      ),
    );
    addTearDown(updater.dispose);
    await updater.initialize();
    await updater.check();
    expect(updater.available, true);
    var saved = false;
    await updater.install(
      beforeInstall: () async {
        saved = true;
      },
    );
    expect(saved, true);
    expect(installer.installs, 1);
    expect(installer.lastPlatform, 'linux-rpm');
    expect(installer.lastPath, endsWith('.rpm'));
    expect(File(installer.lastPath!).isAbsolute, isTrue);
    expect(File(installer.lastPath!).parent.path, directory.path);
    expect(requested, endsWith('-Linux-GTK4-x86_64.rpm'));
    expect(updater.message, contains('ponownie'));
  });
  test('a failed save never launches the privileged Linux installer', () async {
    final content = await signedData({
      'platforms': {
        'linux-rpm': {
          'url': linuxUrl('-Linux-GTK4-x86_64.rpm'),
          'sha256': digest,
          'size': bytes.length,
        },
      },
    });
    final installer = LinuxFakeInstaller(directory.path, platform: 'linux-rpm');
    final updater = AppUpdater(
      installer: installer,
      client: UpdateClient(
        publicKey: publicKey,
        clientFactory: () => MockClient(
          (request) async => request.url == updateFeed
              ? http.Response(content, 200)
              : http.Response.bytes(bytes, 200),
        ),
      ),
    );
    addTearDown(updater.dispose);
    await updater.initialize();
    await updater.check();
    expect(updater.available, true);
    await updater.install(
      beforeInstall: () async {
        throw StateError('disk unavailable');
      },
    );
    expect(installer.installs, 0);
    expect(updater.message, contains('Nie udało się'));
  });
  test(
    'a dismissed authorization is reported clearly and never retried silently',
    () async {
      final content = await signedData({
        'platforms': {
          'linux-deb': {
            'url': linuxUrl('-Linux-GTK4-amd64.deb'),
            'sha256': digest,
            'size': bytes.length,
          },
        },
      });
      final installer = LinuxFakeInstaller(
        directory.path,
        platform: 'linux-deb',
      )..outcome = LinuxInstallOutcome.cancelled;
      final updater = AppUpdater(
        installer: installer,
        client: UpdateClient(
          publicKey: publicKey,
          clientFactory: () => MockClient(
            (request) async => request.url == updateFeed
                ? http.Response(content, 200)
                : http.Response.bytes(bytes, 200),
          ),
        ),
      );
      addTearDown(updater.dispose);
      await updater.initialize();
      await updater.check();
      await updater.install(beforeInstall: () async {});
      expect(installer.installs, 1);
      expect(installer.lastPlatform, 'linux-deb');
      expect(updater.message, contains('anulowana'));
      expect(updater.busy, false);
    },
  );
  test('the updater never offers a same or older Linux build', () async {
    for (final build in [8, 7]) {
      final content = await signedData({
        'build': build,
        'platforms': {
          'linux-rpm': {
            'url': linuxUrl('-Linux-GTK4-x86_64.rpm'),
            'sha256': digest,
            'size': bytes.length,
          },
        },
      });
      final installer = LinuxFakeInstaller(
        directory.path,
        platform: 'linux-rpm',
      );
      final updater = AppUpdater(
        installer: installer,
        client: UpdateClient(
          publicKey: publicKey,
          clientFactory: () =>
              MockClient((_) async => http.Response(content, 200)),
        ),
      );
      addTearDown(updater.dispose);
      await updater.initialize();
      await updater.check();
      expect(updater.available, false);
      await updater.install(beforeInstall: () async {});
      expect(installer.installs, 0);
    }
  });
  test('a portable Linux tar never checks or installs automatically', () async {
    var requests = 0;
    final installer = LinuxFakeInstaller(directory.path, platform: 'linux');
    final updater = AppUpdater(
      installer: installer,
      client: UpdateClient(
        clientFactory: () => MockClient((_) async {
          requests++;
          throw StateError('Portable tar installs stay manual');
        }),
      ),
    );
    addTearDown(updater.dispose);
    await updater.initialize();
    await updater.check(quiet: true);
    expect(requests, 0);
    expect(updater.available, false);
    await updater.install(beforeInstall: () async {});
    expect(installer.installs, 0);
  });
  test(
    'a successful Linux install flushes notes before restarting exactly once',
    () async {
      final content = await signedData({
        'platforms': {
          'linux-rpm': {
            'url': linuxUrl('-Linux-GTK4-x86_64.rpm'),
            'sha256': digest,
            'size': bytes.length,
          },
        },
      });
      final installer = LinuxFakeInstaller(
        directory.path,
        platform: 'linux-rpm',
      );
      final events = <String>[];
      var restarts = 0;
      final updater = AppUpdater(
        installer: installer,
        restartAfterInstall: () async {
          restarts++;
          events.add('restart');
        },
        client: UpdateClient(
          publicKey: publicKey,
          clientFactory: () => MockClient(
            (request) async => request.url == updateFeed
                ? http.Response(content, 200)
                : http.Response.bytes(bytes, 200),
          ),
        ),
      );
      addTearDown(updater.dispose);
      await updater.initialize();
      await updater.check();
      expect(updater.available, true);
      await updater.install(beforeInstall: () async => events.add('flush'));
      expect(events, ['flush', 'restart']);
      expect(restarts, 1);
      expect(updater.message, contains('uruchamia się ponownie'));
      expect(updater.busy, false);
    },
  );
  test(
    'cancelled and failed Linux installs never restart and never mention one',
    () async {
      for (final outcome in [
        LinuxInstallOutcome.cancelled,
        LinuxInstallOutcome.failed,
      ]) {
        final content = await signedData({
          'platforms': {
            'linux-rpm': {
              'url': linuxUrl('-Linux-GTK4-x86_64.rpm'),
              'sha256': digest,
              'size': bytes.length,
            },
          },
        });
        final installer = LinuxFakeInstaller(
          directory.path,
          platform: 'linux-rpm',
        )..outcome = outcome;
        var restarts = 0;
        final updater = AppUpdater(
          installer: installer,
          restartAfterInstall: () async => restarts++,
          client: UpdateClient(
            publicKey: publicKey,
            clientFactory: () => MockClient(
              (request) async => request.url == updateFeed
                  ? http.Response(content, 200)
                  : http.Response.bytes(bytes, 200),
            ),
          ),
        );
        addTearDown(updater.dispose);
        await updater.initialize();
        await updater.check();
        await updater.install(beforeInstall: () async {});
        expect(restarts, 0);
        expect(updater.message, isNot(contains('ponownie')));
        expect(updater.busy, false);
      }
    },
  );
  test(
    'a throwing restart leaves an actionable message and never wedges the updater',
    () async {
      final content = await signedData({
        'platforms': {
          'linux-rpm': {
            'url': linuxUrl('-Linux-GTK4-x86_64.rpm'),
            'sha256': digest,
            'size': bytes.length,
          },
        },
      });
      final installer = LinuxFakeInstaller(
        directory.path,
        platform: 'linux-rpm',
      );
      var restarts = 0;
      final updater = AppUpdater(
        installer: installer,
        restartAfterInstall: () async {
          restarts++;
          throw StateError('no window');
        },
        client: UpdateClient(
          publicKey: publicKey,
          clientFactory: () => MockClient(
            (request) async => request.url == updateFeed
                ? http.Response(content, 200)
                : http.Response.bytes(bytes, 200),
          ),
        ),
      );
      addTearDown(updater.dispose);
      await updater.initialize();
      await updater.check();
      await updater.install(beforeInstall: () async {});
      expect(restarts, 1);
      expect(updater.message, contains('Uruchom Silique ponownie'));
      expect(updater.busy, false);
    },
  );
  test(
    'downloads carry the canonical package extension and refuse others',
    () async {
      final client = UpdateClient(
        clientFactory: () =>
            MockClient((_) async => http.Response.bytes(bytes, 200)),
      );
      final rpm = await client.download(
        linuxArtifact('-Linux-GTK4-x86_64.rpm'),
        directory,
        build: 11,
        onProgress: (_) {},
        cancelled: Completer<void>().future,
      );
      expect(rpm.path, endsWith('.rpm'));
      final deb = await client.download(
        linuxArtifact('-Linux-GTK4-amd64.deb'),
        directory,
        build: 11,
        onProgress: (_) {},
        cancelled: Completer<void>().future,
      );
      expect(deb.path, endsWith('.deb'));
      await expectLater(
        client.download(
          linuxArtifact('-Linux-GTK4-x64.tar.gz'),
          directory,
          build: 11,
          onProgress: (_) {},
          cancelled: Completer<void>().future,
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'a Linux package with a bad hash, size or signature is rejected',
    () async {
      await expectLater(
        AppRelease.verify(
          await signedData({
            'platforms': {
              'linux-rpm': {
                'url': linuxUrl('-Linux-GTK4-x86_64.rpm'),
                'sha256': 'bad',
                'size': bytes.length,
              },
            },
          }),
          publicKey: publicKey,
        ),
        throwsFormatException,
      );
      await expectLater(
        AppRelease.verify(
          await signedData({
            'platforms': {
              'linux-deb': {
                'url': linuxUrl('-Linux-GTK4-amd64.deb'),
                'sha256': digest,
                'size': 513 * 1024 * 1024,
              },
            },
          }),
          publicKey: publicKey,
        ),
        throwsFormatException,
      );
      final forged = jsonDecode(
        await signedData({
          'platforms': {
            'linux-rpm': {
              'url': linuxUrl('-Linux-GTK4-x86_64.rpm'),
              'sha256': digest,
              'size': bytes.length,
            },
          },
        }),
      ) as Map<String, dynamic>;
      forged['payload'] = base64Encode(utf8.encode('{}'));
      await expectLater(
        AppRelease.verify(jsonEncode(forged), publicKey: publicKey),
        throwsFormatException,
      );
    },
  );
}
