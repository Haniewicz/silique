import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/main.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/storage/windows_folder_access.dart';
import 'package:silique/storage/native_files.dart';
import 'package:silique/ui/location_setup.dart';

const executable = r'C:\Program Files\Silique\silique.exe';
const helper = r'C:\Program Files\Silique\silique_folder_access.exe';
const root = r'C:\Users\Test\Documents\Silique Vaults';

// Keep real host filesystem preparation, translating only at the Windows seam.
// An exact match prevents unrelated folders from sharing the fixture capability.
class _FixtureWindowsFolderAccess extends WindowsFolderAccess {
  _FixtureWindowsFolderAccess({
    required this.fixtureRoot,
    required FolderAccessRunner runProcess,
  }) : super(
         isWindows: true,
         resolvedExecutable: executable,
         runProcess: runProcess,
       );

  final String fixtureRoot;

  String _windowsRoot(String path) {
    if (path != fixtureRoot) {
      throw ArgumentError.value(path, 'path', 'Not the fixture root');
    }
    return root;
  }

  @override
  Future<FolderAccessResult> inspect(String root) =>
      super.inspect(_windowsRoot(root));

  @override
  Future<FolderAccessResult> requestAllow(
    FolderAccessResult inspection,
    String root,
  ) => super.requestAllow(inspection, _windowsRoot(root));
}

ProcessResult reply(
  String status, {
  String exe = executable,
  bool? canRequest = true,
}) => ProcessResult(
  1,
  0,
  jsonEncode({
    'status': status,
    'executable': exe,
    'message': 'Odczytano stan.',
    'canRequest': ?canRequest,
  }),
  '',
);

ButtonStyleButton button(WidgetTester tester, String text) =>
    tester.widget<ButtonStyleButton>(
      find
          .ancestor(
            of: find.text(text, skipOffstage: false),
            matching: find.byWidgetPredicate(
              (widget) => widget is ButtonStyleButton,
              skipOffstage: false,
            ),
          )
          .first,
    );

void main() {
  test('fixture mapping rejects unrelated roots and preserves one-shot validation', () async {
    final directory = Directory.systemTemp.createTempSync('silique-cfa-mapping-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final calls = <List<String>>[];
    final service = _FixtureWindowsFolderAccess(
      fixtureRoot: directory.path,
      runProcess: (program, arguments) async {
        calls.add([program, ...arguments]);
        return reply(arguments.first == '--inspect' ? 'confirmed' : 'allowed');
      },
    );
    final inspected = await service.inspect(directory.path);
    expect(inspected.status, FolderAccessStatus.confirmed);
    expect(inspected.root, root);
    expect(inspected.canRequest, isTrue);
    for (final unrelated in [
      '${directory.path}-other',
      '${directory.path}${Platform.pathSeparator}child',
      root,
    ]) {
      expect(() => service.inspect(unrelated), throwsArgumentError);
      expect(
        () => service.requestAllow(inspected, unrelated),
        throwsArgumentError,
      );
    }
    expect(calls, [
      [helper, '--inspect', root],
    ]);
    expect(
      (await service.requestAllow(inspected, directory.path)).status,
      FolderAccessStatus.allowed,
    );
    expect(
      (await service.requestAllow(inspected, directory.path)).status,
      FolderAccessStatus.failed,
    );
    expect(calls, [
      [helper, '--inspect', root],
      [helper, '--request', root],
    ]);
  });

  test('the real transport decodes helper UTF-8 rather than the OEM code page', () async {
    if (!Platform.isWindows) return;
    const script =
        "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; "
        "Write-Output 'C:\\Program Files\\\u017b\u00f3\u0142\u0107\\silique.exe'";
    final result = await WindowsFolderAccess.runTransport('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      script,
    ]);
    expect(result.stdout, contains('\u017b\u00f3\u0142\u0107'));
  });

  testWidgets(
    'first-run storage failure offers the same explicit CFA consent',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = Directory.systemTemp.createTempSync(
        'silique-cfa-first-run-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      addTearDown(() {
        debugDirectoryPicker = null;
        debugStorageAccess = null;
      });
      debugDirectoryPicker = () async => StorageChoice(path: directory.path);
      debugStorageAccess = (_) {};
      final calls = <List<String>>[];
      await tester.pumpWidget(
        LocationSetupScreen(
          onChosen: (path) async {
            expect(
              path,
              '${directory.path}${Platform.pathSeparator}Silique Vaults',
            );
            expect(Directory(path).existsSync(), isTrue);
            throw StorageRootWriteBlocked(path, 'Write refused');
          },
          folderAccessService: _FixtureWindowsFolderAccess(
            fixtureRoot: directory.path,
            runProcess: (program, arguments) async {
              calls.add([program, ...arguments]);
              return reply(
                arguments.first == '--inspect' ? 'confirmed' : 'allowed',
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.tap(find.byKey(const Key('choose-location')));
      await tester.pumpAndSettle();
      expect(find.text('Zezwól Silique w ochronie Windows'), findsOneWidget);
      expect(calls, [
        [helper, '--inspect', root],
      ]);
      await tester.tap(find.text('Zezwól Silique w ochronie Windows'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('choose-location')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Kontynuuj do UAC'));
      await tester.pumpAndSettle();
      expect(calls, [
        [helper, '--inspect', root],
        [helper, '--request', root],
      ]);
      expect(
        find.text('Dodano zgodę. Zamknij i uruchom Silique ponownie.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('choose-location')))
            .onPressed,
        isNull,
      );
    },
  );
  test('native failed exit one stays a completed failure rather than an unknown operation', () async {
    final service = WindowsFolderAccess(
      isWindows: true,
      resolvedExecutable: executable,
      runProcess: (_, arguments) async => arguments.first == '--inspect'
          ? reply('confirmed')
          : ProcessResult(1, 1, reply('failed').stdout, ''),
    );
    final inspected = await service.inspect(root);
    expect(
      (await service.requestAllow(inspected, root)).status,
      FolderAccessStatus.failed,
    );
  });

  testWidgets(
    'unknown request keeps storage actions locked because elevated operation may still run',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        StartupFailureScreen(
          error: 'Blokada',
          hint: 'Dane pozostają.',
          storageRoot: root,
          folderAccessService: WindowsFolderAccess(
            isWindows: true,
            resolvedExecutable: executable,
            runProcess: (_, arguments) async => reply(
              arguments.first == '--inspect' ? 'confirmed' : 'unconfirmed',
            ),
          ),
          onChooseFolder: () {},
          onRecover: () async => null,
          onRelocate: () async => null,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Zezwól Silique w ochronie Windows'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kontynuuj do UAC'));
      await tester.pumpAndSettle();
      for (final text in [
        'Spróbuj ponownie',
        'Wskaż inny folder',
        'Odzyskaj do nowego folderu',
        'Przenieś notatki',
      ]) {
        expect(button(tester, text).onPressed, isNull);
      }
      expect(button(tester, 'Kopiuj diagnostykę').onPressed, isNotNull);
      expect(
        button(tester, 'Otwórz Zabezpieczenia Windows').onPressed,
        isNotNull,
      );
    },
  );

  test('late inspection cannot replace a newer root capability or revive a consumed request', () async {
    final first = Completer<ProcessResult>();
    var inspections = 0;
    var requests = 0;
    final service = WindowsFolderAccess(
      isWindows: true,
      resolvedExecutable: executable,
      runProcess: (_, arguments) {
        if (arguments.first == '--request') {
          requests++;
          return Future.value(reply('allowed'));
        }
        inspections++;
        return inspections == 1
            ? first.future
            : Future.value(reply('confirmed'));
      },
    );
    final pendingOld = service.inspect(root);
    final current = await service.inspect('$root-new');
    first.complete(reply('confirmed'));
    final old = await pendingOld;
    expect(old.canRequest, isFalse);
    expect(
      (await service.requestAllow(old, root)).status,
      FolderAccessStatus.failed,
    );
    expect(
      (await service.requestAllow(current, '$root-new')).status,
      FolderAccessStatus.allowed,
    );
    final afterRequest = await service.inspect('$root-new');
    expect(afterRequest.canRequest, isFalse);
    expect(requests, 1);
  });

  testWidgets(
    'changing root discards stale inspection and cannot offer UAC for the old root',
    (tester) async {
      final first = Completer<ProcessResult>();
      final second = Completer<ProcessResult>();
      final roots = <String>[];
      final service = WindowsFolderAccess(
        isWindows: true,
        resolvedExecutable: executable,
        runProcess: (_, arguments) {
          roots.add(arguments.last);
          return roots.length == 1 ? first.future : second.future;
        },
      );
      Widget panel(String path) => MaterialApp(
        home: Scaffold(
          body: WindowsFolderAccessPanel(root: path, service: service),
        ),
      );
      await tester.pumpWidget(panel(root));
      await tester.pumpWidget(panel('$root-new'));
      expect(roots, [root, '$root-new']);
      first.complete(reply('confirmed'));
      await tester.pumpAndSettle();
      expect(find.text('Zezwól Silique w ochronie Windows'), findsNothing);
      second.complete(reply('unconfirmed'));
      await tester.pumpAndSettle();
      expect(find.text('Zezwól Silique w ochronie Windows'), findsNothing);
    },
  );

  for (final relocate in [false, true]) {
    testWidgets(
      '${relocate ? 'relocation' : 'recovery'} disables UAC until the storage action finishes',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final pending = Completer<String?>();
        var requests = 0;
        await tester.pumpWidget(
          StartupFailureScreen(
            error: 'Blokada',
            hint: 'Dane pozostają.',
            storageRoot: root,
            folderAccessService: WindowsFolderAccess(
              isWindows: true,
              resolvedExecutable: executable,
              runProcess: (_, arguments) async {
                if (arguments.first == '--request') requests++;
                return reply('confirmed');
              },
            ),
            onRecover: relocate ? null : () => pending.future,
            onRelocate: relocate ? () => pending.future : null,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(
            relocate ? 'Przenieś notatki' : 'Odzyskaj do nowego folderu',
          ),
        );
        await tester.pump();
        expect(
          button(tester, 'Zezwól Silique w ochronie Windows').onPressed,
          isNull,
        );
        expect(button(tester, 'Spróbuj ponownie').onPressed, isNull);
        expect(requests, 0);
        pending.complete(null);
        await tester.pumpAndSettle();
        expect(
          button(tester, 'Zezwól Silique w ochronie Windows').onPressed,
          isNotNull,
        );
      },
    );
  }

  testWidgets(
    'legacy LocalAppData installation cannot auto-prompt even with confirmed CFA',
    (tester) async {
      const legacy = r'C:\Users\Test\AppData\Local\Silique\silique.exe';
      final calls = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WindowsFolderAccessPanel(
              root: root,
              service: WindowsFolderAccess(
                isWindows: true,
                resolvedExecutable: legacy,
                runProcess: (_, arguments) async {
                  calls.add(arguments.first);
                  return reply('confirmed', exe: legacy, canRequest: false);
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Zezwól Silique w ochronie Windows'), findsNothing);
      expect(
        find.textContaining('Zainstaluj Silique ponownie w Program Files'),
        findsOneWidget,
      );
      expect(calls, ['--inspect']);
    },
  );

  test('invalid or failed transport after request is unknown, never cancelled or retried', () async {
    for (final response in <Future<ProcessResult> Function()>[
      () async => ProcessResult(1, 1, reply('allowed').stdout, 'denied'),
      () async => ProcessResult(1, 0, 'invalid', ''),
      () async => reply('allowed', exe: r'C:\Other\silique.exe'),
      () async => throw const ProcessException(helper, [], 'access denied'),
    ]) {
      var requests = 0;
      final service = WindowsFolderAccess(
        isWindows: true,
        resolvedExecutable: executable,
        runProcess: (_, arguments) {
          if (arguments.first == '--inspect') {
            return Future.value(reply('confirmed'));
          }
          requests++;
          return response();
        },
      );
      final inspected = await service.inspect(root);
      expect(
        (await service.requestAllow(inspected, root)).status,
        FolderAccessStatus.unconfirmed,
      );
      expect(
        (await service.requestAllow(inspected, root)).status,
        FolderAccessStatus.failed,
      );
      expect(requests, 1);
    }
  });

  testWidgets(
    'request excludes retry relocation recovery and folder choice; allowed needs a new process',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final pending = Completer<ProcessResult>();
      var requests = 0;
      var storageActions = 0;
      await tester.pumpWidget(
        StartupFailureScreen(
          error: 'Folder zablokowany',
          hint: 'Wybierz działanie.',
          storageRoot: root,
          folderAccessService: WindowsFolderAccess(
            isWindows: true,
            resolvedExecutable: executable,
            runProcess: (_, arguments) {
              if (arguments.first == '--inspect') {
                return Future.value(reply('confirmed'));
              }
              requests++;
              return pending.future;
            },
          ),
          onChooseFolder: () => storageActions++,
          onRecover: () async {
            storageActions++;
            return null;
          },
          onRelocate: () async {
            storageActions++;
            return null;
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Zezwól Silique w ochronie Windows'));
      await tester.pumpAndSettle();
      for (final text in [
        'Spróbuj ponownie',
        'Wskaż inny folder',
        'Odzyskaj do nowego folderu',
        'Przenieś notatki',
      ]) {
        expect(button(tester, text).onPressed, isNull);
      }
      await tester.tap(find.text('Kontynuuj do UAC'));
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(storageActions, 0);
      pending.complete(reply('allowed'));
      await tester.pumpAndSettle();
      expect(
        find.text('Dodano zgodę. Zamknij i uruchom Silique ponownie.'),
        findsOneWidget,
      );
      expect(button(tester, 'Spróbuj ponownie').onPressed, isNull);
      expect(button(tester, 'Przenieś notatki').onPressed, isNotNull);
      expect(find.text('Kopiuj diagnostykę'), findsOneWidget);
      expect(find.byType(StartupFailureScreen), findsOneWidget);
    },
  );

  testWidgets(
    'only storage failures inspect the folder root, never a database file or keychain',
    (tester) async {
      final database = '$root${Platform.pathSeparator}silique.sqlite';
      for (final error in <Object>[
        const StorageRootWriteBlocked(root, 'Folder blokuje zapis.'),
        StorageOpenFailure(
          path: database,
          summary: '778',
          reason: 'Błąd bazy.',
        ),
        StateError('keychain'),
      ]) {
        final inspectedRoots = <String>[];
        final service = WindowsFolderAccess(
          isWindows: true,
          resolvedExecutable: executable,
          runProcess: (_, arguments) async {
            inspectedRoots.add(arguments.last);
            return reply('unconfirmed');
          },
        );
        await tester.pumpWidget(
          startupFailureFor(
            error,
            Directory(r'C:\Support'),
            folderAccessService: service,
          ),
        );
        await tester.pumpAndSettle();
        if (error is StateError) {
          expect(inspectedRoots, isEmpty);
          expect(find.byType(WindowsFolderAccessPanel), findsNothing);
          expect(find.text(StartupFailureScreen.keychainHint), findsOneWidget);
        } else {
          expect(inspectedRoots, [root]);
          expect(find.byType(WindowsFolderAccessPanel), findsOneWidget);
          expect(find.text('Kopiuj diagnostykę'), findsOneWidget);
          expect(
            find.text(
              error is StorageRootWriteBlocked
                  ? 'Przenieś notatki'
                  : 'Odzyskaj do nowego folderu',
            ),
            findsOneWidget,
          );
        }
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets('non-Windows panel is absent and does not inspect', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WindowsFolderAccessPanel(
            root: root,
            service: WindowsFolderAccess(
              isWindows: false,
              runProcess: (_, _) async {
                calls++;
                return reply('confirmed');
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Windows'), findsNothing);
    expect(find.textContaining('CFA'), findsNothing);
    expect(calls, 0);
  });

  testWidgets(
    'unconfirmed inaccessible invalid or missing helper only offers manual settings',
    (tester) async {
      final responses = <Future<ProcessResult> Function()>[
        () async => reply('unconfirmed'),
        () async => reply('failed'),
        () async => ProcessResult(1, 0, 'secret invalid response', ''),
        () async => throw const ProcessException(helper, [], 'secret denied'),
        () async => reply('confirmed', exe: r'C:\Other\silique.exe'),
      ];
      for (var i = 0; i < responses.length; i++) {
        final launched = <Uri>[];
        var requests = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WindowsFolderAccessPanel(
                key: ValueKey(i),
                root: root,
                openSecurity: (uri) async {
                  launched.add(uri);
                  return true;
                },
                service: WindowsFolderAccess(
                  isWindows: true,
                  resolvedExecutable: executable,
                  runProcess: (_, arguments) {
                    if (arguments.first == '--request') requests++;
                    return responses[i]();
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Zezwól Silique w ochronie Windows'), findsNothing);
        expect(
          find.textContaining('Nie potwierdzono, że przyczyną jest'),
          findsOneWidget,
        );
        expect(find.textContaining(executable), findsOneWidget);
        expect(find.textContaining('secret'), findsNothing);
        await tester.tap(find.text('Otwórz Zabezpieczenia Windows'));
        await tester.pumpAndSettle();
        expect(launched.single.toString(), 'windowsdefender://threatsettings');
        expect(requests, 0);
      }
    },
  );

  for (final canRequest in [false, null]) {
    testWidgets(
      'legacy or missing canRequest=$canRequest diagnoses but cannot request UAC',
      (tester) async {
        var requests = 0;
        final service = WindowsFolderAccess(
          isWindows: true,
          resolvedExecutable: executable,
          runProcess: (_, arguments) async {
            if (arguments.first == '--request') requests++;
            return reply('confirmed', canRequest: canRequest);
          },
        );
        final inspected = await service.inspect(root);
        expect(inspected.status, FolderAccessStatus.confirmed);
        expect(
          (await service.requestAllow(inspected, root)).status,
          FolderAccessStatus.failed,
        );
        expect(requests, 0);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WindowsFolderAccessPanel(root: root, service: service),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Zezwól Silique w ochronie Windows'), findsNothing);
        expect(
          find.textContaining('Zainstaluj Silique ponownie w Program Files'),
          findsOneWidget,
        );
        expect(find.textContaining('Potwierdzono'), findsOneWidget);
        expect(requests, 0);
      },
    );
  }

  for (final status in ['allowed', 'cancelled', 'failed', 'unconfirmed']) {
    testWidgets(
      'explicit UAC result $status is shown without retry or restarting in-process',
      (tester) async {
        final calls = <List<String>>[];
        final busy = <bool>[];
        var restartRequired = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WindowsFolderAccessPanel(
                key: ValueKey(status),
                root: root,
                onBusyChanged: busy.add,
                onRestartRequired: () => restartRequired = true,
                service: WindowsFolderAccess(
                  isWindows: true,
                  resolvedExecutable: executable,
                  runProcess: (program, arguments) async {
                    calls.add([program, ...arguments]);
                    return reply(
                      arguments.first == '--inspect' ? 'confirmed' : status,
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Zezwól Silique w ochronie Windows'));
        await tester.pumpAndSettle();
        expect(calls, [
          [helper, '--inspect', root],
        ]);
        await tester.tap(find.text('Kontynuuj do UAC'));
        await tester.pumpAndSettle();
        expect(calls, [
          [helper, '--inspect', root],
          [helper, '--request', root],
        ]);
        expect(busy, status == 'unconfirmed' ? [true] : [true, false]);
        expect(find.text('Zezwól Silique w ochronie Windows'), findsNothing);
        final expectedText = {
          'allowed': 'Dodano zgodę. Zamknij i uruchom Silique ponownie.',
          'cancelled': 'Anulowano zgodę UAC. Nie zmieniono ustawień.',
          'failed': 'Nie udało się dodać zgody. Zmianę mogła zablokować polityka systemowa lub odmowa dostępu.',
          'unconfirmed': 'Nie potwierdzono wyniku. Operacja Windows może nadal trwać. Nie ponawiaj żądania.',
        }[status]!;
        expect(find.textContaining(expectedText), findsOneWidget);
        expect(restartRequired, status == 'allowed' || status == 'unconfirmed');
        expect(find.byType(WindowsFolderAccessPanel), findsOneWidget);
      },
    );
  }

  testWidgets('own consent explains scope and cancelling never invokes UAC', (
    tester,
  ) async {
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WindowsFolderAccessPanel(
            root: root,
            service: WindowsFolderAccess(
              isWindows: true,
              resolvedExecutable: executable,
              runProcess: (_, arguments) async {
                calls.add(arguments.first);
                return reply('confirmed');
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zezwól Silique w ochronie Windows'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('chronionych folderów'), findsOneWidget);
    expect(find.textContaining('Nieznany wydawca'), findsOneWidget);
    expect(find.textContaining('administratora'), findsOneWidget);
    expect(find.textContaining('nie wyłącza'), findsOneWidget);
    await tester.tap(find.text('Anuluj'));
    await tester.pumpAndSettle();
    expect(calls, ['--inspect']);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets(
    'panel only inspects on init and offers explicit allow after confirmation',
    (tester) async {
      final calls = <List<String>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WindowsFolderAccessPanel(
              root: root,
              service: WindowsFolderAccess(
                isWindows: true,
                resolvedExecutable: executable,
                runProcess: (program, arguments) async {
                  calls.add([program, ...arguments]);
                  return reply('confirmed');
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, [
        [helper, '--inspect', root],
      ]);
      expect(find.text('Zezwól Silique w ochronie Windows'), findsOneWidget);
      expect(find.textContaining(root), findsOneWidget);
    },
  );

  test(
    'timeouts fail closed without killing or repeating an unknown request',
    () async {
      final pendingInspection = Completer<ProcessResult>();
      final inspectionService = WindowsFolderAccess(
        isWindows: true,
        resolvedExecutable: executable,
        inspectionTimeout: const Duration(milliseconds: 1),
        runProcess: (_, _) => pendingInspection.future,
      );
      final timedOut = await inspectionService.inspect(root);
      expect(timedOut.status, FolderAccessStatus.failed);
      pendingInspection.complete(reply('confirmed'));
      expect(
        (await inspectionService.requestAllow(timedOut, root)).status,
        FolderAccessStatus.failed,
      );

      final pendingRequest = Completer<ProcessResult>();
      var requests = 0;
      final service = WindowsFolderAccess(
        isWindows: true,
        resolvedExecutable: executable,
        requestTimeout: const Duration(milliseconds: 1),
        runProcess: (_, arguments) {
          if (arguments.first == '--inspect') {
            return Future.value(reply('confirmed'));
          }
          requests++;
          return pendingRequest.future;
        },
      );
      final confirmed = await service.inspect(root);
      final unknown = await service.requestAllow(confirmed, root);
      expect(unknown.status, FolderAccessStatus.unconfirmed);
      expect(unknown.message, isNot(contains('Anulowano')));
      pendingRequest.complete(reply('allowed'));
      final reinspection = await service.inspect(root);
      expect(
        (await service.requestAllow(reinspection, root)).status,
        FolderAccessStatus.failed,
      );
      expect(requests, 1);
    },
  );

  test('other platforms and non-installed executable or relative roots never run a helper', () async {
    for (final config in [
      (false, executable, root),
      (true, r'C:\Tests\flutter_tester.exe', root),
      (true, 'silique.exe', root),
      (true, executable, r'C:relative'),
      (true, executable, ''),
    ]) {
      var calls = 0;
      final service = WindowsFolderAccess(
        isWindows: config.$1,
        resolvedExecutable: config.$2,
        runProcess: (_, _) async {
          calls++;
          return reply('confirmed');
        },
      );
      final result = await service.inspect(config.$3);
      expect(result.status, FolderAccessStatus.failed);
      expect(
        (await service.requestAllow(result, config.$3)).status,
        FolderAccessStatus.failed,
      );
      expect(calls, 0);
    }
  });

  test('request needs this service confirmation for exactly this root and is single use', () async {
    final calls = <List<String>>[];
    final service = WindowsFolderAccess(
      isWindows: true,
      resolvedExecutable: executable,
      runProcess: (program, arguments) async {
        calls.add([program, ...arguments]);
        return reply(arguments.first == '--inspect' ? 'confirmed' : 'allowed');
      },
    );
    final inspected = await service.inspect(root);
    expect(
      (await service.requestAllow(inspected, '$root-other')).status,
      FolderAccessStatus.failed,
    );
    expect(calls, hasLength(1));
    final other = WindowsFolderAccess(
      isWindows: true,
      resolvedExecutable: executable,
      runProcess: (_, _) async => reply('confirmed'),
    );
    expect(
      (await other.requestAllow(inspected, root)).status,
      FolderAccessStatus.failed,
    );
    expect(
      (await service.requestAllow(inspected, root)).status,
      FolderAccessStatus.allowed,
    );
    expect(
      (await service.requestAllow(inspected, root)).status,
      FolderAccessStatus.failed,
    );
    expect(calls, [
      [helper, '--inspect', root],
      [helper, '--request', root],
    ]);
  });

  test(
    'inspection fails closed on invalid or inaccessible helper responses',
    () async {
      final responses = <Future<ProcessResult> Function()>[
        () async => ProcessResult(1, 0, 'not json', ''),
        () async => ProcessResult(1, 1, reply('confirmed').stdout, 'denied'),
        () async => reply('confirmed', exe: r'C:\Other\silique.exe'),
        () async => reply('allowed'),
        () async => ProcessResult(1, 0, '{"status":"confirmed"}', ''),
        () async => ProcessResult(1, 0, '[]', ''),
        () async => throw const ProcessException(helper, [], 'missing'),
      ];
      for (final response in responses) {
        final service = WindowsFolderAccess(
          isWindows: true,
          resolvedExecutable: executable,
          runProcess: (_, _) => response(),
        );
        final result = await service.inspect(root);
        expect(result.status, FolderAccessStatus.failed);
        expect(result.message, isNot(contains('not json')));
      }
    },
  );

  test(
    'inspection is read-only and uses only the installed sibling helper',
    () async {
      final calls = <List<String>>[];
      final service = WindowsFolderAccess(
        isWindows: true,
        resolvedExecutable: executable,
        runProcess: (program, arguments) async {
          calls.add([program, ...arguments]);
          return reply('confirmed');
        },
      );
      final result = await service.inspect(root);
      expect(result.status, FolderAccessStatus.confirmed);
      expect(result.root, root);
      expect(result.executable, executable);
      expect(calls, [
        [helper, '--inspect', root],
      ]);
    },
  );
}
