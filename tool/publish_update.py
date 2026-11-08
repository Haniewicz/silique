#!/usr/bin/env python3
"""Publish an owner-approved prepared update to the installer-only public repo.

Usage requires --publish deliberately. It uploads and verifies a draft first,
then publishes assets, then advances both signed feeds. It never copies code.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as XML
from prepare_update import REPOSITORY, SPARKLE_NS, ASSET_SUFFIXES, safe_notes
from macos_dmg import verify_dmg


def installer_names(manifest):
    """Only canonical assets from the signed installer-only release are allowed."""
    version = manifest['version']
    platforms = manifest['platforms']
    if not {'android', 'macos-dmg'}.issubset(platforms) or not set(platforms).issubset(ASSET_SUFFIXES):
        raise ValueError('Unexpected or incomplete installer platforms.')
    for first, second in [('windows', 'windows-portable'), ('linux', 'linux-deb')]:
        if (first in platforms) != (second in platforms):
            raise ValueError('Incomplete desktop installer/portable pair.')
    if ('linux' in platforms) != ('linux-rpm' in platforms):
        raise ValueError('Incomplete Linux DEB/RPM release.')
    names = []
    for platform, suffix in ASSET_SUFFIXES.items():
        if platform not in platforms:
            continue
        name = f'Silique-{version}{suffix}'
        expected = f'https://github.com/{REPOSITORY}/releases/download/v{version}/{name}'
        if platforms[platform]['url'] != expected:
            raise ValueError('Noncanonical installer URL.')
        names.append(name)
    return names


def run(*args, cwd=None):
    return subprocess.run(args, cwd=cwd, check=True, text=True, capture_output=True).stdout.strip()


def verify_prepared_macos(source, manifest, notes):
    """Authenticate both feeds' shared DMG and inspect it before any upload."""
    version = manifest['version']
    signing = Path.home() / '.local/share/silique-toolchains/sparkle-2.10.0/bin/sign_update'
    key = Path.home() / '.local/share/silique-signing/updater-ed25519.key'
    run(str(signing), '--ed-key-file', str(key), '--verify', str(source / 'appcast.xml'))
    safe_notes((source / 'appcast.xml').read_text())
    items = XML.parse(source / 'appcast.xml').findall('./channel/item')
    if len(items) != 1:
        raise ValueError('Expected one current appcast item.')
    enclosure = items[0].find('enclosure')
    macos = manifest['platforms']['macos-dmg']
    if (enclosure is None or enclosure.get('url') != macos['url']
        or enclosure.get(f'{{{SPARKLE_NS}}}version') != str(manifest['build'])
        or enclosure.get(f'{{{SPARKLE_NS}}}shortVersionString') != version
        or enclosure.get('length') != str(macos['size'])
        or items[0].findtext('description') != notes):
        raise ValueError('macOS appcast differs from the signed manifest.')
    image = source / f'Silique-{version}-macOS.dmg'
    run(str(signing), '--ed-key-file', str(key), '--verify',
        str(image), enclosure.get(f'{{{SPARKLE_NS}}}edSignature', ''))
    verify_dmg(image, version, manifest['build'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepared', type=Path, required=True)
    parser.add_argument('--repository', type=Path, required=True)
    parser.add_argument('--publish', action='store_true', required=True)
    args = parser.parse_args()
    source = args.prepared.resolve()
    repository = args.repository.resolve()
    app = Path(__file__).resolve().parent.parent
    dart = Path.home() / '.local/share/silique-toolchains/flutter/bin/dart'
    run(str(dart), 'run', str(app / 'tool/check_update_feed.dart'), str(source / 'latest.json'), cwd=app)
    envelope = json.loads((source / 'latest.json').read_text())
    manifest = json.loads(base64.b64decode(envelope['payload']))
    version = manifest['version']
    installers = installer_names(manifest)
    names = [*installers, 'SHA256SUMS.txt']
    expected = {'latest.json', 'appcast.xml', 'release-notes.txt', *names}
    if {p.name for p in source.iterdir()} != expected:
        raise ValueError('Prepared directory contains unexpected files. Nothing will be published.')
    notes = safe_notes((source / 'release-notes.txt').read_text())
    if notes != manifest['notes']:
        raise ValueError('Notes differ from signed metadata.')
    remote = run('git', 'remote', 'get-url', 'origin', cwd=repository)
    if remote not in [f'https://github.com/{REPOSITORY}', f'https://github.com/{REPOSITORY}.git']:
        raise ValueError('Not the installer-only public repository.')
    if run('git', 'status', '--porcelain', cwd=repository):
        raise ValueError('Public repository must be clean before publishing.')
    if run('git', 'branch', '--show-current', cwd=repository) != 'main':
        raise ValueError('Use the distribution repository main branch.')
    run('git', 'pull', '--ff-only', 'origin', 'main', cwd=repository)
    tracked = set(run('git', 'ls-files', cwd=repository).splitlines())
    if not tracked.issubset({'README.md', 'latest.json', 'appcast.xml', '.github/workflows/windows.yml', '.github/workflows/linux.yml', '.github/workflows/macos-android.yml', '.github/workflows/update-release.yml'}):
        raise ValueError('Public repository contains unexpected files. Refusing to publish code.')
    info = json.loads(run('gh', 'repo', 'view', REPOSITORY, '--json', 'isPrivate,nameWithOwner'))
    if info['isPrivate'] or info['nameWithOwner'] != REPOSITORY:
        raise ValueError('Unexpected distribution repository.')
    for platform in manifest['platforms']:
        asset = manifest['platforms'][platform]
        path = source / asset['url'].rsplit('/', 1)[1]
        if path.stat().st_size != asset['size'] or hashlib.sha256(path.read_bytes()).hexdigest() != asset['sha256']:
            raise ValueError('Installer differs from signed metadata.')
    # A feed must never go backwards even if an old prepared directory is used.
    if (repository / 'latest.json').exists():
        run(str(dart), 'run', str(app / 'tool/check_update_feed.dart'), str(repository / 'latest.json'), cwd=app)
        old = json.loads(base64.b64decode(json.loads((repository / 'latest.json').read_text())['payload']))
        if manifest['build'] < old['build'] or (manifest['version'] != old['version'] and manifest['build'] <= old['build']):
            raise ValueError('Refusing to publish an older build.')
    expected_sums = ''.join(hashlib.sha256((source / name).read_bytes()).hexdigest() + '  ' + name + '\n' for name in installers)
    actual_sums = (source / 'SHA256SUMS.txt').read_text().splitlines()
    if len(actual_sums) != len(installers) or set(actual_sums) != set(expected_sums.splitlines()):
        raise ValueError('Checksum file differs from the verified installers.')
    verify_prepared_macos(source, manifest, notes)
    tag = 'v' + version
    existing = subprocess.run(['gh', 'release', 'view', tag, '--repo', REPOSITORY, '--json', 'isDraft,assets'], capture_output=True, text=True)
    if existing.returncode:
        run('gh', 'release', 'create', tag, *(str(source / n) for n in names), '--repo', REPOSITORY,
            '--target', 'main', '--draft', '--title', 'Silique ' + version, '--notes-file', str(source / 'release-notes.txt'))
    release = json.loads(run('gh', 'release', 'view', tag, '--repo', REPOSITORY, '--json', 'isDraft,assets'))
    if {a['name'] for a in release['assets']} != set(names):
        raise ValueError('Release assets incomplete; keep draft and fix before retrying.')
    for asset in release['assets']:
        local = source / asset['name']
        digest = hashlib.sha256(local.read_bytes()).hexdigest()
        if asset.get('digest') != 'sha256:' + digest or asset['size'] != local.stat().st_size:
            raise ValueError('Remote asset differs from the approved installer.')
    if release['isDraft']:
        run('gh', 'release', 'edit', tag, '--repo', REPOSITORY, '--draft=false', '--latest')
    for name in ['latest.json', 'appcast.xml']:
        shutil.copy2(source / name, repository / name)
    run('git', 'add', 'latest.json', 'appcast.xml', cwd=repository)
    if run('git', 'diff', '--cached', '--name-only', cwd=repository):
        run('git', 'commit', '-m', f'Publish signed update feeds for Silique {version}', cwd=repository)
    run('git', 'push', 'origin', 'main', cwd=repository)
    print(f'Published https://github.com/{REPOSITORY}/releases/tag/{tag}')


if __name__ == '__main__':
    main()
