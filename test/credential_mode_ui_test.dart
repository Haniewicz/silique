import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/credential_mode.dart';
import 'package:silique/storage/native_files.dart';
import 'package:silique/ui/location_setup.dart';
import 'package:silique/ui/android_credential_migration.dart';
import 'package:silique/ui/credential_recovery.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/ui/dialogs.dart';
import 'package:silique/ui/theme.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

class ModeKeys extends MemoryKeys implements CredentialModeControl {
  ModeKeys(this.mode);
  @override
  CredentialMode mode;
  @override
  bool cleanupPending = false;
  final changes = <CredentialMode>[];
  Completer<void>? gate;
  bool fail = false;
  bool activateBeforeFailure = true;
  int retries = 0;
  @override
  Future<void> changeMode(CredentialMode target) async {
    changes.add(target);
    await gate?.future;
    if (!fail || activateBeforeFailure) mode = target;
    if (fail) {
      cleanupPending = true;
      throw StateError('test cleanup failure');
    }
  }

  @override
  Future<void> retryCleanup() async {
    retries++;
    await gate?.future;
    cleanupPending = false;
  }
}

/// Mounts the settings dialog and opens the requested tab. The credential and
/// hidden-note sections live on the storage & security tab; pass
/// `settings-tab-general` (or `settings-tab-account`) for the other sections.
Future<void> mountSettings(
  WidgetTester tester,
  Directory root,
  MemoryKeys keys, {
  String tab = 'settings-tab-storage',
}) async {
  late Notebook repo;
  await tester.runAsync(() async {
    repo = Notebook(
      storage: NativeStorage(root.path),
      keys: keys,
      crypto: TestCrypto(),
    );
    await repo.initialize();
  });
  addTearDown(() => repo.storage.close());
  await tester.pumpWidget(
    MaterialApp(
      theme: siliqueTheme(),
      home: Scaffold(
        body: SettingsPanel(notebook: repo, onChanged: () {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // The tab bar scrolls; a narrow screen may hide the requested tab.
  final tabFinder = find.byKey(Key(tab));
  await tester.ensureVisible(tabFinder);
  await tester.pumpAndSettle();
  await tester.tap(tabFinder);
  await tester.pumpAndSettle();
}

Future<void> tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void testCredentialWidgets(String description, WidgetTesterCallback callback) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await callback(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('silique-credential-ui-');
    debugStorageAccess = (_) {};
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    debugDirectoryPicker = null;
    debugStorageAccess = null;
    root.deleteSync(recursive: true);
  });

  testCredentialWidgets(
    'declining Android migration leaves legacy keys active without switching',
    (tester) async {
      final keys = ModeKeys(CredentialMode.local);
      var keptLocal = 0;
      var continued = 0;
      await tester.pumpWidget(
        AndroidCredentialMigrationScreen(
          control: keys,
          onKeepLocal: () async => keptLocal++,
          onContinue: () async => continued++,
        ),
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'android-credential-keep-local');
      expect(keptLocal, 1);
      expect(continued, 1);
      expect(keys.changes, isEmpty);
      expect(keys.mode, CredentialMode.local);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testCredentialWidgets(
    'failed Android decline stays on the offer and redacts credential errors',
    (tester) async {
      final keys = ModeKeys(CredentialMode.local);
      var continued = 0;
      await tester.pumpWidget(
        AndroidCredentialMigrationScreen(
          control: keys,
          onKeepLocal: () async =>
              throw StateError('sensitive synthetic credential value'),
          onContinue: () async => continued++,
        ),
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'android-credential-keep-local');
      expect(continued, 0);
      expect(
        find.byKey(const Key('android-credential-migration-error')),
        findsOneWidget,
      );
      expect(
        find.textContaining('sensitive synthetic credential value'),
        findsNothing,
      );
      expect(keys.changes, isEmpty);
      expect(keys.mode, CredentialMode.local);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testCredentialWidgets(
    'Android migration remains usable on narrow enlarged-text screens',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      addTearDown(() {
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        return tester.binding.setSurfaceSize(null);
      });
      final keys = ModeKeys(CredentialMode.local);
      await tester.pumpWidget(
        AndroidCredentialMigrationScreen(
          control: keys,
          onKeepLocal: () async {},
          onContinue: () async {},
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('android-credential-migrate')),
      );
      expect(
        find.byKey(const Key('android-credential-migrate')).hitTestable(),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const Key('android-credential-keep-local')),
      );
      expect(
        find.byKey(const Key('android-credential-keep-local')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testCredentialWidgets(
    'failed Android migration enters existing explicit cleanup recovery',
    (tester) async {
      for (final activated in [false, true]) {
        final keys = ModeKeys(CredentialMode.local)
          ..fail = true
          ..activateBeforeFailure = activated;
        var keptLocal = 0;
        var continued = 0;
        await tester.pumpWidget(
          AndroidCredentialMigrationScreen(
            control: keys,
            onKeepLocal: () async => keptLocal++,
            onContinue: () async => continued++,
          ),
        );
        await tester.pumpAndSettle();
        await tapKey(tester, 'android-credential-migrate');
        expect(find.byType(CredentialRecoveryScreen), findsOneWidget);
        expect(find.textContaining('test cleanup failure'), findsNothing);
        expect(
          keys.mode,
          activated ? CredentialMode.system : CredentialMode.local,
        );
        expect(keptLocal, 0);
        expect(continued, 0);
        await tapKey(tester, 'credential-recovery-continue');
        expect(keys.retries, 1);
        expect(continued, 1);
        expect(keys.changes, [CredentialMode.system]);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testCredentialWidgets(
    'Android migration requires explicit consent and freezes both actions',
    (tester) async {
      final keys = ModeKeys(CredentialMode.local)..gate = Completer<void>();
      var keptLocal = 0;
      var continued = 0;
      await tester.pumpWidget(
        AndroidCredentialMigrationScreen(
          control: keys,
          onKeepLocal: () async => keptLocal++,
          onContinue: () async => continued++,
        ),
      );
      await tester.pumpAndSettle();
      expect(keys.changes, isEmpty);
      expect(keptLocal, 0);
      expect(continued, 0);
      expect(find.textContaining('Android Keystore'), findsOneWidget);
      await tapKey(tester, 'android-credential-migrate');
      expect(keys.changes, [CredentialMode.system]);
      expect(continued, 0);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('android-credential-migrate')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const Key('android-credential-keep-local')),
            )
            .onPressed,
        isNull,
      );
      keys.gate!.complete();
      await tester.pumpAndSettle();
      expect(keys.mode, CredentialMode.system);
      expect(keptLocal, 0);
      expect(continued, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testCredentialWidgets(
    'Android fresh setup has no selector and confirms system mode',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final modes = <CredentialMode>[];
      debugDirectoryPicker = () async => null;
      await tester.pumpWidget(
        LocationSetupScreen(
          chooseCredentialMode: true,
          onChosen: (_) async => fail('fresh setup must dispatch system mode'),
          onChosenWithCredentialMode: (_, mode) async => modes.add(mode),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('credential-mode-local')), findsNothing);
      expect(find.byKey(const Key('credential-mode-system')), findsNothing);
      expect(find.byKey(const Key('credential-local-consent')), findsNothing);
      await tapKey(tester, 'choose-location');
      expect(modes, isEmpty);
      expect(root.listSync(), isEmpty);
      debugDirectoryPicker = () async => StorageChoice(path: root.path);
      await tapKey(tester, 'choose-location');
      expect(modes, [CredentialMode.system]);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testCredentialWidgets(
    'Android settings never offers a credential mode selector',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      for (final mode in CredentialMode.values) {
        final keys = ModeKeys(mode);
        await mountSettings(tester, root, keys);
        expect(find.byKey(const Key('credential-mode-local')), findsNothing);
        expect(find.byKey(const Key('credential-mode-system')), findsNothing);
        expect(keys.changes, isEmpty);
        expect(keys.mode, mode);
        await tester.pumpWidget(const SizedBox());
      }
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testCredentialWidgets(
    'migration disables choices and closing until the operation finishes',
    (tester) async {
      final keys = ModeKeys(CredentialMode.local)..gate = Completer<void>();
      await mountSettings(tester, root, keys);
      await tapKey(tester, 'credential-mode-system');
      expect(keys.changes, [CredentialMode.system]);
      expect(
        find.text('Aktualnie: Lokalny plik (mniej bezpieczny)'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<ListTile>(find.byKey(const Key('credential-mode-local')))
            .onTap,
        isNull,
      );
      expect(
        tester
            .widget<ListTile>(find.byKey(const Key('credential-mode-system')))
            .onTap,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == 'Zamknij',
              ),
            )
            .onPressed,
        isNull,
      );
      keys.gate!.complete();
      await tester.pumpAndSettle();
      expect(
        find.text('Aktualnie: Systemowy magazyn / pęk kluczy'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testCredentialWidgets(
    'failure before activation keeps displayed source mode',
    (tester) async {
      final keys = ModeKeys(CredentialMode.local)
        ..fail = true
        ..activateBeforeFailure = false;
      await mountSettings(tester, root, keys);
      await tapKey(tester, 'credential-mode-system');
      expect(
        find.text('Aktualnie: Lokalny plik (mniej bezpieczny)'),
        findsOneWidget,
      );
      expect(find.textContaining('test cleanup failure'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testCredentialWidgets(
    'legacy keystore settings do not offer credential mode changes',
    (tester) async {
      await mountSettings(tester, root, MemoryKeys());
      expect(find.byKey(const Key('credential-current-mode')), findsNothing);
      expect(find.byKey(const Key('hidden-create-password')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testCredentialWidgets(
    'failed switch reads actual target and blocks migration until cleanup retry',
    (tester) async {
      final keys = ModeKeys(CredentialMode.local)..fail = true;
      await mountSettings(tester, root, keys);
      await tapKey(tester, 'credential-mode-system');
      expect(
        find.text('Aktualnie: Systemowy magazyn / pęk kluczy'),
        findsOneWidget,
      );
      expect(find.textContaining('test cleanup failure'), findsOneWidget);
      expect(find.textContaining('poprzednim magazynie'), findsOneWidget);
      expect(
        tester
            .widget<ListTile>(find.byKey(const Key('credential-mode-local')))
            .onTap,
        isNull,
      );
      await tapKey(tester, 'credential-retry-cleanup');
      expect(keys.retries, 1);
      expect(keys.cleanupPending, false);
      expect(
        tester
            .widget<ListTile>(find.byKey(const Key('credential-mode-local')))
            .onTap,
        isNotNull,
      );
      expect(keys.changes, [CredentialMode.system]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testCredentialWidgets(
    'system downgrade warns and cancellation never changes mode',
    (tester) async {
      final keys = ModeKeys(CredentialMode.system);
      await mountSettings(tester, root, keys);
      await tapKey(tester, 'credential-mode-local');
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('Mniej bezpieczne:'), findsOneWidget);
      expect(keys.changes, isEmpty);
      await tester.tap(find.text('Anuluj'));
      await tester.pumpAndSettle();
      expect(keys.mode, CredentialMode.system);
      expect(keys.changes, isEmpty);
      await tapKey(tester, 'credential-mode-local');
      await tapKey(tester, 'credential-confirm-local');
      expect(keys.changes, [CredentialMode.local]);
      expect(
        find.text('Aktualnie: Lokalny plik (mniej bezpieczny)'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testCredentialWidgets(
    'settings moves the same credentials from local to system',
    (tester) async {
      final keys = ModeKeys(CredentialMode.local);
      await mountSettings(tester, root, keys);
      expect(
        find.text('Aktualnie: Lokalny plik (mniej bezpieczny)'),
        findsOneWidget,
      );
      await tapKey(tester, 'credential-mode-system');
      expect(keys.changes, [CredentialMode.system]);
      expect(
        find.text('Aktualnie: Systemowy magazyn / pęk kluczy'),
        findsOneWidget,
      );
      expect(find.textContaining('Mniej bezpieczne:'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testCredentialWidgets(
    'local consent and real folder confirmation dispatch chosen mode only',
    (tester) async {
      var oldCalls = 0;
      final chosen = <CredentialMode>[];
      debugDirectoryPicker = () async => StorageChoice(path: root.path);
      await tester.pumpWidget(
        LocationSetupScreen(
          chooseCredentialMode: true,
          onChosen: (_) async => oldCalls++,
          onChosenWithCredentialMode: (path, mode) async {
            expect(Directory(path).existsSync(), true);
            chosen.add(mode);
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('credential-local-consent')),
      );
      await tester.tap(find.byKey(const Key('credential-local-consent')));
      await tester.pumpAndSettle();
      expect(chosen, isEmpty);
      expect(root.listSync(), isEmpty);
      await tester.ensureVisible(find.byKey(const Key('choose-location')));
      await tester.tap(find.byKey(const Key('choose-location')));
      await tester.pumpAndSettle();
      expect(chosen, [CredentialMode.local]);
      expect(oldCalls, 0);
    },
  );

  testCredentialWidgets(
    'system choice needs no local consent and cancelling the picker writes nothing',
    (tester) async {
      final modes = <CredentialMode>[];
      debugDirectoryPicker = () async => null;
      await tester.pumpWidget(
        LocationSetupScreen(
          chooseCredentialMode: true,
          onChosen: (_) async => fail('legacy callback must not run'),
          onChosenWithCredentialMode: (_, mode) async => modes.add(mode),
        ),
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'credential-mode-system');
      expect(find.byKey(const Key('credential-local-consent')), findsNothing);
      expect(modes, isEmpty);
      await tapKey(tester, 'choose-location');
      expect(modes, isEmpty);
      expect(root.listSync(), isEmpty);
      debugDirectoryPicker = () async => StorageChoice(path: root.path);
      await tapKey(tester, 'choose-location');
      expect(modes, [CredentialMode.system]);
    },
  );

  testCredentialWidgets(
    'recovery ignores fresh choice flag and never changes credentials',
    (tester) async {
      final db = File('${root.path}/silique.sqlite')
        ..writeAsStringSync('preserved');
      var calls = 0;
      debugDirectoryPicker = () async => StorageChoice(path: root.path);
      await tester.pumpWidget(
        LocationSetupScreen(
          recovering: true,
          chooseCredentialMode: true,
          onChosen: (_) async => calls++,
          onChosenWithCredentialMode: (_, mode) async =>
              fail('recovery must not initialize a new mode'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('credential-mode-local')), findsNothing);
      await tapKey(tester, 'choose-location');
      expect(calls, 1);
      expect(db.readAsStringSync(), 'preserved');
    },
  );

  testCredentialWidgets(
    'local cancellation creates no store and returning to local requires new consent',
    (tester) async {
      var calls = 0;
      debugDirectoryPicker = () async => null;
      await tester.pumpWidget(
        LocationSetupScreen(
          chooseCredentialMode: true,
          onChosen: (_) async => calls++,
          onChosenWithCredentialMode: (_, mode) async => calls++,
        ),
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'credential-local-consent');
      await tapKey(tester, 'choose-location');
      expect(calls, 0);
      expect(root.listSync(), isEmpty);
      await tapKey(tester, 'credential-mode-system');
      await tapKey(tester, 'credential-mode-local');
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('credential-local-consent')),
            )
            .value,
        false,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('choose-location')))
            .onPressed,
        isNull,
      );
    },
  );

  testCredentialWidgets(
    'fresh setup busy guard freezes choice before picker confirmation',
    (tester) async {
      final picker = Completer<StorageChoice?>();
      var calls = 0;
      debugDirectoryPicker = () => picker.future;
      await tester.pumpWidget(
        LocationSetupScreen(
          chooseCredentialMode: true,
          onChosen: (_) async => calls++,
        ),
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'credential-local-consent');
      await tapKey(tester, 'choose-location');
      expect(calls, 0);
      expect(root.listSync(), isEmpty);
      expect(
        tester
            .widget<ListTile>(find.byKey(const Key('credential-mode-system')))
            .onTap,
        isNull,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('credential-local-consent')),
            )
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('choose-location')))
            .onPressed,
        isNull,
      );
      picker.complete(null);
      await tester.pumpAndSettle();
      expect(calls, 0);
    },
  );

  testCredentialWidgets(
    'credential setup and downgrade remain reachable on a narrow large-font phone',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      addTearDown(() {
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        return tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(
        LocationSetupScreen(chooseCredentialMode: true, onChosen: (_) async {}),
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'credential-local-consent');
      await tester.ensureVisible(find.byKey(const Key('choose-location')));
      expect(
        find.byKey(const Key('choose-location')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      final keys = ModeKeys(CredentialMode.system);
      await mountSettings(tester, root, keys);
      await tapKey(tester, 'credential-mode-local');
      expect(find.byType(AlertDialog), findsOneWidget);
      await tapKey(tester, 'credential-confirm-local');
      expect(keys.mode, CredentialMode.local);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testCredentialWidgets(
    'fresh local choice requires visible weaker-security consent',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        LocationSetupScreen(
          chooseCredentialMode: true,
          onChosen: (_) async => calls++,
          onChosenWithCredentialMode: (_, mode) async => calls++,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Lokalny plik (mniej bezpieczny)'), findsOneWidget);
      expect(find.textContaining('tokeny kont'), findsOneWidget);
      expect(find.textContaining('podszywanie się'), findsOneWidget);
      expect(find.textContaining('SQLite'), findsOneWidget);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('credential-local-consent')),
            )
            .value,
        false,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('choose-location')))
            .onPressed,
        isNull,
      );
      expect(calls, 0);
    },
  );
}
