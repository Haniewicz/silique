import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/core/updates.dart';
import 'package:silique/services/app_updates.dart';
import 'package:silique/storage/native_updates.dart';

// Frozen pre-DMG parser from 178cd90:lib/core/updates.dart. Keep its allowlist
// and verification independent of production to exercise real old-client rules.
import 'fixtures/legacy_updates_0_2_29.dart' as legacy;

class _MacInstaller extends NativeUpdateInstaller {
  @override
  Future<InstalledApp?> info() async =>
      const InstalledApp('0.2.29', 38, 'macos');

  @override
  Future<String> downloadDirectory() =>
      throw StateError('Sparkle, not Dart, downloads the DMG');

  @override
  Future<String> installAndroid(String path) =>
      throw StateError('A DMG is never an Android installer');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final algorithm = Ed25519();
  late SimpleKeyPair pair;
  late String publicKey;

  setUp(() async {
    pair = await algorithm.newKeyPair();
    publicKey = base64Encode((await pair.extractPublicKey()).bytes);
  });

  String url(String suffix) =>
      'https://github.com/$updateRepository/releases/download/v0.2.30/Silique-0.2.30$suffix';

  Map<String, dynamic> artifact(String suffix) => {
    'url': url(suffix),
    'sha256': 'a' * 64,
    'size': 123,
  };

  Future<String> signed(Map<String, dynamic> platforms) async {
    final payload = utf8.encode(
      jsonEncode({
        'schema': 1,
        'version': '0.2.30',
        'build': 39,
        'notes': 'DMG update',
        'platforms': platforms,
      }),
    );
    final signature = await algorithm.sign(payload, keyPair: pair);
    return jsonEncode({
      'payload': base64Encode(payload),
      'signature': base64Encode(signature.bytes),
    });
  }

  test('both macOS wire keys are ambiguous even when one is null', () async {
    for (final platforms in [
      {'macos': artifact('-macOS.zip'), 'macos-dmg': artifact('-macOS.dmg')},
      {'macos-dmg': artifact('-macOS.dmg'), 'macos': artifact('-macOS.zip')},
      {'macos': null, 'macos-dmg': artifact('-macOS.dmg')},
      {'macos': artifact('-macOS.zip'), 'macos-dmg': null},
    ]) {
      await expectLater(
        AppRelease.verify(await signed(platforms), publicKey: publicKey),
        throwsFormatException,
      );
    }
  });

  test('signed macos-dmg is exposed as the existing macos artifact', () async {
    final release = await AppRelease.verify(
      await signed({'macos-dmg': artifact('-macOS.dmg')}),
      publicKey: publicKey,
    );
    expect(release.version, '0.2.30');
    expect(release.build, 39);
    expect(release.artifacts.keys, ['macos']);
    expect(release.artifacts['macos']!.url.toString(), url('-macOS.dmg'));
    expect(release.artifacts['macos']!.sha256, 'a' * 64);
    expect(release.artifacts['macos']!.size, 123);
  });

  test('historical macos ZIP feeds are still accepted', () async {
    final release = await AppRelease.verify(
      await signed({'macos': artifact('-macOS.zip')}),
      publicKey: publicKey,
    );
    expect(release.artifacts.keys, ['macos']);
    expect(release.artifacts['macos']!.url.toString(), url('-macOS.zip'));
  });

  test('each macOS wire key only accepts its exact canonical URL', () async {
    for (final entry in {
      'macos': '-macOS.zip',
      'macos-dmg': '-macOS.dmg',
    }.entries) {
      final canonical = url(entry.value);
      for (final invalid in [
        canonical.replaceFirst('https:', 'http:'),
        canonical.replaceFirst('github.com', 'evil.example'),
        canonical.replaceFirst(updateRepository, 'attacker/silique-releases'),
        canonical.replaceFirst('v0.2.30', 'v0.2.29'),
        canonical.replaceFirst('Silique-0.2.30', 'Silique-0.2.29'),
        url(entry.key == 'macos' ? '-macOS.dmg' : '-macOS.zip'),
        url('.apk'),
        url('-Linux-GTK4-amd64.deb'),
        '$canonical?download=1',
        '$canonical#fragment',
        canonical.replaceFirst('Silique-', '%53ilique-'),
        canonical.replaceFirst('/Silique-', '/extra/../Silique-'),
        canonical.replaceFirst('-macOS.', '-macos.'),
        '$canonical.exe',
      ]) {
        await expectLater(
          AppRelease.verify(
            await signed({
              entry.key: {...artifact(entry.value), 'url': invalid},
              // A valid other platform must not hide an invalid macOS artifact.
              'android': artifact('.apk'),
            }),
            publicKey: publicKey,
          ),
          throwsFormatException,
          reason: '${entry.key}: $invalid',
        );
      }
    }
  });

  test(
    'macos-dmg metadata retains signature, hash and size validation',
    () async {
      for (final change in [
        {'sha256': 'bad'},
        {'sha256': 'A' * 64},
        {'size': 0},
        {'size': 513 * 1024 * 1024},
      ]) {
        await expectLater(
          AppRelease.verify(
            await signed({
              'macos-dmg': {...artifact('-macOS.dmg'), ...change},
            }),
            publicKey: publicKey,
          ),
          throwsFormatException,
        );
      }
      final envelope = await signed({'macos-dmg': artifact('-macOS.dmg')});
      final tampered = jsonDecode(envelope) as Map<String, dynamic>;
      final payload = jsonDecode(
        utf8.decode(base64Decode(tampered['payload'] as String)),
      ) as Map<String, dynamic>;
      payload['platforms']['macos-dmg']['url'] = url('-macOS.zip');
      tampered['payload'] = base64Encode(utf8.encode(jsonEncode(payload)));
      await expectLater(
        AppRelease.verify(jsonEncode(tampered), publicKey: publicKey),
        throwsFormatException,
      );
      final anotherKey = base64Encode(
        (await (await algorithm.newKeyPair()).extractPublicKey()).bytes,
      );
      await expectLater(
        AppRelease.verify(envelope, publicKey: anotherKey),
        throwsFormatException,
      );
    },
  );

  test('old signed parser accepts new Android and Linux feed but has no Mac update', () async {
    final platforms = {
      'macos-dmg': artifact('-macOS.dmg'),
      'android': artifact('.apk'),
      'linux': artifact('-Linux-GTK4-x64.tar.gz'),
      'linux-deb': artifact('-Linux-GTK4-amd64.deb'),
      'linux-rpm': artifact('-Linux-GTK4-x86_64.rpm'),
    };
    expect(platforms.containsKey('macos'), false);
    final envelope = await signed(platforms);
    final oldRelease = await legacy.AppRelease.verify(
      envelope,
      publicKey: publicKey,
    );
    expect(oldRelease.version, '0.2.30');
    expect(oldRelease.build, 39);
    expect(oldRelease.artifacts.keys.toSet(), {
      'android',
      'linux',
      'linux-deb',
      'linux-rpm',
    });
    final newRelease = await AppRelease.verify(envelope, publicKey: publicKey);
    expect(newRelease.artifacts.keys.toSet(), {
      'macos',
      'android',
      'linux',
      'linux-deb',
      'linux-rpm',
    });
    for (final platform in ['android', 'linux-deb', 'linux-rpm']) {
      // Feed acceptance is not enough: old AppUpdater availability must still
      // select its own supported package at a newer build.
      final updater = AppUpdater()
        ..installed = InstalledApp('0.2.29', 38, platform)
        ..release = AppRelease(
          version: oldRelease.version,
          build: oldRelease.build,
          notes: oldRelease.notes,
          artifacts: {
            for (final entry in oldRelease.artifacts.entries)
              entry.key: UpdateArtifact(
                url: entry.value.url,
                sha256: entry.value.sha256,
                size: entry.value.size,
              ),
          },
        );
      addTearDown(updater.dispose);
      expect(updater.available, true, reason: platform);
      expect(
        updater.release!.artifacts[platform]!.url,
        newRelease.artifacts[platform]!.url,
      );
      updater.installed = const InstalledApp('0.2.29', 38, 'macos');
      // Pre-0.2.30 Mac clients require a manual DMG transition; do not imply
      // that their unknown macos-dmg field enables automatic installation.
      expect(updater.available, false);
    }
    final forged = jsonDecode(envelope) as Map<String, dynamic>;
    forged['payload'] = base64Encode(utf8.encode('{}'));
    await expectLater(
      legacy.AppRelease.verify(jsonEncode(forged), publicKey: publicKey),
      throwsFormatException,
    );
  });

  test(
    'DMG discovery delegates to native Sparkle only after beforeInstall',
    () async {
      final content = await signed({'macos-dmg': artifact('-macOS.dmg')});
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeUpdateInstaller.channel, (
            call,
          ) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeUpdateInstaller.channel, null),
      );
      var requests = 0;
      final updater = AppUpdater(
        installer: _MacInstaller(),
        client: UpdateClient(
          publicKey: publicKey,
          clientFactory: () => MockClient((request) async {
            requests++;
            expect(
              request.url,
              updateFeed,
              reason: 'Dart must not download the DMG',
            );
            return http.Response(content, 200);
          }),
        ),
      );
      addTearDown(updater.dispose);
      await updater.initialize();
      await updater.check();
      expect(updater.available, true);
      expect(
        updater.release!.artifacts['macos']!.url.toString(),
        url('-macOS.dmg'),
      );

      await updater.install(
        beforeInstall: () async => throw StateError('save failed'),
      );
      expect(calls, isEmpty);
      expect(updater.message, contains('Nie udało się'));

      final saving = Completer<void>();
      final entered = Completer<void>();
      final installing = updater.install(
        beforeInstall: () {
          entered.complete();
          return saving.future;
        },
      );
      await entered.future;
      expect(updater.stage, UpdateStage.installing);
      expect(calls, isEmpty);
      saving.complete();
      await installing;
      expect(calls.map((call) => call.method), ['installMac']);
      expect(calls.single.arguments, isNull);
      expect(requests, 1);
      expect(updater.stage, UpdateStage.idle);
      expect(updater.message, contains('okno instalatora Silique'));
    },
  );
}
