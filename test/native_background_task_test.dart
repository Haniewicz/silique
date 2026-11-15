import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/storage/native_background_task.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Records MethodChannel invocations to `silique.notes/background`, so the
  // wrapper can be verified without any real platform call.
  final calls = <String, List<Object?>>{};

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('silique.notes/background'),
          (call) async {
            (calls[call.method] ??= []).add(call.arguments);
            return null;
          },
        );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('silique.notes/background'),
          null,
        );
  });

  test('start/stop only talk to the channel on Android', () async {
    // Non-Android platforms (web/macOS/linux/windows) are no-ops: the channel
    // is never touched and no error is thrown.
    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.iOS,
      TargetPlatform.fuchsia,
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      final task = NativeBackgroundTask();
      await task.start(title: 't', message: 'm');
      await task.stop();
      expect(calls, isEmpty, reason: 'no channel traffic on $platform');
    }

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final task = NativeBackgroundTask();
    await task.start(title: 'Syncing', message: 'Please wait');
    expect(calls['start'], hasLength(1));
    expect(
      (calls['start']!.single as Map)['title'],
      'Syncing',
    );
    expect((calls['start']!.single as Map)['message'], 'Please wait');
    await task.stop();
    expect(calls['stop'], hasLength(1));
  });

  test('a failed notification never aborts the operation path', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('silique.notes/background'),
          (call) async {
            throw PlatformException(code: 'denied', message: 'no permission');
          },
        );

    // Both start and stop must swallow the platform error, so the decorated
    // operation still completes and returns its value.
    var ran = false;
    final value = await withBackgroundTask(
      () async {
        ran = true;
        return 42;
      },
      background: NativeBackgroundTask(),
      title: 't',
      message: 'm',
    );
    expect(ran, isTrue);
    expect(value, 42);
  });

  test('the wrapper stops the service on error and on cancellation', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    // On error: start, then stop, and the error propagates to the caller.
    var stopCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('silique.notes/background'),
          (call) async {
            if (call.method == 'stop') stopCalls++;
            return null;
          },
        );
    await expectLater(
      withBackgroundTask(
        () async => throw StateError('boom'),
        background: NativeBackgroundTask(),
        title: 't',
        message: 'm',
      ),
      throwsStateError,
    );
    // start/stop are fire-and-forget; flush the queued microtasks before
    // asserting that the finally path really posted the stop.
    await Future<void>.delayed(Duration.zero);
    expect(stopCalls, 1);

    // On cancellation: the same finally path stops the service.
    stopCalls = 0;
    try {
      await withBackgroundTask(
        () async {
          // A cancellation-style throw must still stop the service.
          throw Exception('cancelled');
        },
        background: NativeBackgroundTask(),
        title: 't',
        message: 'm',
      );
    } catch (_) {
      // expected: the operation's own throw propagates.
    }
    await Future<void>.delayed(Duration.zero);
    expect(stopCalls, 1);
  });
}