import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/contracts.dart';
import 'package:silique/core/key_bundle.dart';

class _Keys implements KeyStore {
  final values = <String, String>{};
  int reads = 0;
  bool deny = false, dropWrites = false;
  bool failNextRead = false, loseNextAcknowledgement = false;
  @override
  Future<String?> read(String key) async {
    reads++;
    if (failNextRead) {
      failNextRead = false;
      throw StateError('Lost write acknowledgement');
    }
    if (deny) throw StateError('Authorization denied');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (!dropWrites) values[key] = value;
    if (loseNextAcknowledgement) {
      loseNextAcknowledgement = false;
      failNextRead = true;
    }
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  test(
    'lost acknowledgement reloads committed keys before another write',
    () async {
      final primary = _Keys(), legacy = _Keys();
      final keys = KeyBundle(primary: primary, legacy: legacy);
      await keys.write('a', 'old');
      primary.loseNextAcknowledgement = true;
      await expectLater(keys.write('a', 'new'), throwsStateError);
      await keys.write('b', 'second');
      final reopened = KeyBundle(primary: primary, legacy: legacy);
      expect(await reopened.read('a'), 'new');
      expect(await reopened.read('b'), 'second');
    },
  );
  test(
    'migrates without deleting old keys; reopening reads one OS item',
    () async {
      final primary = _Keys(), legacy = _Keys();
      legacy.values.addAll({
        'local': 'existing-key',
        'identity': 'existing-id',
      });
      var keys = KeyBundle(primary: primary, legacy: legacy);
      expect(await keys.read('local'), 'existing-key');
      expect(await keys.read('identity'), 'existing-id');
      expect(await keys.read('session'), isNull);
      expect(legacy.values['local'], 'existing-key');
      expect(legacy.values['identity'], 'existing-id');
      final before = primary.reads, legacyBefore = legacy.reads;
      keys = KeyBundle(primary: primary, legacy: legacy);
      expect(await keys.read('local'), 'existing-key');
      expect(await keys.read('identity'), 'existing-id');
      expect(await keys.read('session'), isNull);
      expect(primary.reads - before, 1);
      expect(legacy.reads, legacyBefore);
      await Future.wait([keys.write('a', 'one'), keys.write('b', 'two')]);
      keys = KeyBundle(primary: primary, legacy: legacy);
      expect(await keys.read('a'), 'one');
      expect(await keys.read('b'), 'two');
      await keys.delete('session');
      // A stale backup of the old item cannot resurrect a logged-out session.
      legacy.values['session'] = 'stale-session';
      keys = KeyBundle(primary: primary, legacy: legacy);
      expect(await keys.read('session'), isNull);
    },
  );

  test(
    'denied access and unconfirmed writes preserve the legacy key',
    () async {
      final primary = _Keys(), legacy = _Keys();
      legacy.values['local'] = 'existing-key';
      legacy.deny = true;
      final keys = KeyBundle(primary: primary, legacy: legacy);
      await expectLater(keys.read('local'), throwsStateError);
      expect(primary.values, isEmpty);
      legacy.deny = false;
      primary.dropWrites = true;
      await expectLater(keys.read('local'), throwsStateError);
      expect(legacy.values['local'], 'existing-key');
      primary.dropWrites = false;
      expect(await keys.read('local'), 'existing-key');
    },
  );

  test(
    'corrupt or unsupported key bundles fail closed without fallback',
    () async {
      final primary = _Keys(), legacy = _Keys();
      for (final value in [
        'broken',
        jsonEncode({'version': 2, 'keys': {}}),
      ]) {
        primary.values[KeyBundle.slot] = value;
        final keys = KeyBundle(primary: primary, legacy: legacy);
        await expectLater(keys.read('local'), throwsFormatException);
        expect(legacy.reads, 0);
        expect(primary.values[KeyBundle.slot], value);
      }
    },
  );
}
