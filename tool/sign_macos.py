#!/usr/bin/env python3
"""Stable, isolated local-preview signer. No system trust settings are changed.

The certificate is deliberately self-signed, not an Apple Developer ID. Keep
this directory with the Android release key when backing up local signing keys.
See https://developer.apple.com/library/archive/technotes/tn2206/ .
"""

import os
from pathlib import Path
import subprocess
import sys


def run(*args):
    # Never include command arguments in failures: security receives passwords.
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"{Path(args[0]).name} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def main():
    if len(sys.argv) != 3:
        raise SystemExit('Usage: sign_macos.py APP ENTITLEMENTS')
    os.umask(0o077)
    root = Path.home() / '.local/share/silique-signing'
    keychain = root / 'macos-preview.keychain-db'
    password_file = root / 'macos-preview.password'
    certificate = root / 'macos-preview.crt'
    if not all(path.is_file() for path in (keychain, password_file, certificate)):
        raise RuntimeError('Existing macOS signing identity is required; never generate replacement keys.')
    password = password_file.read_text().strip()
    fingerprint = run('/usr/bin/openssl', 'x509', '-in', str(certificate),
                      '-noout', '-fingerprint', '-sha1').split('=')[1].replace(':', '')
    run('/usr/bin/security', 'unlock-keychain', '-p', password, str(keychain))
    try:
        # Pin the actual signer and bundle ID. A bundle-ID-only requirement would
        # let unrelated code impersonate this app to the legacy Keychain.
        requirement = (f'=designated => identifier "pl.novanotes.novaNotes" '
                       f'and certificate leaf = H"{fingerprint}"')
        sparkle = Path(sys.argv[1]) / 'Contents/Frameworks/Sparkle.framework'
        if sparkle.exists():
            for item in ['Versions/B/XPCServices/Installer.xpc',
                         'Versions/B/XPCServices/Downloader.xpc',
                         'Versions/B/Autoupdate', 'Versions/B/Updater.app', '.']:
                component = sparkle / item
                if component.exists():
                    args = ['/usr/bin/codesign', '--force', '--sign', fingerprint,
                            '--keychain', str(keychain), '--options', 'runtime']
                    if item.endswith('Downloader.xpc'):
                        args += ['--preserve-metadata=entitlements']
                    run(*args, str(component))
        run('/usr/bin/codesign', '--force', '--sign', fingerprint,
            '--keychain', str(keychain), '--requirements', requirement,
            '--entitlements', sys.argv[2], sys.argv[1])
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', sys.argv[1])
    finally:
        run('/usr/bin/security', 'lock-keychain', str(keychain))
    print('Local preview signature verified (stable certificate and app identity).')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError) as error:
        raise SystemExit(str(error)) from None
