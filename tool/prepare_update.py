#!/usr/bin/env python3
"""Prepare only signed, public distribution files. Never copy a source tree.

Publishing remains a separate, explicit operation after owner acceptance.
The Ed25519 private key stays in the owner's signing directory (outside Git).
"""
import argparse
import base64
import datetime
import email.utils
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as XML
from macos_dmg import verify_dmg

REPOSITORY = 'Haniewicz/silique-releases'
ASSET_SUFFIXES = {
    'macos-dmg': '-macOS.dmg',
    'android': '.apk',
    'windows': '-Setup-Windows-x64.exe',
    'windows-portable': '-Windows-x64.zip',
    'linux': '-Linux-GTK4-x64.tar.gz',
    'linux-deb': '-Linux-GTK4-amd64.deb',
    'linux-rpm': '-Linux-GTK4-x86_64.rpm',
}
PUBLIC_KEY = 'gISI1x7vljf/QRt50r3fmP4D8v8LwCJIkAFO2qUaCpc='
SPARKLE_NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
XML.register_namespace('sparkle', SPARKLE_NS)


def safe_notes(text):
    if len(text) > 20000 or re.search(
        r'/Users/|/tmp/|Bearer\s|github_pat_|gh[pousr]_[A-Za-z0-9]+|'
        r'\b(?:192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d+\.\d+)\b', text):
        raise ValueError('Release notes contain local/private details; write public product notes.')
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', type=int, required=True)
    parser.add_argument('--macos', '--macos-dmg', dest='macos_dmg', type=Path, required=True)
    parser.add_argument('--android', type=Path, required=True)
    parser.add_argument('--windows', type=Path)
    parser.add_argument('--windows-portable', type=Path)
    parser.add_argument('--linux', type=Path)
    parser.add_argument('--linux-deb', type=Path)
    parser.add_argument('--linux-rpm', type=Path)
    parser.add_argument('--notes', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'\d{1,4}\.\d{1,4}\.\d{1,4}', args.version) or args.build < 1:
        raise ValueError('Invalid version/build.')
    if args.out.exists():
        raise ValueError('Use a new output directory; never overwrite a prepared release.')
    for first, second in [('windows', 'windows_portable'), ('linux', 'linux_deb')]:
        if bool(getattr(args, first)) != bool(getattr(args, second)):
            raise ValueError('Supply both desktop installer and portable archive.')
    if bool(args.linux) != bool(args.linux_rpm):
        raise ValueError('Supply both DEB and Fedora RPM with the Linux archive.')
    notes = safe_notes(args.notes.read_text())
    # Native mount/identity/signature/universal verification, never ZIP parsing.
    verify_dmg(args.macos_dmg, args.version, args.build)
    tools = Path.home() / '.local/share/silique-toolchains'
    env = os.environ.copy()
    env['JAVA_HOME'] = str(tools / 'jdk17/Contents/Home')
    build_tools = sorted((tools / 'android-sdk/build-tools').glob('*/aapt2'))[-1].parent
    metadata = subprocess.run([str(build_tools / 'aapt2'), 'dump', 'badging', str(args.android)], capture_output=True, text=True, check=True).stdout.splitlines()[0]
    if f"versionName='{args.version}'" not in metadata or f"versionCode='{args.build}'" not in metadata or "name='pl.novanotes.nova_notes'" not in metadata:
        raise ValueError('Android identity/version differs from release metadata.')
    signature_check = subprocess.run([str(build_tools / 'apksigner'), 'verify', '--print-certs', str(args.android)], env=env, check=True, capture_output=True, text=True)
    if '2021902e8c43d5c10059c9f0458ed8c1ac94fce86a488f7b46d0b0eb3467996e' not in signature_check.stdout:
        raise ValueError('APK does not use the Silique release certificate.')
    signer = tools / 'sparkle-2.10.0/bin/sign_update'
    key = Path.home() / '.local/share/silique-signing/updater-ed25519.key'
    if key.stat().st_mode & 0o077:
        raise ValueError('Updater signing key must be readable only by its owner.')

    def sign(path):
        result = subprocess.run([str(signer), '--ed-key-file', str(key), '-p', str(path)], check=True, text=True, capture_output=True)
        return result.stdout.strip()

    args.out.mkdir(parents=True)
    platforms = {}
    checksums = []
    for platform, suffix in ASSET_SUFFIXES.items():
        source = getattr(args, platform.replace('-', '_'))
        if source is None:
            continue
        name = f'Silique-{args.version}{suffix}'
        target = args.out / name
        shutil.copy2(source, target)
        digest = hashlib.sha256(target.read_bytes()).hexdigest()
        platforms[platform] = {'url': f'https://github.com/{REPOSITORY}/releases/download/v{args.version}/{name}', 'sha256': digest, 'size': target.stat().st_size}
        checksums.append(f'{digest}  {name}\n')
    payload = json.dumps({'schema': 1, 'version': args.version, 'build': args.build, 'notes': notes, 'platforms': platforms}, separators=(',', ':'), ensure_ascii=False).encode()
    with tempfile.TemporaryDirectory(prefix='silique-sign-') as temp:
        data = Path(temp) / 'payload.bin'
        data.write_bytes(payload)
        signature = sign(data)
    (args.out / 'latest.json').write_text(json.dumps({'payload': base64.b64encode(payload).decode(), 'signature': signature}, indent=2) + '\n')
    (args.out / 'SHA256SUMS.txt').write_text(''.join(checksums))
    (args.out / 'release-notes.txt').write_text(notes)

    rss = XML.Element('rss', version='2.0')
    channel = XML.SubElement(rss, 'channel')
    XML.SubElement(channel, 'title').text = 'Silique'
    XML.SubElement(channel, 'link').text = f'https://github.com/{REPOSITORY}/releases'
    item = XML.SubElement(channel, 'item')
    XML.SubElement(item, 'title').text = f'Silique {args.version}'
    XML.SubElement(item, 'pubDate').text = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))
    XML.SubElement(item, 'description').text = notes
    XML.SubElement(item, f'{{{SPARKLE_NS}}}minimumSystemVersion').text = '12.0'
    archive = args.out / f'Silique-{args.version}-macOS.dmg'
    XML.SubElement(item, 'enclosure', {
        'url': platforms['macos-dmg']['url'],
        f'{{{SPARKLE_NS}}}version': str(args.build),
        f'{{{SPARKLE_NS}}}shortVersionString': args.version,
        f'{{{SPARKLE_NS}}}edSignature': sign(archive),
        'length': str(platforms['macos-dmg']['size']), 'type': 'application/octet-stream',
    })
    feed = args.out / 'appcast.xml'
    XML.ElementTree(rss).write(feed, encoding='utf-8', xml_declaration=True)
    sign(feed)
    subprocess.run([str(signer), '--ed-key-file', str(key), '--verify', str(feed)], check=True, capture_output=True)
    dart = tools / 'flutter/bin/dart'
    app = Path(__file__).resolve().parent.parent
    subprocess.run([str(dart), 'run', str(app / 'tool/check_update_feed.dart'), str((args.out / 'latest.json').resolve())], cwd=app, check=True, capture_output=True)
    print(f'Prepared signed release {args.version}, build {args.build}: {args.out}')
    print('Only copy latest.json and appcast.xml to the public repository AFTER release assets have been published.')


if __name__ == '__main__':
    main()
