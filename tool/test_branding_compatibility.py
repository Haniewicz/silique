"""Presentation rebranding must not rotate persisted identities or wire domains."""
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
BRAND = re.compile(r'nova[ _.-]?notes', re.I)
# Exact literals, exact paths. Documentation entries preserve historical facts;
# none of these grant permission to reuse the former product name in UI copy.
COMPAT = {
    'pl.novanotes.nova_notes': (
        'android/app/build.gradle.kts', 'linux/CMakeLists.txt',
        'linux-gtk4/CMakeLists.txt', 'tool/package_linux_gtk4.py',
        'tool/check_linux_settings_scroll.py', 'tool/prepare_update.py',
        'tool/test_prepare_update.py', 'docs/rebrand.md', 'docs/HANDOFF.md',
        'docs/0.2.19.md', 'docs/0.2.20.md', 'docs/0.2.22.md', 'docs/0.2.27.md',
        'docs/0.2.28.md', 'docs/0.2.29.md', 'docs/0.2.32.md',
        'docs/migration-signing-identity.md',
    ),
    'pl.novanotes.novaNotes': (
        'macos/Runner/Configs/AppInfo.xcconfig',
        'macos/Runner.xcodeproj/project.pbxproj',
        'macos/Runner/DebugProfile.entitlements', 'macos/Runner/Release.entitlements',
        'tool/sign_macos.py', 'tool/install_macos.py', 'tool/macos_dmg.py',
        'tool/test_macos_dmg.py', 'docs/rebrand.md', 'docs/0.2.29.md',
        'docs/hermes-verification-2026-10-22.md', 'docs/migration-signing-identity.md',
        'docs/HANDOFF.md',
    ),
    'pl.novanotes.keys': (
        'lib/storage/secure_keys.dart', 'macos/Runner/MainFlutterWindow.swift',
        'tool/test_native_language.py', 'docs/rebrand.md', 'docs/releases.md',
    ),
    '/.well-known/nova-notes': ('lib/services/notebook.dart', 'docs/rebrand.md', 'docs/migration-signing-identity.md'),
    # Android keyAlias — compatibility identifier, kept unchanged during the
    # macOS signing identity rotation. Narrow literal, sign/scoping only.
    'nova-notes': (
        'docs/migration-signing-identity.md', 'docs/HANDOFF.md',
        'tool/make_signing_identity.sh',
    ),
    # Legacy data-directory name (persistence identifier, not UI brand) as
    # named in the rotation handoff/migration docs.
    'Nova Notes': ('docs/migration-signing-identity.md', 'docs/HANDOFF.md'),
    r'\nkeyAlias=nova-notes\n': ('tool/ci_macos_android.sh', '.github/workflows/build.yml'),
    # Historyczny CN podpisu macOS, zrotowany na "Silique" 2026-11-10. Żywą
    # tożsamością jest CN=Silique; ten literal wolno utrzymywać wyłącznie jako
    # fakt proweniencji w starych dokumentach, nie w kodzie ani nowych pinach.
    'Nova Notes Local Preview': ('docs/0.2.30.md', 'docs/rebrand.md', 'docs/migration-signing-identity.md', 'docs/HANDOFF.md'),
    # Historyczny fakt w proweniencji wydań: CN certyfikatu podpisującego
    # ANDROIDA (tożsamość zachowana — rotacja macOS z 2026-11-10 jej NIE dotyczy).
    # Wpis wąski: dokładny literal i wyłącznie pliki proweniencji/dokumenty rotacji
    # — nie zwalnia z brandingu żadnego kodu.
    'CN=Nova Notes': (
        'docs/0.2.31.md',
        'docs/0.2.35.md',
        'docs/0.2.36.md',
        'docs/HANDOFF.md',
        'docs/migration-signing-identity.md',
        'tool/make_signing_identity.sh',
    ),
}
LEGACY_PATH_LINES = {
    'lib/storage/native_storage.dart': "final legacy = Directory('$applicationSupport/Nova Notes');",
    'test/workspace_domain_test.dart': "final legacy = Directory('${support.path}/Nova Notes')..createSync();",
    'test/workspace_review_test.dart': "final old = Directory('${support.path}/Nova Notes')..createSync();",
    'test/rebrand_migration_test.dart': (
        "final oldRoot = '${support.path}/Nova Notes';",
        "Directory('${support.path}/Nova Notes').createSync();",
        "expect(Directory('${support.path}/Nova Notes').existsSync(), isTrue);",
    ),
}


def violations(path, text):
    errors = []
    for number, line in enumerate(text.splitlines(), 1):
        allowed = LEGACY_PATH_LINES.get(path, ())
        if isinstance(allowed, str):
            allowed = (allowed,)
        if line.strip() in allowed:
            continue
        remainder = line
        for literal, paths in COMPAT.items():
            if path in paths:
                pattern = re.escape(literal)
                if not literal.startswith('\\n'):
                    pattern = r'(?<![A-Za-z0-9_])' + pattern + r'(?![A-Za-z0-9_])'
                remainder = re.sub(pattern, '', remainder)
        if BRAND.search(remainder):
            errors.append(f'{path}:{number}: {line.strip()}')
    return errors


class BrandingCompatibility(unittest.TestCase):
    def test_no_unapproved_former_brand(self):
        tracked = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT).decode().split('\0')
        errors = []
        for name in tracked:
            if not name or name == 'tool/test_branding_compatibility.py':
                continue
            try:
                text = (ROOT / name).read_text(encoding='utf-8')
            except (UnicodeError, IsADirectoryError):
                continue
            errors.extend(violations(name, text))
        self.assertEqual(errors, [], '\n'.join(errors))

    def test_allowlist_is_not_a_file_wide_branding_exemption(self):
        self.assertTrue(violations('lib/storage/native_storage.dart', "print('Nova Notes');"))
        self.assertTrue(violations('lib/ui/home.dart', "Text('pl.novanotes.nova_notes')"))
        self.assertFalse(violations('android/app/build.gradle.kts', 'applicationId = "pl.novanotes.nova_notes"'))
        self.assertTrue(violations('macos/Runner/Configs/AppInfo.xcconfig', 'PRODUCT_BUNDLE_IDENTIFIER = pl.novanotes.novaNotesReplacement'))

    def test_data_crypto_signing_identity_pins_remain(self):
        assignments = {
            'android/app/build.gradle.kts': (r'^\s*applicationId\s*=\s*"([^"]+)"\s*$', 'pl.novanotes.nova_notes'),
            'macos/Runner/Configs/AppInfo.xcconfig': (r'^PRODUCT_BUNDLE_IDENTIFIER\s*=\s*(\S+)\s*$', 'pl.novanotes.novaNotes'),
            'macos/Runner.xcodeproj/project.pbxproj': (r'^\s*PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);\s*$', 'pl.novanotes.novaNotes.RunnerTests'),
            'tool/macos_dmg.py': (r"^BUNDLE_ID\s*=\s*'([^']+)'\s*$", 'pl.novanotes.novaNotes'),
            'tool/install_macos.py': (r"^BUNDLE_ID\s*=\s*'([^']+)'\s*$", 'pl.novanotes.novaNotes'),
        }
        for name, (pattern, expected) in assignments.items():
            values = re.findall(pattern, (ROOT / name).read_text(), re.M)
            self.assertTrue(values, f'{name}: missing identity assignment')
            self.assertEqual(set(values), {expected}, f'{name}: exact identity changed')
        pins = {
            'lib/core/key_bundle.dart': ["'nova.keys.v1'", "'silique.keys.v2'"],
            'lib/storage/secure_keys.dart': ["'pl.novanotes.keys'", 'flutter_secure_storage.dat'],
            'lib/storage/native_storage.dart': ['nova.sqlite', 'Nova Notes', '.silique-pending-rename'],
            'lib/core/crypto.dart': ['nova:1:pairing'],
            'lib/core/models.dart': ['silique:2:note:', 'nova:1:note:'],
            'lib/services/notebook.dart': [
                'silique:2:vault-key', 'silique:2:folder-base', 'silique:2:vault-meta',
                'silique:2:local-note', 'silique:2:local-vault',
                # legacy read fallback (never removed in this release)
                'nova:1:vault-meta:', 'nova:1:folder-base:',
                # account and pairing envelopes stay nova:1 forever
                'nova:1:account:', 'nova:1:pairing', '/.well-known/nova-notes',
            ],
            'android/app/build.gradle.kts': ['applicationId = "pl.novanotes.nova_notes"'],
            'macos/Runner/Configs/AppInfo.xcconfig': ['PRODUCT_BUNDLE_IDENTIFIER = pl.novanotes.novaNotes'],
            'tool/sign_macos.py': ['certificate leaf = H"{fingerprint}"', 'pl.novanotes.novaNotes', 'CN=Silique'],
            # macOS publisher leaf SHA-256, rotated 2026-11-10 to CN=Silique.
            # Placeholder until the owner runs tool/make_signing_identity.sh and
            # pastes its printed digest here and in tool/macos_dmg.py.
            'tool/macos_dmg.py': ['0000000000000000000000000000000000000000000000000000000000000000'],
        }
        for name, literals in pins.items():
            text = (ROOT / name).read_text()
            for literal in literals:
                self.assertIn(literal, text, f'{name}: compatibility pin changed: {literal}')


if __name__ == '__main__':
    unittest.main()
