import 'dart:io';

import 'package:silique/core/updates.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError('Pass the signed latest.json file.');
  }
  final release = await AppRelease.verify(
    await File(args.single).readAsString(),
  );
  stdout.writeln(
    'Verified publisher signature: ${release.version}, build ${release.build}',
  );
}
