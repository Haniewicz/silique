// Location choice: first run, cancelled picker and recovery of existing data.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/storage/native_files.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/ui/location_setup.dart';

Future<void> _mount(
  WidgetTester tester, {
  required Future<void> Function(String root) onChosen,
  bool recovering = false,
  String? unavailable,
}) async {
  await tester.pumpWidget(
    LocationSetupScreen(
      onChosen: onChosen,
      recovering: recovering,
      unavailable: unavailable,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late Directory root;
  late Directory support;
  final remembered = <String>[];
  final chosenRoots = <String>[];

  setUp(() {
    root = Directory.systemTemp.createTempSync('silique-loc-ui-');
    support = Directory('${root.path}/support')..createSync();
    remembered.clear();
    chosenRoots.clear();
    debugStorageAccess = remembered.add;
  });

  tearDown(() {
    debugDirectoryPicker = null;
    debugStorageAccess = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  testWidgets(
    'a chosen folder is created, persisted and remembered as one path',
    (tester) async {
      final picked = Directory('${root.path}/Dokumenty')..createSync();
      debugDirectoryPicker = () async => StorageChoice(path: picked.path);
      await _mount(
        tester,
        onChosen: (value) async {
          chosenRoots.add(value);
          NativeStorage.persistChosenRoot(support.path, value);
        },
      );
      await tester.tap(find.byKey(const Key('choose-location')));
      await tester.pumpAndSettle();

      expect(chosenRoots, hasLength(1));
      final persisted = NativeStorage.recordedRoot(support.path);
      expect(
        chosenRoots.single,
        '${picked.path}/${NativeStorage.vaultsFolderName}',
      );
      // The remembered bookmark path must equal the persisted pointer path, or a
      // restart cannot restore the security-scoped access.
      expect(remembered, [persisted]);
      expect(Directory(persisted!).existsSync(), true);
      // And the recorded location opens again after a restart.
      expect(NativeStorage.existingRoot(support.path), persisted);
    },
  );

  testWidgets('cancelling creates nothing and keeps the choice on screen', (
    tester,
  ) async {
    debugDirectoryPicker = () async => null;
    await _mount(tester, onChosen: (value) async => chosenRoots.add(value));
    await tester.tap(find.byKey(const Key('choose-location')));
    await tester.pumpAndSettle();

    expect(chosenRoots, isEmpty);
    expect(remembered, isEmpty);
    expect(find.byKey(const Key('location-error')), findsOneWidget);
    expect(Directory('${support.path}/Silique').existsSync(), false);
    expect(
      Directory('${support.path}/${NativeStorage.vaultsFolderName}')
          .existsSync(),
      false,
    );
    expect(NativeStorage.existingRoot(support.path), isNull);
  });

  testWidgets('recovery adopts the existing store instead of a new one', (
    tester,
  ) async {
    final old = Directory('${root.path}/Stare miejsce/Dokumenty/Silique Vaults')
      ..createSync(recursive: true);
    File('${old.path}/silique.sqlite').writeAsStringSync('dane');
    File('${old.path}/notatka.md').writeAsStringSync('# Notatka');
    debugDirectoryPicker = () async => StorageChoice(path: old.path);
    await _mount(
      tester,
      recovering: true,
      unavailable: '/nie/ma/tu',
      onChosen: (value) async {
        chosenRoots.add(value);
        NativeStorage.persistChosenRoot(support.path, value);
      },
    );
    expect(find.byKey(const Key('unavailable-location')), findsOneWidget);
    await tester.tap(find.byKey(const Key('choose-location')));
    await tester.pumpAndSettle();

    expect(chosenRoots, [old.path]);
    expect(remembered, [old.path]);
    expect(File('${old.path}/silique.sqlite').readAsStringSync(), 'dane');
    expect(File('${old.path}/notatka.md').existsSync(), true);
    expect(NativeStorage.existingRoot(support.path), old.path);
  });

  testWidgets('recovery refuses a folder without notes and writes nothing', (
    tester,
  ) async {
    final empty = Directory('${root.path}/Pusty')..createSync();
    debugDirectoryPicker = () async => StorageChoice(path: empty.path);
    await _mount(
      tester,
      recovering: true,
      onChosen: (value) async => chosenRoots.add(value),
    );
    await tester.tap(find.byKey(const Key('choose-location')));
    await tester.pumpAndSettle();

    expect(chosenRoots, isEmpty);
    expect(find.byKey(const Key('location-error')), findsOneWidget);
    expect(
      Directory('${empty.path}/${NativeStorage.vaultsFolderName}').existsSync(),
      false,
      reason: 'recovery must never create an empty store',
    );
    expect(NativeStorage.recordedRoot(support.path), isNull);
  });

  testWidgets('an unusable provider is refused with a plain message', (
    tester,
  ) async {
    debugDirectoryPicker = () async =>
        const StorageChoice(label: 'Dokumenty (SAF)', writable: true);
    await _mount(tester, onChosen: (value) async => chosenRoots.add(value));
    await tester.tap(find.byKey(const Key('choose-location')));
    await tester.pumpAndSettle();

    expect(chosenRoots, isEmpty);
    final error = tester.widget<Text>(find.byKey(const Key('location-error')));
    expect(error.data, contains('Wybierz folder w pamięci urządzenia'));
    // No technical storage terms and no silent substitution of another folder.
    expect(error.data, isNot(contains('SQLite')));
    expect(error.data, isNot(contains('SAF')));
    expect(find.byKey(const Key('use-app-storage')), findsNothing);
  });
}
