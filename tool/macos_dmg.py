#!/usr/bin/env python3
"""Build/inspect installer-only DMGs without opening apps or changing trust."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

BUNDLE_ID = 'pl.novanotes.novaNotes'
# Leaf certificate of the macOS publisher (self-signed, CN=Silique). Rotated
# from the historical local-preview identity on 2026-11-10 by owner decision;
# the Android keystore is intentionally unchanged, so the two platform
# identities are now asymmetric (see docs/migration-signing-identity.md). The
# bytes below are PLACEHOLDER-0000000000000000000000000000000000: run
# tool/make_signing_identity.sh, paste its printed SHA-256 here, and the SHA-1
# into tool/sign_macos.py. Pin bytes, never a non-unique display name.
PUBLISHER_CERTIFICATE_SHA256 = 'bf965f8369bbd9d8688ea31a3e87200f8752485a57e09f2d5599eb76947074a8'


def run(*args, stderr=False):
    try:
        result = subprocess.run(args, check=True, capture_output=True)
    except subprocess.CalledProcessError as error:
        # These tools never receive secrets. Keep actionable stderr in the
        # encrypted CI diagnostics instead of only the generic exit status.
        detail = (error.stderr or error.stdout or b'').decode('utf-8', errors='replace')
        raise RuntimeError(f'{Path(args[0]).name} failed: {detail.strip()}') from error
    return result.stderr if stderr else result.stdout


def validate_app(app, version, build):
    app = Path(app)
    contents = app / 'Contents'
    plist = contents / 'Info.plist'
    if (app.is_symlink() or not app.is_dir() or contents.is_symlink()
            or plist.is_symlink() or not plist.is_file()):
        raise ValueError('Expected exact root Silique.app/Contents/Info.plist, without aliases.')
    info = plistlib.loads(plist.read_bytes())
    if (info.get('CFBundleIdentifier') != BUNDLE_ID
            or info.get('CFBundleShortVersionString') != version
            or str(info.get('CFBundleVersion')) != str(build)
            or info.get('CFBundlePackageType') != 'APPL'):
        raise ValueError('macOS root bundle identity/version/build differs.')
    name = info.get('CFBundleExecutable', '')
    if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', name):
        raise ValueError('Invalid root bundle executable.')
    executable = contents / 'MacOS' / name
    if executable.parent.is_symlink() or executable.is_symlink() or not executable.is_file():
        raise ValueError('Root executable must not be an alias.')
    # lipo treats every token after -verify_arch as an architecture, so the
    # input must precede the option (Apple cctools misc/lipo.c).
    run('/usr/bin/lipo', str(executable), '-verify_arch', 'x86_64', 'arm64')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
    with tempfile.TemporaryDirectory(prefix='silique-macos-certificate-') as folder:
        prefix = str(Path(folder) / 'publisher-')
        # The prefix is an optional long-option argument; codesign only
        # associates it with this option when joined by '='.
        run('/usr/bin/codesign', '-d', '--extract-certificates=' + prefix, str(app))
        certificate = Path(prefix + '0')
        if (certificate.is_symlink() or not certificate.is_file()
                or hashlib.sha256(certificate.read_bytes()).hexdigest() != PUBLISHER_CERTIFICATE_SHA256):
            raise ValueError('macOS publisher certificate differs from the existing identity.')


def validate_layout(root):
    """One root app, one Applications link; framework symlinks stay internal."""
    root = Path(root)
    allowed = {'Silique.app', 'Applications', 'README.txt', '.DS_Store',
               '.Trashes', '.fseventsd', '.Spotlight-V100', '.metadata_never_index'}
    if not {'Silique.app', 'Applications'}.issubset({p.name for p in root.iterdir()}):
        raise ValueError('DMG must contain Silique.app and Applications.')
    if any(p.name not in allowed for p in root.iterdir()):
        raise ValueError('Unexpected DMG root entry (extra bundle or alias).')
    app = root / 'Silique.app'
    if app.is_symlink() or not app.is_dir():
        raise ValueError('Root app must be a real directory, not an alias.')
    applications = root / 'Applications'
    if not applications.is_symlink() or os.readlink(applications) != '/Applications':
        raise ValueError('Applications must link exactly to /Applications.')
    for parent, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(parent) / name
            if path == applications:
                continue
            if path.is_symlink():
                try:
                    target = path.resolve(strict=True)
                except (OSError, RuntimeError) as error:
                    raise ValueError('Broken or cyclic bundle symlink.') from error
                if not path.is_relative_to(app) or not target.is_relative_to(app.resolve()):
                    raise ValueError('Alias/symlink escapes the root app.')
            if path.suffix.lower() == '.app':
                # Sparkle's signed helper is part of the existing framework,
                # not a second installable application. Never search arbitrary
                # nested bundles for metadata or let them hide a second app.
                framework = app / 'Contents/Frameworks/Sparkle.framework'
                helper = framework / 'Versions/B/Updater.app'
                framework_link = framework / 'Updater.app'
                if path == framework_link:
                    if not path.is_symlink() or path.resolve() != helper.resolve():
                        raise ValueError('Unexpected Sparkle helper alias.')
                elif path not in (app, helper):
                    raise ValueError('Extra app bundle in disk image.')


def verify_dmg(image, version, build):
    image = Path(image)
    if image.is_symlink() or not image.is_file() or image.suffix != '.dmg':
        raise ValueError('Expected a real .dmg installer.')
    image = image.resolve()
    run('/usr/bin/hdiutil', 'verify', str(image))
    metadata = plistlib.loads(run('/usr/bin/hdiutil', 'imageinfo', '-plist', str(image)))
    if metadata.get('Format') != 'UDZO':
        raise ValueError('Expected a compressed read-only UDZO image.')
    # Do not recursively remove a potentially still-mounted image after a detach
    # failure. A unique, canonical mount directory never aliases /Volumes names.
    mount = Path(tempfile.mkdtemp(prefix='silique-dmg-mount-')).resolve()
    attached = False
    try:
        data = run('/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen',
                   '-mountpoint', str(mount), '-plist', str(image))
        attached = True
        entities = plistlib.loads(data).get('system-entities', [])
        mounts = [entry['mount-point'] for entry in entities if 'mount-point' in entry]
        if mounts != [str(mount)]:
            raise ValueError('Unexpected DMG mount layout.')
        validate_layout(mount)
        if not os.statvfs(mount).f_flag & os.ST_RDONLY:
            raise ValueError('DMG was not mounted read-only.')
        validate_app(mount / 'Silique.app', version, build)
    finally:
        if attached:
            run('/usr/bin/hdiutil', 'detach', str(mount))
        mount.rmdir()


def build_dmg(app, image, version, build, *, replace=False):
    app, image = Path(app), Path(image)
    if (image.exists() and not replace) or image.is_symlink() or image.suffix != '.dmg':
        raise ValueError('Use a new .dmg output; do not overwrite a candidate.')
    validate_app(app, version, build)
    image.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.silique-dmg-', dir=image.parent) as folder:
        temporary = Path(folder)
        stage = temporary / 'contents'
        stage.mkdir()
        run('/usr/bin/ditto', str(app), str(stage / 'Silique.app'))
        (stage / 'Applications').symlink_to('/Applications')
        (stage / 'README.txt').write_text(
            'Quit Silique, then drag Silique.app to Applications and choose Replace.\n'
            'Open /Applications/Silique.app, not the copy on this disk image.\n'
            'Your notes, preferences and keys are preserved. Eject this image afterwards.\n'
            'Existing preview signature is not Developer ID notarization. If macOS blocks\n'
            'a trusted download, review Privacy & Security > Open Anyway for this app.\n')
        validate_layout(stage)
        candidate = temporary / 'Silique-macOS.dmg'
        run('/usr/bin/hdiutil', 'create', '-volname', f'Silique {version}',
            '-fs', 'HFS+', '-format', 'UDZO', '-srcfolder', str(stage), str(candidate))
        verify_dmg(candidate, version, build)
        candidate.replace(image)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('build', 'verify'))
    parser.add_argument('--app', type=Path)
    parser.add_argument('--image', type=Path, required=True)
    parser.add_argument('--replace', action='store_true', help='Atomically replace a local candidate only after successful verification')
    parser.add_argument('--version')
    parser.add_argument('--build', type=int)
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('Native hdiutil/codesign verification requires macOS.')
    if args.version is None or args.build is None:
        pubspec = Path(__file__).resolve().parent.parent / 'pubspec.yaml'
        version, build = re.search(r'^version: ([0-9.]+)\+([0-9]+)$', pubspec.read_text(), re.M).groups()
        args.version = args.version or version
        args.build = args.build if args.build is not None else int(build)
    if args.operation == 'build':
        if args.app is None:
            parser.error('--app is required for build')
        build_dmg(args.app, args.image, args.version, args.build, replace=args.replace)
    else:
        verify_dmg(args.image, args.version, args.build)
    print(f'Native DMG {args.operation} verified: {args.version}+{args.build}')


if __name__ == '__main__':
    main()
