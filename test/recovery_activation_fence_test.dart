import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/main.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/storage/native_storage_recovery.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'snapshot creation never changes authority while source writers continue',
    () async {
      final dir = Directory(
        Directory.systemTemp
            .createTempSync('silique-recovery-authority-')
            .resolveSymbolicLinksSync(),
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final source = Directory('${dir.path}/source')..createSync();
      final support = Directory('${dir.path}/support')..createSync();
      NativeStorage.persistChosenRoot(support.path, source.path);
      final writer = sqlite3.open('${source.path}/silique.sqlite');
      writer.execute('PRAGMA journal_mode=WAL');
      writer.execute('CREATE TABLE sentinel(value TEXT)');
      writer.execute("INSERT INTO sentinel VALUES('before snapshot')");
      try {
        final recovered = await NativeStorageRecovery.recover(
          source.path,
          '${dir.path}/candidate',
        );
        writer.execute(
          "INSERT INTO sentinel VALUES('later authoritative commit')",
        );
        expect(NativeStorage.recordedRoot(support.path), source.path);
        expect(writer.select('SELECT value FROM sentinel').length, 2);
        final copy = sqlite3.open('$recovered/silique.sqlite');
        try {
          expect(copy.select('SELECT value FROM sentinel').length, 1);
        } finally {
          copy.close();
        }
      } finally {
        writer.close();
      }
    },
  );

  testWidgets(
    'completed recovery is labelled a snapshot and never auto-opens it',
    (tester) async {
      await tester.pumpWidget(
        StartupFailureScreen(
          error: 'SQLITE_IOERR_WRITE',
          hint: 'Source preserved',
          onRecover: () async => '/verified/recovery-copy',
        ),
      );
      await tester.tap(find.text('Odzyskaj do nowego folderu'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('recovery-snapshot-ready')), findsOneWidget);
      expect(find.textContaining('/verified/recovery-copy'), findsOneWidget);
      expect(find.textContaining('Nie została aktywowana'), findsOneWidget);
      expect(find.textContaining('Późniejsze zmiany'), findsOneWidget);
      expect(find.text('Nie udało się otworzyć Silique'), findsOneWidget);
    },
  );
}
