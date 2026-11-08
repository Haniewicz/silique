import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/app_updates.dart';

void main() {
  test(
    'public signed feed and APK download work without GitHub credentials',
    () async {
      final client = UpdateClient();
      final release = await client.latest();
      expect(release.build, greaterThanOrEqualTo(8));
      final directory = Directory.systemTemp.createTempSync(
        'silique-public-update-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final artifact = release.artifacts['android']!;
      final file = await client.download(
        artifact,
        directory,
        build: release.build,
        onProgress: (_) {},
        cancelled: Completer<void>().future,
      );
      expect(file.lengthSync(), artifact.size);
      expect(File('${file.path}.part').existsSync(), false);
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: Platform.environment['SILIQUE_PUBLIC_UPDATER_SMOKE'] != '1'
        ? 'Set SILIQUE_PUBLIC_UPDATER_SMOKE=1 for the real public network smoke test'
        : false,
  );
}
