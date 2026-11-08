import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/updates.dart';
import 'package:silique/main.dart';
import 'package:silique/services/app_updates.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/ui/dialogs.dart';
import 'package:silique/ui/home.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;
import 'hidden_notes_home_test.dart' as home;

const _installed = InstalledApp('0.2.33', 42, 'macos');

AppRelease get _release => AppRelease(
  version: '0.2.34',
  build: 43,
  notes: '',
  artifacts: {
    'macos': UpdateArtifact(
      url: Uri.https('example.invalid', '/verified-update'),
      sha256: '0' * 64,
      size: 1,
    ),
  },
);

class _StubClient extends UpdateClient {
  _StubClient(this.release);
  final AppRelease release;
  @override
  Future<AppRelease> latest() async => release;
}

class _StubInstaller implements UpdateInstaller {
  _StubInstaller(this.app);
  final InstalledApp? app;
  @override
  Future<InstalledApp?> info() async => app;
  @override
  Future<String> downloadDirectory() async => '/fixture/update-cache';
  @override
  Future<String> installAndroid(String path) async => 'started';
  @override
  Future<void> installMac() async {}
}

Finder _settingsViewport() => find
    .ancestor(
      of: find.byKey(const Key('updates-section')),
      matching: find.byType(SingleChildScrollView),
    )
    .first;

/// The settings dialog must be opened on the given tab.
void _expectSelectedTab(WidgetTester tester, int index) {
  expect(
    tester.widget<TabBar>(find.byType(TabBar)).controller!.index,
    index,
    reason: 'the settings dialog opened on the wrong tab',
  );
}

/// The updates section and the installed-version line must sit fully inside
/// the dialog's scroll viewport, i.e. be reachable without manual scrolling.
void _expectUpdatesSectionVisible(WidgetTester tester) {
  final viewport = tester.getRect(_settingsViewport());
  final section = tester.getRect(find.byKey(const Key('updates-section')));
  expect(
    section.top,
    greaterThanOrEqualTo(viewport.top - 2),
    reason: 'updates section top above the viewport',
  );
  expect(
    section.bottom,
    lessThanOrEqualTo(viewport.bottom + 2),
    reason: 'updates section bottom below the viewport',
  );
  final installed = tester.getRect(find.byKey(const Key('installed-version')));
  expect(installed.top, greaterThanOrEqualTo(viewport.top - 2));
  expect(installed.bottom, lessThanOrEqualTo(viewport.bottom + 2));
}

Future<Notebook> _notebook(WidgetTester tester) async {
  late Notebook repo;
  late Directory dir;
  await tester.runAsync(() async {
    dir = Directory.systemTemp.createTempSync('silique-settings-updates-');
    repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
  });
  addTearDown(() async {
    await repo.storage.close();
    dir.deleteSync(recursive: true);
  });
  return repo;
}

void main() {
  testWidgets('openUpdates: true opens settings directly on the updates tab', (
    tester,
  ) async {
    final repo = await _notebook(tester);
    final updater = AppUpdater(
      client: _StubClient(_release),
      installer: _StubInstaller(_installed),
    )..installed = _installed;
    addTearDown(updater.dispose);
    await tester.binding.setSurfaceSize(const Size(1000, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Dialog(
              child: SettingsPanel(
                notebook: repo,
                onChanged: () {},
                updater: updater,
                openUpdates: true,
              ),
            ),
          ),
        ),
      ),
    );
    // The dialog opens directly on the updates tab; no reveal scroll runs.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    _expectSelectedTab(tester, 4);
    _expectUpdatesSectionVisible(tester);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('openUpdates: false leaves the settings on the general tab', (
    tester,
  ) async {
    final repo = await _notebook(tester);
    final updater = AppUpdater(
      client: _StubClient(_release),
      installer: _StubInstaller(_installed),
    )..installed = _installed;
    addTearDown(updater.dispose);
    await tester.binding.setSurfaceSize(const Size(1000, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Dialog(
              child: SettingsPanel(
                notebook: repo,
                onChanged: () {},
                updater: updater,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    _expectSelectedTab(tester, 0);
    expect(
      find.byKey(const Key('language-picker')),
      findsOneWidget,
      reason: 'the general tab is the landing tab when updates are not asked',
    );
    expect(
      find.byKey(const Key('updates-section')),
      findsNothing,
      reason: 'the updates section must stay hidden when not requested',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('update snackbar action opens settings on the updates section', (
    tester,
  ) async {
    final repo = await home.fixture(tester);
    final updater = AppUpdater(
      client: _StubClient(_release),
      installer: _StubInstaller(_installed),
    )..release = _release;
    // HomeScreen.dispose owns the injected updater, so no extra dispose here.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [notebookProvider.overrideWithValue(repo)],
        child: MaterialApp(home: HomeScreen(updater: updater)),
      ),
    );
    await tester.pumpAndSettle();
    final announce = find.textContaining('Dostępna jest aktualizacja Silique');
    await home.drainUntil(tester, () => announce.evaluate().isNotEmpty);
    await tester.tap(find.widgetWithText(SnackBarAction, 'Zobacz'));
    await home.drainUntil(
      tester,
      () => find.byKey(const Key('updates-section')).evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    _expectUpdatesSectionVisible(tester);
  });
}
