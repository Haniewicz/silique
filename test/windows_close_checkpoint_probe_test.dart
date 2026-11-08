import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('diagnostic real SQLite TRUNCATE reader timing', () async {
    final dir = Directory.systemTemp.createTempSync('silique-truncate-probe-');
    final storage = NativeStorage(dir.path, exclusiveAccess: false);
    final reader = sqlite3.open('${dir.path}/silique.sqlite');
    try {
      storage.db.execute('CREATE TABLE close_probe(value TEXT)');
      storage.db.execute("INSERT INTO close_probe VALUES('before')");
      reader.execute('BEGIN');
      debugPrint('snapshot=${reader.select('SELECT * FROM close_probe')}');
      storage.db.execute("INSERT INTO close_probe VALUES('after')");
      final elapsed = Stopwatch()..start();
      debugPrint('mode=${storage.db.select('PRAGMA journal_mode')}');
      debugPrint('timeout=${storage.db.select('PRAGMA busy_timeout')}');
      final wall = DateTime.now();
      final result = storage.db.select('PRAGMA wal_checkpoint(TRUNCATE)');
      expect(result.single['busy'], 1);
      debugPrint('result=$result');
      debugPrint('wall_ms=${DateTime.now().difference(wall).inMilliseconds}');
      debugPrint('RAW_TRUNCATE elapsed_ms=${elapsed.elapsedMilliseconds}');
      reader.execute('ROLLBACK');
    } finally {
      reader.close();
      await storage.close();
      dir.deleteSync(recursive: true);
    }
  });
}
