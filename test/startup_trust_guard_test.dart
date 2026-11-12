import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/contracts.dart';
import 'package:silique/core/server_trust.dart';
import 'package:silique/storage/startup_notebook.dart';

class _Keys implements KeyStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

/// Removes `//` and `/* */` comments (respecting string literals) so the
/// structural guard inspects real code, not prose.
String _stripComments(String source) {
  final out = StringBuffer();
  var i = 0;
  final n = source.length;
  while (i < n) {
    final c = source[i];
    if (c == '"' || c == "'") {
      final quote = c;
      out.write(c);
      i++;
      while (i < n) {
        out.write(source[i]);
        if (source[i] == '\\' && i + 1 < n) {
          out.write(source[i + 1]);
          i += 2;
          continue;
        }
        if (source[i] == quote) {
          i++;
          break;
        }
        i++;
      }
    } else if (c == '/' && i + 1 < n && source[i + 1] == '/') {
      while (i < n && source[i] != '\n') {
        i++;
      }
    } else if (c == '/' && i + 1 < n && source[i + 1] == '*') {
      i += 2;
      while (i + 1 < n && !(source[i] == '*' && source[i + 1] == '/')) {
        i++;
      }
      i += 2;
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

/// Returns the [source] label and the argument span for every *call* to
/// `openStartupNotebook(` (the `Future<Notebook>` declaration is skipped).
List<MapEntry<String, String>> _callArgumentSpans(Map<String, String> files) {
  final calls = <MapEntry<String, String>>[];
  for (final entry in files.entries) {
    final stripped = _stripComments(entry.value);
    final callRe = RegExp(r'openStartupNotebook\s*\(');
    for (final m in callRe.allMatches(stripped)) {
      // Skip the declaration: `Future<Notebook> openStartupNotebook(` has a '>'
      // as the last non-whitespace character before the name.
      var j = m.start - 1;
      while (j >= 0 &&
          (stripped[j] == ' ' ||
              stripped[j] == '\n' ||
              stripped[j] == '\t')) {
        j--;
      }
      if (j >= 0 && stripped[j] == '>') continue;

      final open = m.end - 1; // index of '('
      var depth = 0;
      var k = open;
      for (; k < stripped.length; k++) {
        if (stripped[k] == '(') {
          depth++;
        } else if (stripped[k] == ')') {
          depth--;
          if (depth == 0) break;
        }
      }
      calls.add(MapEntry(entry.key, stripped.substring(open + 1, k)));
    }
  }
  return calls;
}

void main() {
  group('structural guard: production calls pass a resolved support directory',
      () {
    test('every openStartupNotebook( call in lib/ passes applicationSupport',
        () {
      final files = <String, String>{
        'lib/main.dart': File('lib/main.dart').readAsStringSync(),
        for (final f in Directory('lib/storage')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart')))
          f.path: f.readAsStringSync(),
      };

      final calls = _callArgumentSpans(files);

      // Guard against a vacuous pass (e.g. the function being renamed away).
      expect(calls, isNotEmpty,
          reason: 'expected at least one openStartupNotebook( call in lib/');

      final missing = <String>[];
      for (final call in calls) {
        if (!call.value.contains(RegExp(r'applicationSupport\s*:\s*'))) {
          missing.add(call.key);
        }
      }
      expect(
        missing,
        isEmpty,
        reason:
            'every openStartupNotebook( call must pass a support directory; '
            'missing in: $missing',
      );

      // The value must be a real directory, never a literal null or empty.
      final nullablePattern = RegExp(r'''applicationSupport\s*:\s*(null|''|"")''');
      final nullable = <String>[];
      for (final call in calls) {
        if (nullablePattern.hasMatch(call.value)) {
          nullable.add(call.key);
        }
      }
      expect(
        nullable,
        isEmpty,
        reason:
            'no production call may pass applicationSupport: null/"" — found in: '
            '$nullable',
      );

      // The nullable *parameter* must never be forwarded unresolved: the
      // pre-fix code passed `applicationSupport` (null on the existing/relocate
      // path) straight through, silently demoting the store to memory. Only a
      // resolved directory (e.g. `support.path`) may be passed.
      final passthroughPattern =
          RegExp(r'''applicationSupport\s*:\s*applicationSupport\b''');
      final passthrough = <String>[];
      for (final call in calls) {
        if (passthroughPattern.hasMatch(call.value)) {
          passthrough.add(call.key);
        }
      }
      expect(
        passthrough,
        isEmpty,
        reason:
            'no production call may forward the unresolved nullable parameter; '
            'pass a resolved directory (support.path) instead — found in: '
            '$passthrough',
      );
    });
  });

  group('openStartupNotebook store selection', () {
    test('resolves the support directory itself and uses FileTrustStore', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final dir = Directory.systemTemp.createTempSync('silique-null-resolve-');
      addTearDown(() => dir.deleteSync(recursive: true));

      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getApplicationSupportDirectory') return dir.path;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final notebook = await openStartupNotebook(
        '${dir.path}/root',
        keys: _Keys(),
      );
      try {
        expect(notebook.trust.store, isA<FileTrustStore>(),
            reason: 'a null applicationSupport must resolve to a durable file '
                'store, never an in-memory one');
      } finally {
        await notebook.close();
      }
    });
  });
}