#!/usr/bin/env python3
"""Replace the one local installation, preserving all user data and keys."""

from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'build/macos/Build/Products/Release/Silique.app'
DESTINATION = Path('/Applications/Silique.app')
BUNDLE_ID = 'pl.novanotes.novaNotes'
LSREGISTER = ('/System/Library/Frameworks/CoreServices.framework/Frameworks/'
              'LaunchServices.framework/Support/lsregister')


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def version(app):
    if app.is_symlink() or not app.is_dir():
        raise RuntimeError(f'Expected an application directory: {app}')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != BUNDLE_ID:
        raise RuntimeError(f'Unexpected application identity: {app}')
    return (info['CFBundleShortVersionString'], int(info['CFBundleVersion']))


def main():
    if sys.platform != 'darwin':
        raise RuntimeError('This installer is only for macOS.')
    current = version(SOURCE)
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(SOURCE))
    processes = run('/bin/ps', '-axo', 'comm=').splitlines()
    if any('/Contents/MacOS/Silique' in item for item in processes):
        raise RuntimeError('Zamknij Silique przed aktualizacją i uruchom skrypt ponownie.')
    if DESTINATION.exists():
        installed = version(DESTINATION)
        if installed[1] > current[1]:
            raise RuntimeError('Refusing to replace a newer installed build.')
    # Hidden staging/backup exists only during replacement. It is removed on
    # success; a failed replacement rolls back before touching the build output.
    with tempfile.TemporaryDirectory(prefix='.silique-install-', dir='/Applications') as folder:
        stage = Path(folder) / 'Silique.app'
        backup = Path(folder) / 'previous'
        run('/usr/bin/ditto', str(SOURCE), str(stage))
        if version(stage) != current:
            raise RuntimeError('Staged application version differs.')
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(stage))
        had_previous = DESTINATION.exists()
        if had_previous:
            DESTINATION.rename(backup)
        try:
            stage.rename(DESTINATION)
        except OSError:
            if had_previous:
                backup.rename(DESTINATION)
            raise
    run(LSREGISTER, '-f', str(DESTINATION))
    # Only known build products are removed; never touch vaults, preferences,
    # application support, signing materials, or the system keychain.
    debug = ROOT / 'build/macos/Build/Products/Debug/Silique.app'
    for app in (SOURCE, debug):
        if app.exists():
            version(app)
            run(LSREGISTER, '-u', str(app))
            shutil.rmtree(app)
    print(f'Zaktualizowano {DESTINATION}: {current[0]}, build {current[1]}.')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from None
