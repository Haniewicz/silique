import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/storage/native_window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');
  final window = NativeWindow();
  final events = <String>[];
  setUp(() {
    events.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          events.add(call.method);
          return null;
        });
  });
  tearDown(() {
    window.beforeClose = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'repeated close requests share one save and destroy only after it finishes',
    (tester) async {
      final release = Completer<void>();
      window.beforeClose = () async {
        events.add('save-start');
        await release.future;
        events.add('save-durable');
      };
      window.onWindowClose();
      window.onWindowClose();
      await tester.pump(const Duration(seconds: 30));
      // Advancing a long test clock must never bypass a still-pending save.
      expect(events, ['save-start']);
      release.complete();
      await tester.pump();
      expect(events, ['save-start', 'save-durable', 'destroy']);
    },
  );

  testWidgets(
    'failed save leaves window open and a later close retries the save',
    (tester) async {
      window.beforeClose = () async {
        events.add('save-failed');
        throw StateError('synthetic save failure');
      };
      window.onWindowClose();
      await tester.pump();
      expect(events, ['save-failed']);
      window.beforeClose = () async => events.add('save-durable');
      window.onWindowClose();
      await tester.pump();
      expect(events, ['save-failed', 'save-durable', 'destroy']);
    },
  );
}
