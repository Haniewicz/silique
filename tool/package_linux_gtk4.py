#!/usr/bin/env python3
"""Package a tested production GTK4 bundle, never the isolated probe entrypoint."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--probe-result', type=Path, required=True)
    parser.add_argument('--engine-source', type=Path, required=True)
    parser.add_argument('--fedora-rootfs', type=Path, required=True)
    parser.add_argument('--proot', default='proot')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    app = Path(__file__).resolve().parent.parent
    match = re.search(r'^version: ([0-9.]+)\+([0-9]+)$', (app / 'pubspec.yaml').read_text(), re.M)
    if not match or args.out.exists():
        raise ValueError('Valid version and a new output directory are required.')
    version, build = match.groups()
    result = json.loads(args.probe_result.read_text())
    required = {'native-window', 'native-secret-store', 'editor-save', 'failed-save-keeps-window',
                'sqlite-reopen', 'protected-vault-reopen', 'native-keyboard', 'native-folder-chooser', 'native-file-drop'}
    if result.get('passed') is not True or not required.issubset(result.get('checks', [])):
        raise ValueError('The production GTK4 probe has not passed all required checks.')
    bundle = args.bundle.resolve()
    for component in ['silique', 'lib/libflutter_linux_gtk4.so', 'lib/libapp.so', 'data/icudtl.dat', 'data/flutter_assets/NOTICES.Z']:
        if not (bundle / component).is_file():
            raise ValueError(f'Missing production bundle component: {component}')
    if (bundle / 'lib/libflutter_linux_gtk.so').exists():
        raise ValueError('GTK3 engine found in GTK4 bundle.')
    for path in bundle.rglob('*'):
        if path.is_symlink() and not path.resolve(strict=True).is_relative_to(bundle):
            raise ValueError('Bundle contains a symlink outside its portable directory.')
    dependencies = []
    gtk4_found = False
    for path in bundle.rglob('*'):
        if not path.is_file():
            continue
        with path.open('rb') as stream:
            if stream.read(4) != b'\x7fELF':
                continue
        # Flutter copies plugin targets as files, retaining their build-tree
        # RUNPATH. Relocate every shipped ELF before packaging or auditing it.
        dynamic = subprocess.run(['readelf', '-d', str(path)], check=True, capture_output=True, text=True).stdout
        if re.search(r'\((NEEDED|RPATH|RUNPATH)\)', dynamic):
            relative = os.path.relpath(bundle / 'lib', path.parent)
            rpath = '$ORIGIN' if relative == '.' else f'$ORIGIN:$ORIGIN/{relative}'
            subprocess.run(['patchelf', '--set-rpath', rpath, str(path)], check=True)
        linked = subprocess.run(['ldd', str(path)], check=True, capture_output=True, text=True).stdout
        if 'not found' in linked or re.search(r'lib(?:gtk|gdk)-3', linked):
            raise ValueError(f'Missing dependency or GTK3 linkage: {path.name}')
        gtk4_found |= 'libgtk-4.so' in linked
        dependencies.append({'file': str(path.relative_to(bundle)), 'ldd': linked})
    if not gtk4_found:
        raise ValueError('No actual GTK4 linkage found.')
    args.out.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix='silique-package-') as temporary:
        root = Path(temporary)
        portable = root / 'Silique'
        shutil.copytree(bundle, portable, symlinks=True)
        licenses = portable / 'licenses'
        licenses.mkdir()
        shutil.copy2(args.engine_source / 'LICENSE', licenses / 'Flutter-LICENSE')
        shutil.copy2(args.engine_source / 'bin/cache/artifacts/engine/linux-x64/LICENSE.artifacts.md', licenses / 'Flutter-engine-NOTICES.md')
        shutil.copy2(app / 'linux-gtk4/UPSTREAM_LICENSE', licenses / 'GTK4-runner-LICENSE')
        for license_path in (app / 'linux-gtk4/flutter/ephemeral/gtk4-plugins').glob('*/LICENSE'):
            shutil.copy2(license_path, licenses / f'{license_path.parent.name}-LICENSE')
        (portable / 'README.txt').write_text(
            f'Silique {version} (build {build}) — Linux x64 / GTK4\n\n'
            'Requires Ubuntu 24.04+, Fedora 44, or a compatible system with GTK >= 4.14, '
            'glibc >= 2.39, libsecret-1, libGL, libEGL, libepoxy and an unlocked Secret Service.\n'
            'Start ./silique. Choose the vault directory on first launch.\n'
            'New releases: https://github.com/Haniewicz/silique-releases/releases\n'
            'This build uses a custom GTK4 Flutter engine. GTK4 support is experimental.\n'
            'Application and dependency notices are in data/flutter_assets/NOTICES.Z and licenses/.\n')
        archive = args.out / f'Silique-{version}-Linux-GTK4-x64.tar.gz'
        with tarfile.open(archive, 'w:gz') as output:
            output.add(portable, arcname='Silique')
        deb = root / 'deb'
        target = deb / 'opt/silique'
        shutil.copytree(portable, target, symlinks=True)
        (deb / 'usr/bin').mkdir(parents=True)
        os.symlink('/opt/silique/silique', deb / 'usr/bin/silique')
        desktop = deb / 'usr/share/applications/pl.novanotes.nova_notes.desktop'
        desktop.parent.mkdir(parents=True)
        desktop.write_text('[Desktop Entry]\nType=Application\nName=Silique\nComment=Private Markdown notes\nExec=/opt/silique/silique\nIcon=pl.novanotes.nova_notes\nTerminal=false\nCategories=Office;Utility;\nStartupWMClass=pl.novanotes.nova_notes\n')
        icon = deb / 'usr/share/icons/hicolor/256x256/apps/pl.novanotes.nova_notes.png'
        icon.parent.mkdir(parents=True)
        shutil.copy2(app / 'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png', icon)
        control = deb / 'DEBIAN/control'
        control.parent.mkdir()
        control.write_text(f'Package: silique\nVersion: {version}-{build}\nArchitecture: amd64\n'
                           'Maintainer: Silique\nSection: utils\nPriority: optional\n'
                           'Depends: libgtk-4-1 (>= 4.14), libsecret-1-0, libstdc++6, libc6 (>= 2.39), libgl1, libegl1, libepoxy0, libx11-6\n'
                           'Recommends: dbus-user-session, gnome-keyring\n'
                           'Description: Private encrypted Markdown notes (GTK4)\n'
                           ' Offline vaults and end-to-end encrypted synchronization.\n')
        subprocess.run(['dpkg-deb', '--root-owner-group', '--build', str(deb), str(args.out / f'Silique-{version}-Linux-GTK4-amd64.deb')], check=True)
        rpm_root = root / 'rpmbuild'
        for directory in ['BUILD', 'BUILDROOT', 'RPMS', 'SOURCES', 'SPECS', 'SRPMS']:
            (rpm_root / directory).mkdir(parents=True)
        shutil.copytree(deb / 'opt', rpm_root / 'SOURCES/opt')
        shutil.copytree(deb / 'usr', rpm_root / 'SOURCES/usr', symlinks=True)
        private_names = set()
        for path in (portable / 'lib').rglob('*'):
            if not path.is_file():
                continue
            with path.open('rb') as stream:
                if stream.read(4) != b'\x7fELF':
                    continue
            dynamic = subprocess.run(['readelf', '-d', str(path)], check=True, capture_output=True, text=True).stdout
            soname = re.search(r'\(SONAME\).*\[(.*?)\]', dynamic)
            private_names.add(soname[1] if soname else path.name)
        # RPM must still resolve all system ELF dependencies, while libraries
        # shipped under /opt/silique remain private to this application.
        private_requires = '^(' + '|'.join(name.replace('.', '[.]') for name in sorted(private_names)) + ')'
        spec = rpm_root / 'SPECS/silique.spec'
        spec.write_text(f'''%global debug_package %{{nil}}
%global __provides_exclude_from ^/opt/silique/.*$
%global __requires_exclude {private_requires}
Name: silique
Version: {version}
Release: {build}%{{?dist}}
Summary: Private encrypted Markdown notes (GTK4)
License: LicenseRef-Proprietary AND BSD-3-Clause AND MIT
URL: https://github.com/Haniewicz/silique-releases
BuildArch: x86_64
Requires: gtk4 >= 4.14
Requires: libsecret
Recommends: gnome-keyring

%description
Offline vaults and end-to-end encrypted synchronization.
Uses a custom Flutter GTK4 engine.

%prep

%build

%install
mkdir -p %{{buildroot}}
cp -a %{{_sourcedir}}/opt %{{_sourcedir}}/usr %{{buildroot}}/

%files
/opt/silique
/usr/bin/silique
/usr/share/applications/pl.novanotes.nova_notes.desktop
/usr/share/icons/hicolor/256x256/apps/pl.novanotes.nova_notes.png
''')
        subprocess.run([args.proot, '-0', '-R', str(args.fedora_rootfs.resolve()), '-b', f'{rpm_root}:/work', '-w', '/work',
                        'rpmbuild', '-bb', '--define', '_topdir /work', '--define', 'dist .fc44', '/work/SPECS/silique.spec'], check=True)
        built_rpms = list((rpm_root / 'RPMS/x86_64').glob('silique-*.rpm'))
        if len(built_rpms) != 1:
            raise ValueError('Expected exactly one Fedora RPM.')
        shutil.copy2(built_rpms[0], args.out / f'Silique-{version}-Linux-GTK4-x86_64.rpm')
    files = [{'name': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'size': path.stat().st_size}
             for path in sorted(args.out.iterdir())]
    (args.out / 'SHA256SUMS-Linux.txt').write_text(''.join(f"{item['sha256']}  {item['name']}\n" for item in files))
    (args.out / 'linux-build.json').write_text(json.dumps({'version': version, 'build': int(build), 'gtk': 4,
        'architecture': 'x64', 'probe': result, 'files': files, 'dependencies': dependencies,
        'gtk4PatchSHA256': hashlib.sha256((app / 'tool/gtk4/flutter-3.47.7-gtk4.patch').read_bytes()).hexdigest()}, indent=2) + '\n')
    print('GTK4 packages prepared after native checks and dependency verification.')


if __name__ == '__main__':
    main()
