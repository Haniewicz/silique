"""Exercise preparation IO with external native/signing commands doubled."""
import base64
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as XML

import prepare_update


class PreparedDmgTests(unittest.TestCase):
    def test_prepare_emits_only_dmg_wirekey_and_signs_dmg(self):
        self.assertTrue(hasattr(prepare_update, 'verify_dmg'), 'Preparation must use the native DMG verifier')
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            tools = root / '.local/share/silique-toolchains'
            (tools / 'android-sdk/build-tools/fixture').mkdir(parents=True)
            (tools / 'android-sdk/build-tools/fixture/aapt2').touch()
            key = root / '.local/share/silique-signing/updater-ed25519.key'
            key.parent.mkdir(parents=True)
            key.write_text('not a real key; signing command is doubled')
            key.chmod(0o600)
            notes = root / 'notes.txt'
            notes.write_text('DMG installer.')
            out = root / 'prepared'
            args = ['prepare_update.py', '--version', '0.2.30', '--build', '39', '--notes', str(notes), '--out', str(out)]
            for platform, suffix in prepare_update.ASSET_SUFFIXES.items():
                installer = root / ('candidate' + suffix)
                installer.write_bytes(platform.encode())
                args += ['--macos' if platform == 'macos-dmg' else '--' + platform, str(installer)]
            commands = []
            def command_double(command, **kwargs):
                commands.append(command)
                if 'badging' in command:
                    text = "package: name='pl.novanotes.nova_notes' versionCode='39' versionName='0.2.30'\n"
                elif '--print-certs' in command:
                    text = '2021902e8c43d5c10059c9f0458ed8c1ac94fce86a488f7b46d0b0eb3467996e'
                else:
                    text = base64.b64encode(bytes(64)).decode()
                return subprocess.CompletedProcess(command, 0, stdout=text)
            with patch.object(Path, 'home', return_value=root), patch.object(sys, 'argv', args), \
                    patch.object(prepare_update.subprocess, 'run', side_effect=command_double), \
                    patch.object(prepare_update, 'verify_dmg') as verify, contextlib.redirect_stdout(io.StringIO()):
                prepare_update.main()
            verify.assert_called_once_with(root / 'candidate-macOS.dmg', '0.2.30', 39)
            manifest = json.loads(base64.b64decode(json.loads((out / 'latest.json').read_text())['payload']))
            self.assertEqual(set(manifest['platforms']), set(prepare_update.ASSET_SUFFIXES))
            self.assertNotIn('macos', manifest['platforms'])
            self.assertEqual(len((out / 'SHA256SUMS.txt').read_text().splitlines()), 7)
            enclosure = XML.parse(out / 'appcast.xml').find('./channel/item/enclosure')
            self.assertEqual(enclosure.get('url'), manifest['platforms']['macos-dmg']['url'])
            self.assertTrue(enclosure.get('url').endswith('/Silique-0.2.30-macOS.dmg'))
            signed = [command[-1] for command in commands if '-p' in command]
            self.assertIn(str(out / 'Silique-0.2.30-macOS.dmg'), signed)
            self.assertFalse(any('.zip' in str(path) and 'macOS' in str(path) for path in out.iterdir()))


if __name__ == '__main__':
    unittest.main()
