"""Exercise candidate collection with real synthetic files, no remote writes."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

# The owner's operations script is deliberately not part of this repository, so
# this module skips instead of failing the whole suite on a public checkout
# (previously it broke every CI build of the candidate workflows).
_SCRIPT = Path(__file__).parent / 'hermes/silique'
if not _SCRIPT.exists():
    raise unittest.SkipTest(
        'owner-only operations script tool/hermes/silique is not shipped here')

loader = importlib.machinery.SourceFileLoader('hermes_collect', str(_SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
assert spec is not None
operations = importlib.util.module_from_spec(spec)
loader.exec_module(operations)


class CollectDmgTest(unittest.TestCase):
    def test_collects_only_dmg_for_macos_and_sends_seven_installers(self):
        with tempfile.TemporaryDirectory(prefix='silique-collect-dmg-') as scratch:
            root = Path(scratch)
            (root / 'releases').mkdir()
            linux = root / 'linux'
            linux.mkdir()
            sha = 'a' * 40
            version = '0.2.30'
            (linux / 'SOURCE_COMMIT').write_text(sha + '\n')
            for suffix in ['-Linux-GTK4-x64.tar.gz', '-Linux-GTK4-amd64.deb', '-Linux-GTK4-x86_64.rpm']:
                (linux / f'Silique-{version}{suffix}').write_bytes(b'synthetic-linux-fixture')
            calls = []

            def run(*args, **kwargs):
                calls.append(tuple(map(str, args)))
                if args[:3] == ('gh', 'run', 'view'):
                    workflow = 'macOS and Android installer candidate' if args[3] == '1' else 'Windows installer candidate'
                    return json.dumps({'conclusion': 'success', 'workflowName': workflow})
                if args[:3] == ('gh', 'run', 'download'):
                    directory = Path(args[args.index('--dir') + 1])
                    directory.mkdir()
                    names = ['Silique-macOS.dmg', 'Silique.apk'] if args[3] == '1' else [f'Silique-{version}-Setup-Windows-x64.exe', f'Silique-{version}-Windows-x64.zip']
                    for name in names:
                        (directory / name).write_bytes(b'synthetic-installer-fixture')
                    (directory / 'build-provenance.json').write_text(json.dumps({'source_commit': sha}))
                return None

            args = SimpleNamespace(ref=sha, macos_run='1', windows_run='2', linux_dir=str(linux), notes=str(root / 'notes.txt'))
            with patch.object(operations, 'ROOT', root), patch.object(operations, 'commit', return_value=sha), patch.object(operations, 'source_version', return_value=(version, '39')), patch.object(operations, 'run', side_effect=run):
                operations.collect(args)
            public = root / 'releases/candidate-0.2.30-39/installers'
            names = {entry.name for entry in public.iterdir()}
            self.assertEqual(len(names), 7)
            self.assertIn('Silique-0.2.30-macOS.dmg', names)
            self.assertNotIn('Silique-0.2.30-macOS.zip', names)
            publish = next(call for call in calls if call[:3] == ('gh', 'release', 'create'))
            self.assertIn('--draft', publish)
            self.assertEqual(sum(Path(arg).name in names for arg in publish), 7)


if __name__ == '__main__':
    unittest.main()
