import 'dart:async';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/core/updates.dart';
import 'package:silique/main.dart';
import 'package:silique/services/app_updates.dart';
import 'package:silique/storage/native_window.dart';
import 'package:silique/ui/home.dart';

import 'hidden_notes_home_test.dart' as home;
import 'windows_updater_test.dart' show WindowsInstaller;

void main() {
  for (final disposeAfterFailure in [false, true]) {
    testWidgets(
      'failed postlaunch close offers only close retry behind retained Home barrier (dispose=$disposeAfterFailure)',
      (tester) async {
        final repo = await home.fixture(tester);
        late Directory directory;
        late String hash;
        await tester.runAsync(() async {
          directory = Directory.systemTemp.createTempSync(
            'silique-home-close-',
          );
          hash = (await Sha256().hash([1, 2, 3])).bytes
              .map((v) => v.toRadixString(16).padLeft(2, '0'))
              .join();
        });
        addTearDown(() => directory.deleteSync(recursive: true));
        final events = <String>[];
        var closes = 0;
        final releaseClose = Completer<void>();
        const channel = MethodChannel('window_manager');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              expectSync(call.method, 'destroy');
              closes++;
              if (closes == 1) throw PlatformException(code: 'close_failed');
              await releaseClose.future;
              return null;
            });
        NativeWindow.instance.enabled = true;

        addTearDown(() {
          NativeWindow.instance.enabled = false;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });
        final updater =
            AppUpdater(
                installer: WindowsInstaller(directory.path, events),
                client: UpdateClient(
                  clientFactory: () => MockClient((_) async {
                    events.add('download');
                    return http.Response.bytes([1, 2, 3], 200);
                  }),
                ),
              )
              ..release = AppRelease(
                version: '0.2.32',
                build: 41,
                notes: '',
                artifacts: {
                  'windows': UpdateArtifact(
                    url: Uri.parse(
                      'https://github.com/$updateRepository/releases/download/v0.2.32/Silique-0.2.32-Setup-Windows-x64.exe',
                    ),
                    sha256: hash,
                    size: 3,
                  ),
                },
              );
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1440, 1000);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final showHome = ValueNotifier(true);
        addTearDown(showHome.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [notebookProvider.overrideWithValue(repo)],
            child: MaterialApp(
              home: ValueListenableBuilder<bool>(
                valueListenable: showHome,
                builder: (_, visible, _) => visible
                    ? HomeScreen(updater: updater)
                    : const Scaffold(body: Text('Replacement screen')),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final task = updater.install(beforeInstall: () async {});
        await home.drainUntil(
          tester,
          () => updater.stage == UpdateStage.closeRequired,
        );
        await task;
        expect(closes, 1);
        expect(
          find.textContaining('Instalator został uruchomiony'),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('retry-update-close')).hitTestable(),
          findsOneWidget,
        );
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('note-title')))
              .readOnly,
          isTrue,
        );
        await tester.runAsync(
          () => expectLater(
            repo.createVault('Rejected after failed close'),
            throwsStateError,
          ),
        );
        if (disposeAfterFailure) {
          showHome.value = false;
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          await tester.runAsync(
            () => expectLater(
              repo.createVault('Rejected after Home disposal'),
              throwsStateError,
            ),
          );
        } else {
          await tester.tap(find.byKey(const Key('retry-update-close')));
          await tester.pumpAndSettle();
          expect(closes, 2);
          expect(updater.stage, UpdateStage.installing);
          await updater.retryWindowsClose();
          expect(closes, 2, reason: 'Concurrent retry must not close twice');
          expect(find.byType(AlertDialog), findsOneWidget);
          releaseClose.complete();
          await tester.pumpAndSettle();
          expect(updater.busy, isTrue);
          expect(events, ['download', 'native']);
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('note-title')))
                .readOnly,
            isTrue,
          );
          await tester.runAsync(
            () => expectLater(
              repo.createVault('Rejected after close retry'),
              throwsStateError,
            ),
          );
        }
      },
    );
  }
  for (final disposeHome in [false, true]) {
    testWidgets(
      'Home fences editor and SQLite during UAC, then restores both after cancel (dispose=$disposeHome)',
      (tester) async {
        final repo = await home.fixture(tester);
        final events = <String>[];
        late Directory directory;
        late UpdateArtifact artifact;
        await tester.runAsync(() async {
          directory = Directory.systemTemp.createTempSync(
            'silique-home-update-',
          );
          artifact = UpdateArtifact(
            url: Uri.parse(
              'https://github.com/$updateRepository/releases/download/v0.2.32/Silique-0.2.32-Setup-Windows-x64.exe',
            ),
            sha256: (await Sha256().hash([1, 2, 3])).bytes
                .map((v) => v.toRadixString(16).padLeft(2, '0'))
                .join(),
            size: 3,
          );
        });
        addTearDown(() => directory.deleteSync(recursive: true));
        final entered = Completer<void>(), release = Completer<void>();
        final installer = WindowsInstaller(directory.path, events)
          ..outcome = WindowsInstallOutcome.cancelled
          ..onNative = () async {
            entered.complete();
            await release.future;
          };
        final updater =
            AppUpdater(
                installer: installer,
                client: UpdateClient(
                  clientFactory: () => MockClient(
                    (_) async => http.Response.bytes([1, 2, 3], 200),
                  ),
                ),
              )
              ..release = AppRelease(
                version: '0.2.32',
                build: 41,
                notes: '',
                artifacts: {'windows': artifact},
              );
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1440, 1000);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final showHome = ValueNotifier(true);
        addTearDown(showHome.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [notebookProvider.overrideWithValue(repo)],
            child: MaterialApp(
              home: ValueListenableBuilder<bool>(
                valueListenable: showHome,
                builder: (_, visible, _) => visible
                    ? HomeScreen(updater: updater)
                    : const Scaffold(body: Text('Replacement screen')),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('note-title')), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('note-title')),
          'Acknowledged before UAC',
        );
        final task = updater.install(beforeInstall: () async {});
        await home.drainUntil(
          tester,
          () => entered.isCompleted || updater.message != null,
        );
        expect(
          entered.isCompleted,
          isTrue,
          reason: '${updater.message}; events=$events; stage=${updater.stage}',
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('note-title')))
              .readOnly,
          isTrue,
        );
        expect(
          repo.notes.values.single.values.single.title,
          'Acknowledged before UAC',
        );
        await tester.runAsync(
          () =>
              expectLater(repo.createVault('late mutation'), throwsStateError),
        );
        final controller = tester
            .widget<TextField>(find.byKey(const Key('note-title')))
            .controller!;
        controller.text = 'late IME callback must not survive';
        expect(controller.text, 'Acknowledged before UAC');
        if (disposeHome) {
          showHome.value = false;
          await tester.pumpAndSettle();
          expect(
            find.byType(AlertDialog),
            findsNothing,
            reason:
                'a disposed Home must not leave an uncloseable input barrier',
          );
          await tester.runAsync(
            () => expectLater(
              repo.createVault('still awaiting UAC'),
              throwsStateError,
            ),
          );
        }
        release.complete();
        await home.drainUntil(tester, () => !updater.busy);
        await task;
        if (!disposeHome) {
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('note-title')))
                .readOnly,
            isFalse,
          );
        }
        await tester.runAsync(
          () => repo.createVault('Usable after cancellation'),
        );
        expect(repo.vaults, hasLength(2));
      },
    );
  }
}
