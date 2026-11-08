import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/credential_mode.dart';
import 'package:silique/ui/credential_recovery.dart';

class _Control implements CredentialModeControl {
  @override
  CredentialMode mode = CredentialMode.local;
  @override
  bool cleanupPending = true;
  var calls = 0;
  Future<void> Function()? action;
  @override
  Future<void> retryCleanup() async {
    calls++;
    await action?.call();
    cleanupPending = false;
  }

  @override
  Future<void> changeMode(CredentialMode mode) async =>
      throw StateError('No migration from recovery UI');
}

void main() {
  testWidgets(
    'interrupted credential migration needs explicit cleanup before opening',
    (tester) async {
      final control = _Control();
      var opened = 0;
      await tester.pumpWidget(
        CredentialRecoveryScreen(
          control: control,
          onContinue: () async {
            opened++;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(control.calls, 0);
      expect(opened, 0);
      expect(find.textContaining('Lokalny plik'), findsOneWidget);
      await tester.tap(find.byKey(const Key('credential-recovery-continue')));
      await tester.pumpAndSettle();
      expect(control.calls, 1);
      expect(control.cleanupPending, isFalse);
      expect(opened, 1);
      expect(control.mode, CredentialMode.local);
    },
  );

  testWidgets('failed recovery stays retryable and never opens the notebook', (
    tester,
  ) async {
    final control = _Control();
    final gate = Completer<void>();
    control.action = () => gate.future;
    var opened = 0;
    await tester.pumpWidget(
      CredentialRecoveryScreen(
        control: control,
        onContinue: () async {
          opened++;
        },
      ),
    );
    await tester.tap(find.byKey(const Key('credential-recovery-continue')));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('credential-recovery-continue')),
          )
          .onPressed,
      isNull,
    );
    gate.completeError(StateError('synthetic failure'));
    await tester.pumpAndSettle();
    expect(opened, 0);
    expect(control.cleanupPending, isTrue);
    expect(find.byKey(const Key('credential-recovery-error')), findsOneWidget);
    control.action = null;
    await tester.tap(find.byKey(const Key('credential-recovery-continue')));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });
}
