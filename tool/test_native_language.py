"""Portable native language contracts; native Swift probe runs only on macOS."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NativeLanguageContracts(unittest.TestCase):
    def test_windows_saved_preference_messages(self):
        header = ROOT / 'windows/runner/native_language.h'
        self.assertTrue(header.is_file(), 'Missing native Windows language helper')
        compiler = shutil.which('g++') or shutil.which('clang++')
        if not compiler:
            self.skipTest('Portable C++17 probe requires g++ or clang++; Windows build compiles the runner')
        with tempfile.TemporaryDirectory(prefix='silique-language-') as directory:
            probe = Path(directory) / 'probe'
            subprocess.run([compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror',
                            '-I', str(ROOT), str(ROOT / 'test/native/windows_language_probe.cpp'),
                            '-o', str(probe)], check=True)
            subprocess.run([str(probe)], check=True)

    def test_windows_startup_gate_remains_before_flutter(self):
        source = (ROOT / 'windows/runner/flutter_window.cpp').read_text()
        self.assertIn('WindowsInstanceMessage(ReadInterfaceLanguage())', source)
        self.assertIn('WindowsUpdateDirectoryMessage(ReadInterfaceLanguage())', source)
        self.assertLess(source.index('if (!silique::AcquireWindowsApplicationInstance())'),
                        source.index('WindowsInstanceMessage(ReadInterfaceLanguage())'))
        self.assertLess(source.index('WindowsInstanceMessage(ReadInterfaceLanguage())'),
                        source.index('std::make_unique<flutter::FlutterViewController>'))
        self.assertIn('FOLDERID_RoamingAppData, KF_FLAG_DONT_VERIFY', source)
        self.assertIn('GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE', source)
        self.assertIn('OPEN_EXISTING', source)
        reader = source.split('bool ReadInterfaceLanguage()', 1)[1].split('std::string Utf8', 1)[0]
        for mutation in ['CREATE_ALWAYS', 'OPEN_ALWAYS', 'WriteFile', 'CreateDirectory']:
            self.assertNotIn(mutation, reader)
        resource = (ROOT / 'windows/runner/Runner.rc').read_text()
        self.assertIn('VALUE "CompanyName", "Silique"', resource)
        self.assertIn('VALUE "ProductName", "silique"', resource)
        self.assertIn('WindowsUpdateBlocksClose()', source)

    def test_macos_bridge_and_application_messages(self):
        window = (ROOT / 'macos/Runner/MainFlutterWindow.swift').read_text()
        updater = (ROOT / 'macos/Runner/SiliqueUpdater.swift').read_text()
        self.assertIn('name: "silique/language"', window)
        self.assertIn('call.method == "setLanguage"', window)
        self.assertIn('arguments["languageCode"] as? String', window)
        self.assertIn('code == "en" || code == "pl"', window)
        self.assertIn('UserDefaults.standard.string(forKey: preferenceKey) == "pl"', window)
        self.assertIn('UserDefaults.standard.set(code, forKey: preferenceKey)', window)
        self.assertIn('SiliqueLanguage.text(', window)
        self.assertEqual(updater.count('SiliqueLanguage.text('), 5)
        # Do not localize credential identities or the existing keychain label.
        for preserved in ['silique.notes/storage', 'silique.notes/keys',
                          'pl.silique.keychain-writes', 'silique.storageBookmarks',
                          'pl.novanotes.keys', 'nova.keys.v1', 'Silique — klucze lokalne']:
            self.assertIn(preserved, window)
        for preserved in ['silique.notes/updates', 'silique.notes/lifecycle',
                          'flushBeforeQuit', 'startingUpdater: false',
                          'if (result as? Bool) == true', 'pendingInstall = nil']:
            self.assertIn(preserved, updater)
        self.assertNotIn('forKey: "AppleLanguages"', window + updater)
        # Language updates must not replace the Flutter window/editor.
        handler = window.split('call.method == "setLanguage"', 1)[1].split('let storageChannel', 1)[0]
        self.assertNotIn('FlutterViewController()', handler)

    @unittest.skipUnless(platform.system() == 'Darwin', 'Requires native macOS Swift/Foundation')
    def test_macos_language_preference_native(self):
        source = (ROOT / 'macos/Runner/MainFlutterWindow.swift').read_text()
        helper = source.split('// BEGIN native language helper\n', 1)[1].split('// END native language helper', 1)[0]
        with tempfile.TemporaryDirectory(prefix='silique-language-') as directory:
            root = Path(directory)
            (root / 'main.swift').write_text(
                'import Foundation\n' + helper + '\n' +
                (ROOT / 'test/native/macos_language_probe.swift').read_text())
            subprocess.run(['xcrun', 'swiftc', str(root / 'main.swift'), '-o', str(root / 'probe')], check=True)
            result = subprocess.run([str(root / 'probe')], check=True, capture_output=True, text=True)
            self.assertIn('Native language probe passed', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
