#!/usr/bin/env python3
"""Disposable-runner smoke: pinned Sparkle really unarchives this DMG.

Sparkle 2.10.0 generate_appcast/Unarchive.swift uses SUUnarchiver and waits
for disk-image cleanup. A cold content-hash cache proves extraction happened,
not a stale metadata read. This never launches/installs Silique or publishes
its throwaway appcast; diagnostics belong in the existing encrypted CI log.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import sys
import tempfile
import xml.etree.ElementTree as XML

from macos_dmg import run, validate_app
from prepare_update import SPARKLE_NS


def smoke(image, version, build, generator, key, cache):
    image, cache = Path(image), Path(cache)
    digest = hashlib.sha256(image.read_bytes()).hexdigest()
    extracted = cache / digest
    partial = cache / (digest + '.tmp')
    if extracted.exists() or partial.exists() or extracted.is_symlink() or partial.is_symlink():
        raise ValueError('Sparkle smoke requires a cold cache; preserve preexisting entries.')
    try:
        with tempfile.TemporaryDirectory(prefix='silique-sparkle-dmg-') as folder:
            root = Path(folder)
            shutil.copy2(image, root / image.name)
            feed = root / 'appcast.xml'
            run(str(generator), '--ed-key-file', str(key), '--maximum-deltas', '0',
                '-o', str(feed), str(root))
            items = XML.parse(feed).findall('./channel/item')
            enclosure = items[0].find('enclosure') if len(items) == 1 else None
            # Sparkle 2.10 emits version fields as item children, not the
            # legacy enclosure attributes used by our manually signed feed.
            generated_build = items[0].findtext(f'{{{SPARKLE_NS}}}version') if len(items) == 1 else None
            generated_version = items[0].findtext(f'{{{SPARKLE_NS}}}shortVersionString') if len(items) == 1 else None
            if (enclosure is None or not enclosure.get('url', '').endswith(image.name)
                    or generated_build != str(build)
                    or generated_version != version
                    or not enclosure.get(f'{{{SPARKLE_NS}}}edSignature')):
                raise ValueError('Sparkle did not extract the intended DMG version/build.')
            validate_app(extracted / 'Silique.app', version, build)
    finally:
        # Only these initially absent, content-addressed smoke outputs are ours.
        for path in (extracted, partial):
            if path.is_symlink():
                path.unlink()
            elif path.exists():
                shutil.rmtree(path)
    print(f'Native Sparkle 2.10.0 DMG extraction verified: {version}+{build}; root signature and x86_64+arm64 checked.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', type=int, required=True)
    args = parser.parse_args()
    if (sys.platform != 'darwin' or os.environ.get('GITHUB_ACTIONS') != 'true'
            or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted'):
        parser.error('Run only on a disposable GitHub-hosted macOS runner.')
    tools = Path.home() / '.local/share/silique-toolchains/sparkle-2.10.0'
    key = Path.home() / '.local/share/silique-signing/updater-ed25519.key'
    cache = Path.home() / 'Library/Caches/Sparkle_generate_appcast'
    smoke(args.image, args.version, args.build, tools / 'bin/generate_appcast', key, cache)


if __name__ == '__main__':
    main()
