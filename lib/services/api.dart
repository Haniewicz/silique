import '../l10n/strings.dart';

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show HttpDate, HttpClient, X509Certificate;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../core/contracts.dart';
import '../core/models.dart';
import '../core/server_trust.dart';

class ApiException implements Exception {
  ApiException(this.status, this.message, {this.retryAfter, this.path});
  final String? path;
  final int status;
  final Duration? retryAfter;
  final String message;
  @override
  String toString() => message;
}

/// Thrown when a connection presents a certificate that is neither trusted by
/// the platform nor covered by a confirmed pin. Carries the fingerprint and
/// metadata so the caller can present an informed confirmation prompt — never
/// a silent accept.
class UntrustedServerCertificate implements Exception {
  UntrustedServerCertificate({
    required this.spki,
    required this.subject,
    this.san,
    required this.notAfter,
  });

  final String spki;
  final String subject;
  final String? san;
  final DateTime notAfter;

  @override
  String toString() =>
      'UntrustedServerCertificate(spki: $spki, subject: $subject, '
      'notAfter: $notAfter)';
}

/// Thrown when a connected server presents a public key that does not match the
/// confirmed pin. This is a hard block — no "trust anyway" flag exists.
class ServerCertificatePinMismatch implements Exception {
  ServerCertificatePinMismatch({required this.expected, required this.actual});

  /// The confirmed SPKI pin.
  final String expected;

  /// The SPKI of the certificate actually presented.
  final String actual;

  @override
  String toString() =>
      'ServerCertificatePinMismatch(expected: $expected, actual: $actual)';
}

/// Thrown when a cert's public key matches the pin but the certificate has
/// expired. The pin alone must never admit an expired certificate, because
/// `badCertificateCallback` does not report *why* validation failed.
class ServerCertificateExpired implements Exception {
  ServerCertificateExpired(this.notAfter);
  final DateTime notAfter;
  @override
  String toString() => 'ServerCertificateExpired(notAfter: $notAfter)';
}

class SiliqueApi implements SyncTransport {
  SiliqueApi(
    String server, {
    this.token,
    http.Client? client,
    ServerTrust? trust,
    DateTime Function()? now,
    Duration Function()? elapsed,
  }) : base = validateServer(server),
       client = client ?? _clientFor(trust),
       _now = now ?? DateTime.now,
       _elapsed = elapsed ?? _monotonicClock(),
       trust = trust;

  /// Builds the transport client. Without [ServerTrust], behavior is identical
  /// to the historical default: a plain `http.Client()` over the platform's
  /// normal TLS validation. Only when a [ServerTrust] is supplied do we install
  /// a `badCertificateCallback` that consults a public-key pin as the *fallback*
  /// for certificates the platform itself rejected.
  static http.Client _clientFor(ServerTrust? trust) {
    if (trust == null) return http.Client();
    final inner = HttpClient()
      ..badCertificateCallback = (X509Certificate cert, String host, int port) {
        final base = Uri(scheme: 'https', host: host, port: port);
        return _badCertificateSync(trust, cert, base);
      };
    return IOClient(inner);
  }

  /// Resolves the trust decision synchronously for `badCertificateCallback`
  /// (which cannot await). A pin-backed [ServerTrust] backed by a
  /// [SynchronousServerTrustStore] reads a small JSON file on this path.
  static bool _badCertificateSync(
    ServerTrust trust,
    X509Certificate cert,
    Uri base,
  ) {
    final decision = trust.decideSync(cert: cert, base: base);
    switch (decision) {
      case TrustDecision.allow:
        return true;
      case TrustDecision.pinMismatch:
        final info = certInfoOf(cert);
        throw ServerCertificatePinMismatch(
          expected: trust.lastExpectedPin ?? '',
          actual: info.spki,
        );
      case TrustDecision.expired:
        throw ServerCertificateExpired(cert.endValidity);
      case TrustDecision.unknownCertificate:
        final info = certInfoOf(cert);
        throw UntrustedServerCertificate(
          spki: info.spki,
          subject: info.subject,
          san: info.san,
          notAfter: info.notAfter,
        );
    }
  }

  final DateTime Function() _now;
  final Duration Function() _elapsed;
  final ServerTrust? trust;

  static Duration Function() _monotonicClock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  final Uri base;
  final http.Client client;
  String? token;
  DateTime? _retryAt;

  // The server defaults to 240 requests/minute. Bound all HTTP entry points,
  // not just full syncs: a pass scales with vault count and writes wake our own
  // longpoll. 12 burst + one token/350ms admits at most 185 in any minute,
  // leaving room for setup/other traffic without delaying ordinary small syncs.
  static const _burst = 12;
  static const _tokenInterval = Duration(milliseconds: 350);
  int _tokens = _burst;
  final _admissions = Queue<Completer<void>>();
  Timer? _refill;
  bool _closed = false;

  late Duration _refilledAt = _elapsed();

  void _refillTokens() {
    final now = _elapsed();
    if (now < _refilledAt) _refilledAt = now;
    final count =
        (now - _refilledAt).inMicroseconds ~/ _tokenInterval.inMicroseconds;
    if (count <= 0) return;
    _tokens = (_tokens + count).clamp(0, _burst);
    _refilledAt = _tokens == _burst
        ? now
        : _refilledAt + _tokenInterval * count;
  }

  void _scheduleAdmission() {
    if (_closed || _admissions.isEmpty || _refill != null) return;
    final delay = _refilledAt + _tokenInterval - _elapsed();
    _refill = Timer(delay.isNegative ? Duration.zero : delay, () {
      _refill = null;
      _refillTokens();
      while (_tokens > 0 && _admissions.isNotEmpty) {
        _tokens--;
        _admissions.removeFirst().complete();
      }
      _scheduleAdmission();
    });
  }

  Future<void> _admit({Completer<void>? abort, Uri? uri}) async {
    _checkReady();
    _refillTokens();
    if (_tokens > 0 && _admissions.isEmpty) {
      _tokens--;
    } else {
      final ready = Completer<void>();
      _admissions.add(ready);
      _scheduleAdmission();
      try {
        await Future.any<void>([
          ready.future,
          if (abort != null)
            abort.future.then<void>(
              (_) => throw http.RequestAbortedException(uri),
            ),
        ]);
      } finally {
        _admissions.remove(ready);
        if (_admissions.isEmpty) {
          _refill?.cancel();
          _refill = null;
        }
      }
    }
    if (abort?.isCompleted == true) throw http.RequestAbortedException(uri);
    _checkReady();
  }

  void _checkReady() {
    if (_closed) {
      throw http.ClientException(
        tr('Połączenie zostało zamknięte.', 'The connection has been closed.'),
      );
    }
    _checkCooldown();
  }

  Duration get retryAfter {
    final remaining = _retryAt?.difference(_now()) ?? Duration.zero;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void _checkCooldown() {
    final remaining = retryAfter;
    if (remaining > Duration.zero) {
      throw ApiException(
        429,
        tr(
          'Poczekaj przed ponowną synchronizacją.',
          'Wait before synchronizing again.',
        ),
        retryAfter: remaining,
      );
    }
  }

  ApiException _error(http.Response response, String message) {
    if (response.statusCode == 429) {
      final now = _now();
      final value = response.headers['retry-after'];
      final seconds = int.tryParse(value ?? '');
      DateTime? until;
      if (seconds != null && seconds >= 0) {
        until = now.add(Duration(seconds: seconds));
      } else if (value != null) {
        try {
          until = HttpDate.parse(value);
        } catch (_) {}
      }
      until ??= now.add(const Duration(seconds: 60));
      if (_retryAt == null || until.isAfter(_retryAt!)) _retryAt = until;
    }
    return ApiException(
      response.statusCode,
      message,
      path: response.request?.url.path,
      retryAfter: response.statusCode == 429 ? retryAfter : null,
    );
  }

  static Uri validateServer(String value) {
    final uri = Uri.parse(value.trim().replaceFirst(RegExp(r'/+$'), ''));
    final loopback = ['localhost', '127.0.0.1', '::1'].contains(uri.host);
    final octets = uri.host.split('.').map(int.tryParse).toList();
    final tailnet =
        (octets.length == 4 &&
            octets.every((v) => v != null && v >= 0 && v <= 255) &&
            octets[0] == 100 &&
            octets[1]! >= 64 &&
            octets[1]! <= 127) ||
        uri.host.endsWith('.ts.net');
    if (uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path.isNotEmpty && uri.path != '/') {
      throw FormatException(
        tr(
          'Podaj adres serwera bez ścieżki, np. https://notes.example.com',
          'Enter a server address without a path, e.g. https://notes.example.com',
        ),
      );
    }
    if (uri.scheme != 'https' &&
        !(uri.scheme == 'http' && (loopback || tailnet))) {
      throw FormatException(
        tr(
          'Połączenie wymaga HTTPS. HTTP jest dozwolone lokalnie lub przez Tailscale (100.64.0.0/10 albo .ts.net).',
          'The connection requires HTTPS. HTTP is allowed locally or over Tailscale (100.64.0.0/10 or .ts.net).',
        ),
      );
    }
    return uri.replace(path: '');
  }

  @override
  Future<Json> request(String method, String path, {Json? body}) async {
    await _admit();
    _checkReady();
    final req = http.Request(method, base.resolve(path));
    if (body != null) req.headers['Content-Type'] = 'application/json';
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    if (body != null) req.body = jsonEncode(body);
    // Client.send does not follow redirects: never forward credentials elsewhere.
    req.followRedirects = false;
    Future<http.Response> receive() async =>
        http.Response.fromStream(await client.send(req));
    final response = await receive().timeout(const Duration(seconds: 20));
    if (response.statusCode >= 300) {
      String message = tr(
        'Serwer zwrócił błąd ${response.statusCode}',
        'The server returned error ${response.statusCode}',
      );
      try {
        final decoded = jsonDecode(response.body) as Json;
        message = decoded['error'] as String? ?? message;
        // Fastify returns Zod issues under `details`. Without them a rejected
        // field reads as a bare "Invalid request" and the user cannot tell
        // which input the server refused.
        final details = decoded['details'];
        if (details is List && details.isNotEmpty) {
          final issues = details
              .whereType<Map>()
              .map((issue) {
                final path = issue['path'];
                final field = path is List ? path.join('.') : '$path';
                return field.isEmpty
                    ? '${issue['message'] ?? ''}'
                    : '$field: ${issue['message'] ?? ''}';
              })
              .where((line) => line.trim().isNotEmpty)
              .join('; ');
          if (issues.isNotEmpty) message = '$message ($issues)';
        }
      } catch (_) {}
      throw _error(response, message);
    }
    return response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Json;
  }

  Completer<void>? _changeAbort;
  void cancelChangeWait() {
    final abort = _changeAbort;
    if (abort != null && !abort.isCompleted) abort.complete();
    _changeAbort = null;
  }

  Future<String> waitForChanges(String? cursor) async {
    _checkCooldown();
    cancelChangeWait();
    final abort = Completer<void>();
    _changeAbort = abort;
    final uri = base
        .resolve('/v1/events')
        .replace(queryParameters: cursor == null ? null : {'since': cursor});
    final request = http.AbortableRequest(
      'GET',
      uri,
      abortTrigger: abort.future,
    )..followRedirects = false;
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    try {
      await _admit(abort: abort, uri: uri);
      if (abort.isCompleted) throw http.RequestAbortedException(uri);
      _checkReady();
      Future<http.Response> receive() async =>
          http.Response.fromStream(await client.send(request));
      final response = await receive().timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw _error(
          response,
          tr(
            'Nie udało się odebrać powiadomień.',
            'Could not receive notifications.',
          ),
        );
      }
      final value = (jsonDecode(response.body) as Json)['cursor'];
      if (value is! String || value.isEmpty) {
        throw FormatException(
          tr('Brak kursora zmian.', 'The changes cursor is missing.'),
        );
      }
      return value;
    } finally {
      if (!abort.isCompleted) abort.complete();
      if (identical(_changeAbort, abort)) _changeAbort = null;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _refill?.cancel();
    _refill = null;
    while (_admissions.isNotEmpty) {
      _admissions.removeFirst().completeError(
        http.ClientException(
          tr(
            'Połączenie zostało zamknięte.',
            'The connection has been closed.',
          ),
        ),
      );
    }
    cancelChangeWait();
    client.close();
  }
}
