import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/models.dart';
import 'package:silique/main.dart';
import 'package:silique/storage/native_storage.dart';

// The 0.2.23 injected journal-PRAGMA failures only proved a hypothetical
// WAL-only refusal. Real readonly files and persisted modes are now exercised;
// actual Win32 byte-range I/O locks run separately on the Windows builder.
void main() {
  late Directory tmp;
  setUp(
    () => tmp = Directory.systemTemp.createTempSync('silique-open-failure-'),
  );
  tearDown(() {
    NativeStorage.diagnosticsDirectory = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> seedData(String root) async {
    final storage = NativeStorage(root);
    storage.putVault(
      Vault(
        id: 'vault-1',
        name: 'Notatki',
        mode: 'plain',
        keyWrap: '',
        localWrap: '',
        metadata: '',
      ),
    );
    storage.putDocument('vault-1', 'note-1', '{"title":"Pierwsza"}');
    await storage.close();
  }

  test(
    'repeated real reopen preserves contents and journal without a mode flip',
    () async {
      final root = '${tmp.path}/vault';
      await seedData(root);
      for (var i = 0; i < 5; i++) {
        final storage = NativeStorage(root);
        expect(storage.journalMode, 'wal');
        expect(storage.documents('vault-1')['note-1'], contains('Pierwsza'));
        storage.putDocument('vault-1', 'note-2', '{"iteration":$i}');
        await storage.close();
      }
      final reopened = NativeStorage(root);
      expect(reopened.documents('vault-1')['note-2'], '{"iteration":4}');
      await reopened.close();
    },
  );

  test(
    'readonly file fails truthfully, closes its handle and records native limits',
    () async {
      final root = '${tmp.path}/OneDrive/Dokumenty/Silique Vaults';
      await seedData(root);
      final database = File('$root/silique.sqlite');
      final before = database.readAsBytesSync();
      final support = Directory('${tmp.path}/support')..createSync();
      NativeStorage.diagnosticsDirectory = support.path;
      expect(Process.runSync('chmod', ['444', database.path]).exitCode, 0);
      try {
        expect(
          () => NativeStorage(root),
          throwsA(
            isA<StorageOpenFailure>()
                .having((e) => e.path, 'database path', database.path)
                .having(
                  (e) => e.reason,
                  'no false keychain diagnosis',
                  isNot(contains('Keyring')),
                )
                .having(
                  (e) => e.reason,
                  'preserve WAL warning',
                  contains('WAL'),
                )
                .having(
                  (e) => e.diagnostics['sqlite_primary_code'],
                  'readonly code',
                  8,
                ),
          ),
        );
        expect(database.readAsBytesSync(), before);
        final log = NativeStorage.readDiagnostics()!;
        expect(log, contains('storage_open_failure'));
        expect(log, contains(database.path));
        expect(log, contains('cloud_folder=OneDrive'));
        expect(log, contains('native_error_source='));
        expect(
          File('$root/${NativeStorage.diagnosticsFileName}').existsSync(),
          isFalse,
        );
      } finally {
        // SQLite may create sidecars with the readonly database's inherited mode.
        // Restoring just the main fixture file does not restore those permissions.
        for (final suffix in ['', '-wal', '-shm']) {
          final file = File('${database.path}$suffix');
          if (file.existsSync()) Process.runSync('chmod', ['644', file.path]);
        }
      }
      final moved = Directory(root).renameSync('$root-moved');
      final reopened = NativeStorage(moved.path);
      expect(reopened.documents('vault-1')['note-1'], contains('Pierwsza'));
      await reopened.close();
    },
    skip: Platform.isWindows
        ? 'POSIX permissions; Win32 lock fixture runs separately'
        : null,
  );

  test('checkpoint truncates WAL without removing committed notes', () async {
    final root = '${tmp.path}/vault';
    await seedData(root);
    final storage = NativeStorage(root);
    storage.putDocument('vault-1', 'note-2', '{"title":"Druga"}');
    final wal = File('$root/silique.sqlite-wal');
    expect(wal.existsSync() && wal.lengthSync() > 0, isTrue);
    storage.checkpointJournal();
    expect(wal.lengthSync(), 0);
    expect(storage.documents('vault-1')['note-2'], contains('Druga'));
    await storage.close();
  });

  testWidgets(
    'storage error offers folder choice and copies exact diagnostics',
    (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add('${(call.arguments as Map)['text']}');
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      var choseFolder = false;
      await tester.pumpWidget(
        StartupFailureScreen(
          error: 'SqliteException(778): while executing, disk I/O error',
          hint: 'Nie można otworzyć bazy notatek w /dane/Silique Vaults.',
          onChooseFolder: () => choseFolder = true,
        ),
      );
      expect(find.textContaining('/dane/Silique Vaults'), findsOneWidget);
      expect(find.text(StartupFailureScreen.keychainHint), findsNothing);
      await tester.tap(find.byKey(const Key('startup-failure-choose-folder')));
      expect(choseFolder, isTrue);
      await tester.tap(find.byKey(const Key('startup-failure-copy')));
      await tester.pumpAndSettle();
      expect(copied.single, contains('SqliteException(778)'));
    },
  );

  testWidgets('recovery action is explicit, busy-guarded and shows failures', (
    tester,
  ) async {
    var calls = 0;
    final completer = Completer<String?>();
    await tester.pumpWidget(
      StartupFailureScreen(
        error: 'SqliteException(778)',
        hint: 'Baza i dziennik WAL wymagają odzyskania do nowego folderu.',
        onRecover: () {
          calls++;
          return completer.future;
        },
      ),
    );
    await tester.tap(find.text('Odzyskaj do nowego folderu'));
    await tester.pump();
    expect(calls, 1);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Spróbuj ponownie'),
          )
          .onPressed,
      isNull,
    );
    completer.completeError(
      StateError('Nie można odczytać WAL; oryginał zachowano.'),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Nie można odczytać WAL'), findsOneWidget);
    expect(find.text('Odzyskaj do nowego folderu'), findsOneWidget);
  });

  testWidgets('keychain failure retains guidance with no folder escape', (
    tester,
  ) async {
    await tester.pumpWidget(
      const StartupFailureScreen(error: 'PlatformException(no keyring)'),
    );
    expect(find.text(StartupFailureScreen.keychainHint), findsOneWidget);
    expect(
      find.byKey(const Key('startup-failure-choose-folder')),
      findsNothing,
    );
    expect(find.textContaining('PlatformException'), findsOneWidget);
  });
}
