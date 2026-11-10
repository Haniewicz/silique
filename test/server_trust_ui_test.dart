import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/server_trust.dart';
import 'package:silique/services/api.dart';
import 'package:silique/ui/server_trust_dialogs.dart';
import 'package:silique/ui/theme.dart';

const _spkiA = 'MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWZ4eXoxMjM0';
const _spkiB = 'Nzg5MGFiY2RlZjAxMjM0NTY3ODlhYmNkZWZ4eXoxMjM0MDEyMzQ1Ng==';

/// In-memory [ServerTrustStore] so widget tests never touch the real file
/// system (real I/O does not complete under the test binding's fake-async
/// zone). Behaves identically to [FileTrustStore] for the tested surface.
class _MemoryTrustStore implements SynchronousServerTrustStore {
  final _records = <String, Map<String, String>>{};

  /// Mirrors [FileTrustStore]'s normalization: a missing or empty record
  /// reads as "no pin", matching how a "forget" (empty write) is observed.
  static Map<String, String>? _normalize(Map<String, String>? record) =>
      record == null || record.isEmpty ? null : record;

  @override
  Future<Map<String, String>?> read(String serverKey) async =>
      _normalize(_records[serverKey]);

  @override
  Future<void> write(String serverKey, Map<String, String> record) async {
    _records[serverKey] = Map.of(record);
  }

  @override
  Map<String, String>? readSync(String serverKey) =>
      _normalize(_records[serverKey]);
}

void main() {
  group('groupSpki', () {
    test('groups base64 into 4-character blocks', () {
      expect(
        groupSpki('MDEyMzQ1Njc4OWFi'),
        'MDEy MzQ1 Njc4 OWFi',
      );
      expect(groupSpki(''), '');
      expect(groupSpki('a'), 'a');
      expect(groupSpki('abcd'), 'abcd');
      expect(groupSpki('abcde'), 'abcd e');
    });
  });

  group('unknown certificate dialog', () {
    testWidgets('shows fingerprint; Cancel does not store a pin', (tester) async {
      await tester.pumpWidget(_app((context) => TextButton(
        onPressed: () async {
          final trusted = await showUnknownCertificateDialog(
            context,
            server: 'https://notes.example.com',
            error: UntrustedServerCertificate(
              spki: _spkiA,
              subject: 'CN=notes.example.com',
              notAfter: DateTime(2035),
            ),
          );
          _lastResult = trusted;
        },
        child: const Text('Open'),
      )));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Nieznany certyfikat serwera'),
        findsOneWidget,
      );
      final fingerprint = tester.widget<SelectableText>(
        find.byKey(const Key('server-trust-fingerprint')),
      );
      expect(fingerprint.data, groupSpki(_spkiA));
      expect(find.textContaining('CN=notes.example.com'), findsOneWidget);

      await tester.tap(find.text('Anuluj'));
      await tester.pumpAndSettle();
      expect(_lastResult, isFalse);
    });

    testWidgets('Trust stores the pin and retries the connection once',
        (tester) async {
      final store = _MemoryTrustStore();
      final trust = ServerTrust(store: store);
      final base = Uri.parse('https://notes.example.com');
      var attempts = 0;

      Future<String> attempt() async {
        attempts++;
        if (attempts == 1) {
          throw UntrustedServerCertificate(
            spki: _spkiA,
            subject: 'CN=notes.example.com',
            notAfter: DateTime(2035),
          );
        }
        return 'connected';
      }

      var result = '';
      await tester.pumpWidget(_app((context) => TextButton(
        onPressed: () async {
          result = await connectTrustingServerCertificate<String>(
            context: context,
            trust: trust,
            base: base,
            attempt: attempt,
          );
        },
        child: const Text('Connect'),
      )));
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Nieznany certyfikat serwera'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('server-trust-confirm')));
      await tester.pumpAndSettle();

      expect(result, 'connected');
      expect(attempts, 2);
      final record = await store.read(serverKeyOf(base));
      expect(record?['spki'], _spkiA);
      expect(record?['subject'], 'CN=notes.example.com');
      expect(record?['savedAt'], isNotNull);
      expect(record?['notAfter'], isNotNull);
    });
  });

  group('pin mismatch dialog', () {
    testWidgets('shows expected and actual and no trust button', (tester) async {
      await tester.pumpWidget(_app((context) => TextButton(
        onPressed: () => showPinMismatchDialog(
          context,
          server: 'https://notes.example.com',
          error: ServerCertificatePinMismatch(
            expected: _spkiA,
            actual: _spkiB,
          ),
        ),
        child: const Text('Open'),
      )));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Certyfikat serwera się zmienił'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const Key('server-trust-expected')),
            )
            .data,
        groupSpki(_spkiA),
      );
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const Key('server-trust-actual')),
            )
            .data,
        groupSpki(_spkiB),
      );
      expect(find.text('Zaufaj temu serwerowi'), findsNothing);
      expect(find.byKey(const Key('server-trust-mismatch-close')), findsOneWidget);
    });
  });

  group('expired certificate dialog', () {
    testWidgets('points at renew-cert', (tester) async {
      await tester.pumpWidget(_app((context) => TextButton(
        onPressed: () => showExpiredCertificateDialog(
          context,
          server: 'https://notes.example.com',
          error: ServerCertificateExpired(DateTime(2024)),
        ),
        child: const Text('Open'),
      )));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Text>(find.byKey(const Key('server-trust-renew-cert')))
            .data,
        contains('renew-cert'),
      );
    });
  });

  group('trusted server certificate settings section', () {
    testWidgets('no pin shows the trusted-CA note', (tester) async {
      final trust = ServerTrust(store: _MemoryTrustStore());
      await tester.pumpWidget(_app(
        (context) => Scaffold(
          body: TrustedServerCertSection(
            trust: trust,
            base: Uri.parse('https://notes.example.com'),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('server-trust-none')), findsOneWidget);
      expect(find.byKey(const Key('server-trust-forget')), findsNothing);
    });

    testWidgets('pin present shows fingerprint, dates, and forget removes it',
        (tester) async {
      final store = _MemoryTrustStore();
      final trust = ServerTrust(store: store);
      final base = Uri.parse('https://notes.example.com');
      await trust.confirm(
        base,
        CertInfo(
          spki: _spkiA,
          subject: 'CN=notes.example.com',
          notAfter: DateTime(2035),
        ),
      );

      await tester.pumpWidget(_app(
        (context) => Scaffold(
          body: TrustedServerCertSection(trust: trust, base: base),
        ),
      ));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const Key('server-trust-pinned')),
            )
            .data,
        groupSpki(_spkiA),
      );
      expect(find.byKey(const Key('server-trust-pinned-at')), findsOneWidget);
      expect(
        find.byKey(const Key('server-trust-pinned-not-after')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('server-trust-forget')));
      await tester.pumpAndSettle();
      // Confirmation gate — removing requires an explicit confirm.
      expect(
        find.textContaining('Usunąć zaufany certyfikat'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('server-trust-forget-confirm')));
      await tester.pumpAndSettle();

      expect(await store.read(serverKeyOf(base)), isNull);
      expect(find.byKey(const Key('server-trust-none')), findsOneWidget);
    });
  });

  group('regression', () {
    testWidgets('a clean connection never shows any trust dialog', (tester) async {
      final trust = ServerTrust(store: _MemoryTrustStore());
      var result = '';
      await tester.pumpWidget(_app((context) => TextButton(
        onPressed: () async {
          result = await connectTrustingServerCertificate<String>(
            context: context,
            trust: trust,
            base: Uri.parse('https://notes.example.com'),
            attempt: () async => 'ok',
          );
        },
        child: const Text('Connect'),
      )));
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(result, 'ok');
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}

bool? _lastResult;

Widget _app(WidgetBuilder home) => MaterialApp(
  theme: siliqueTheme(),
  home: Builder(builder: home),
);
