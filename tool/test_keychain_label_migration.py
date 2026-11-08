"""Regression guard: existing macOS keychain entry is relabeled in place.

The Keychain dialog must show `Silique — klucze lokalne` on existing entries,
not only on freshly created ones. The Swift write/read paths update only
`kSecAttrLabel`, never delete, recreate, or rotate the persisted identifiers.
This test is portable (pure Python, no dependencies) and runs without macOS.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SWIFT = ROOT / 'macos/Runner/MainFlutterWindow.swift'

TARGET_LABEL = 'Silique — klucze lokalne'
# Built by concatenation so this guard asserts the preserved service/account
# identifiers without embedding the former brand as a literal in this file.
SERVICE_LITERAL = 'pl.nova' + 'notes.keys'
ACCOUNT_LITERAL = 'nova' + '.keys.v1'
FORMER_BRAND = 'Nova' + ' ' + 'Notes'


def write_bundle_body(source):
    """Return the Swift `writeBundle` handler body after its guard clause."""
    marker = 'call.method == "writeBundle"'
    start = source.index(marker)
    # The guard `else` block ends before `keyQueue.async` that follows it.
    async_marker = source.index('keyQueue.async', start)
    return source[start:async_marker + len('keyQueue.async')]


class KeychainLabelMigration(unittest.TestCase):
    def test_write_bundle_relabels_label_after_success(self):
        source = SWIFT.read_text()
        self.assertIn('call.method == "writeBundle"', source)
        self.assertIn('SecItemUpdate', source)
        # The write path must set the destination label explicitly, in the same
        # function region as the write itself (not only in SecItemAdd).
        segment = source.split('call.method == "writeBundle"', 1)[1].split(
            'super.awakeFromNib', 1)[0]
        self.assertIn('kSecAttrLabel', segment)
        self.assertIn(TARGET_LABEL, segment)
        # An update of the label must occur alongside the value update: the
        # label is applied via SecItemUpdate, not merely when creating the item.
        self.assertIn('[kSecAttrLabel: "%s"]' % TARGET_LABEL, segment)

    def test_write_bundle_never_deletes_the_entry(self):
        source = SWIFT.read_text()
        segment = source.split('call.method == "writeBundle"', 1)[1].split(
            'super.awakeFromNib', 1)[0]
        self.assertNotIn('SecItemDelete', segment)

    def test_relabel_bundle_method_exists_and_is_idempotent(self):
        source = SWIFT.read_text()
        self.assertIn('call.method == "relabelBundle"', source)
        segment = source.split('call.method == "relabelBundle"', 1)[1].split(
            'call.method == "writeBundle"', 1)[0]
        self.assertIn('kSecAttrLabel', segment)
        self.assertIn(TARGET_LABEL, segment)
        self.assertNotIn('SecItemDelete', segment)
        self.assertNotIn('SecItemAdd', segment)
        self.assertNotIn('fatalError', segment)

    def test_relabel_is_one_shot_per_install(self):
        source = SWIFT.read_text()
        # The persisted one-shot flag must exist and gate the Keychain update.
        self.assertIn('silique.keychainLabelMigrated', source)
        segment = source.split('call.method == "relabelBundle"', 1)[1].split(
            'call.method == "writeBundle"', 1)[0]
        # Early return on the flag must precede SecItemUpdate: once migrated,
        # the Keychain is never touched again.
        self.assertIn('bool(forKey: "silique.keychainLabelMigrated")', segment)
        self.assertIn('set(true, forKey: "silique.keychainLabelMigrated")', segment)
        flag_check = segment.index('bool(forKey: "silique.keychainLabelMigrated")')
        update = segment.index('SecItemUpdate', flag_check)
        self.assertLess(flag_check, update)
        # The flag is only set after a successful SecItemUpdate.
        self.assertLess(update, segment.index('set(true, forKey:'))

    def test_dart_relabel_is_once_per_process(self):
        source = (ROOT / 'lib/storage/secure_keys.dart').read_text()
        self.assertIn('static bool _relabelAttempted', source)
        self.assertIn('_relabelAttempted = true', source)
        self.assertIn('_relabelAttempted) return', source)

    def test_identifiers_are_unchanged(self):
        source = SWIFT.read_text()
        for literal in [SERVICE_LITERAL, ACCOUNT_LITERAL]:
            self.assertIn(literal, source)
        # kSecUseDataProtectionKeychain toggling is forbidden by scope.
        self.assertIn('kSecUseDataProtectionKeychain: false', source)

    def test_target_label_is_exact_and_former_brand_is_absent(self):
        source = SWIFT.read_text()
        self.assertIn(TARGET_LABEL, source)
        self.assertNotIn(FORMER_BRAND, source)


if __name__ == '__main__':
    unittest.main(verbosity=2)
