"""Portable contract tests; command doubles are NOT native DMG evidence."""
import contextlib
import io
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

TOOL = Path(__file__).parent


class DmgContractTests(unittest.TestCase):
    def test_ci_and_local_builder_use_dmg_and_run_portable_suite(self):
        ci = (TOOL / 'ci_macos_android.sh').read_text()
        local = (TOOL.parent / 'Zbuduj macOS.command').read_text()
        signing = (TOOL / 'ci_update_release.sh').read_text()
        for script in (ci, local):
            self.assertIn('tool/macos_dmg.py build', script)
            self.assertIn('Silique-macOS.dmg', script)
            self.assertNotIn('Silique-macOS.zip', script)
        self.assertIn('python3 -m unittest discover -s tool', ci)
        self.assertIn('python3 -m unittest discover -s tool', signing)
        self.assertIn('tool/smoke_sparkle_dmg.py', signing)
        self.assertNotIn('-macOS.zip', signing)
        self.assertIn('ASSET_SUFFIXES', signing)
        self.assertIn('macos-dmg-preflight', ci)
        self.assertIn('--version 0.2.29 --build 38', ci)
        self.assertLess(ci.index('macos-dmg-preflight'), ci.index('flutter test'))

    def test_signer_requires_existing_identity_without_creating_keys(self):
        import sign_macos
        with tempfile.TemporaryDirectory() as folder, patch.object(Path, 'home', return_value=Path(folder)), \
                patch.object(sys, 'argv', ['sign_macos.py', 'Silique.app', 'Release.entitlements']), \
                patch.object(sign_macos, 'run', side_effect=RuntimeError('Attempted new identity')) as run:
            with self.assertRaisesRegex(RuntimeError, 'Existing macOS signing identity is required'):
                sign_macos.main()
            run.assert_not_called()
            self.assertFalse((Path(folder) / '.local/share/silique-signing').exists())

    def test_sparkle_smoke_requires_cold_cache_and_inspects_real_extraction(self):
        self.assertTrue((TOOL / 'smoke_sparkle_dmg.py').is_file(), 'Pinned Sparkle DMG smoke is missing')
        import smoke_sparkle_dmg
        import hashlib
        calls = []
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            image = root / 'Silique-0.2.30-macOS.dmg'
            image.write_bytes(b'portable fixture, not a disk image')
            cache = root / 'cache'
            cache.mkdir()
            extracted = cache / hashlib.sha256(image.read_bytes()).hexdigest()
            def native_double(*args):
                calls.append(args)
                (extracted / 'Silique.app').mkdir(parents=True)
                output = Path(args[args.index('-o') + 1])
                output.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>39</sparkle:version><sparkle:shortVersionString>0.2.30</sparkle:shortVersionString><enclosure url="Silique-0.2.30-macOS.dmg" sparkle:edSignature="fixture"/></item></channel></rss>')
            with patch.object(smoke_sparkle_dmg, 'run', side_effect=native_double), \
                    patch.object(smoke_sparkle_dmg, 'validate_app') as inspect, contextlib.redirect_stdout(io.StringIO()):
                smoke_sparkle_dmg.smoke(image, '0.2.30', 39, root / 'generate_appcast', root / 'existing-key', cache)
                inspect.assert_called_once_with(extracted / 'Silique.app', '0.2.30', 39)
                self.assertFalse(extracted.exists())
                self.assertEqual(calls[0][0], str(root / 'generate_appcast'))
                self.assertIn('--ed-key-file', calls[0])
                extracted.mkdir()
                with self.assertRaisesRegex(ValueError, 'cold cache'):
                    smoke_sparkle_dmg.smoke(image, '0.2.30', 39, root / 'generate_appcast', root / 'existing-key', cache)
                self.assertTrue(extracted.exists(), 'Never remove preexisting cache entries')

    def test_native_failure_preserves_stderr_in_private_diagnostics(self):
        import macos_dmg
        import subprocess
        error = subprocess.CalledProcessError(1, ['lipo'], stderr=b'unknown architecture specification')
        with patch.object(macos_dmg.subprocess, 'run', side_effect=error):
            with self.assertRaisesRegex(RuntimeError, 'unknown architecture specification'):
                macos_dmg.run('/usr/bin/lipo', 'synthetic-input')

    def test_dmg_tool_exists(self):
        self.assertTrue((TOOL / 'macos_dmg.py').is_file(), 'Native DMG packaging/verifier is missing')

    def test_verify_is_readonly_unique_noautoopen_and_detaches_on_failure(self):
        import macos_dmg
        self.assertTrue(hasattr(macos_dmg, 'verify_dmg'), 'DMG verifier is missing')
        mounts = []
        calls = []
        def native_double(*args, **kwargs):
            calls.append(args)
            if 'imageinfo' in args:
                return plistlib.dumps({'Format': 'UDZO'})
            if 'attach' in args:
                mount = Path(args[args.index('-mountpoint') + 1])
                mounts.append(mount)
                return plistlib.dumps({'system-entities': [{'mount-point': str(mount), 'dev-entry': '/dev/disk99s1'}]})
            return b''
        with tempfile.TemporaryDirectory() as folder, patch.object(macos_dmg, 'run', side_effect=native_double), \
                patch.object(macos_dmg, 'validate_layout', side_effect=ValueError('bad layout')):
            image = Path(folder) / 'Silique-macOS.dmg'
            image.touch()
            for _ in range(2):
                with self.assertRaisesRegex(ValueError, 'bad layout'):
                    macos_dmg.verify_dmg(image, '0.2.30', 39)
        self.assertNotEqual(mounts[0], mounts[1])
        self.assertTrue(all(not mount.exists() for mount in mounts))
        self.assertTrue(any('verify' in args for args in calls))
        for args in calls:
            if 'attach' in args:
                for flag in ('-readonly', '-nobrowse', '-noautoopen', '-plist'):
                    self.assertIn(flag, args)
        self.assertEqual([args[-1] for args in calls if 'detach' in args], list(map(str, mounts)))

    def test_build_uses_ditto_and_compressed_image_then_verifies_before_publishing(self):
        import macos_dmg
        self.assertTrue(hasattr(macos_dmg, 'build_dmg'), 'DMG builder is missing')
        calls = []
        def native_double(*args, **kwargs):
            calls.append(args)
            if args[0] == '/usr/bin/ditto':
                import shutil
                shutil.copytree(args[1], args[2], symlinks=True)
            if 'create' in args:
                Path(args[-1]).write_bytes(b'not a native image; portable contract only')
            return b''
        with tempfile.TemporaryDirectory() as folder, patch.object(macos_dmg, 'run', side_effect=native_double), \
                patch.object(macos_dmg, 'validate_app'), patch.object(macos_dmg, 'verify_dmg') as verify:
            root = Path(folder)
            app = root / 'Silique.app'
            app.mkdir()
            image = root / 'Silique-macOS.dmg'
            macos_dmg.build_dmg(app, image, '0.2.30', 39)
            self.assertTrue(image.is_file())
            verify.assert_called_once()
            create = next(args for args in calls if 'create' in args)
            self.assertEqual(create[create.index('-format') + 1], 'UDZO')
            self.assertIn('-srcfolder', create)
            with self.assertRaises(ValueError):
                macos_dmg.build_dmg(app, image, '0.2.30', 39)
            import inspect
            self.assertIn('replace', inspect.signature(macos_dmg.build_dmg).parameters)
            macos_dmg.build_dmg(app, image, '0.2.30', 39, replace=True)
            self.assertTrue(image.is_file())

    def test_root_metadata_and_native_code_checks_are_exact(self):
        import macos_dmg
        self.assertTrue(hasattr(macos_dmg, 'validate_app'), 'Root bundle verifier is missing')
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / 'Silique.app'
            (app / 'Contents/MacOS').mkdir(parents=True)
            executable = app / 'Contents/MacOS/Silique'
            executable.write_bytes(b'fixture; lipo is doubled, not native evidence')
            info = {'CFBundleIdentifier': 'pl.novanotes.novaNotes',
                    'CFBundleShortVersionString': '0.2.30', 'CFBundleVersion': '39',
                    'CFBundleExecutable': 'Silique', 'CFBundlePackageType': 'APPL'}
            plist = app / 'Contents/Info.plist'
            plist.write_bytes(plistlib.dumps(info))
            import hashlib
            certificate = b'portable existing certificate fixture'
            certificate_output: list[bytes | None] = [certificate]
            def native_double(*args, **kwargs):
                extract = next((arg for arg in args if arg.startswith('--extract-certificates=')), None)
                if extract is not None and certificate_output[0] is not None:
                    prefix = extract.split('=', 1)[1]
                    Path(prefix + '0').write_bytes(certificate_output[0])
                return b'Authority=Nova Notes Local Preview'
            with patch.object(macos_dmg, 'run', side_effect=native_double) as run, \
                    patch.object(macos_dmg, 'PUBLISHER_CERTIFICATE_SHA256', hashlib.sha256(certificate).hexdigest(), create=True):
                macos_dmg.validate_app(app, '0.2.30', 39)
                self.assertIn(('/usr/bin/lipo', str(executable), '-verify_arch', 'x86_64', 'arm64'), [c.args for c in run.call_args_list])
                self.assertIn(('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)), [c.args for c in run.call_args_list])
                for key, value in [('CFBundleIdentifier', 'wrong'), ('CFBundleVersion', '40'),
                                   ('CFBundleShortVersionString', '0.2.29'),
                                   ('CFBundleExecutable', '../Silique')]:
                    changed = dict(info, **{key: value})
                    plist.write_bytes(plistlib.dumps(changed))
                    with self.subTest(key=key), self.assertRaises(ValueError):
                        macos_dmg.validate_app(app, '0.2.30', 39)
                plist.write_bytes(plistlib.dumps(info))
                certificate_output[0] = b'different certificate with the same human-readable name'
                with self.assertRaisesRegex(ValueError, 'certificate'):
                    macos_dmg.validate_app(app, '0.2.30', 39)
                certificate_output[0] = None  # An ad-hoc signature has no leaf.
                with self.assertRaisesRegex(ValueError, 'certificate'):
                    macos_dmg.validate_app(app, '0.2.30', 39)

    def test_layout_rejects_extra_apps_and_aliases_preserves_framework_links(self):
        if not (TOOL / 'macos_dmg.py').exists():
            self.skipTest('Tool not implemented yet')
        from macos_dmg import validate_layout
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / 'Silique.app'
            framework = app / 'Contents/Frameworks/Example.framework'
            (framework / 'Versions/A').mkdir(parents=True)
            (framework / 'Versions/Current').symlink_to('A')
            sparkle = app / 'Contents/Frameworks/Sparkle.framework'
            (sparkle / 'Versions/B/Updater.app').mkdir(parents=True)
            (sparkle / 'Versions/Current').symlink_to('B')
            (sparkle / 'Updater.app').symlink_to('Versions/Current/Updater.app')
            (root / 'Applications').symlink_to('/Applications')
            validate_layout(root)
            for extra in ('Other.app', 'nested/Other.app', 'Silique.alias'):
                path = root / extra
                path.parent.mkdir(exist_ok=True)
                path.symlink_to('Silique.app')
                with self.subTest(extra=extra), self.assertRaises(ValueError):
                    validate_layout(root)
                path.unlink()
                if path.parent != root:
                    path.parent.rmdir()
            (app / 'Contents/Extra.app').mkdir()
            with self.assertRaisesRegex(ValueError, 'Extra app bundle'):
                validate_layout(root)
            (app / 'Contents/Extra.app').rmdir()
            (framework / 'Escape').symlink_to('/Applications/Silique.app')
            with self.assertRaises(ValueError):
                validate_layout(root)


if __name__ == '__main__':
    unittest.main()
