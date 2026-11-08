#!/usr/bin/env python3
"""Check the installed production entrypoint in an isolated Xvfb/DBus session."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--fedora-rootfs', type=Path)
    parser.add_argument('--proot', default='proot')
    args = parser.parse_args()
    if args.report.exists():
        raise ValueError('Choose a new report file.')
    command = ['/usr/bin/silique']
    distro = 'Ubuntu 24.04'
    if args.fedora_rootfs:
        command = [args.proot, '-R', str(args.fedora_rootfs.resolve()), '-w', '/tmp', *command]
        distro = 'Fedora 44'
    with tempfile.TemporaryDirectory(prefix='silique-installed-test-') as temporary:
        environment = os.environ | {'XDG_DATA_HOME': temporary, 'GDK_BACKEND': 'x11',
                                   'LIBGL_ALWAYS_SOFTWARE': 'true', 'GSK_RENDERER': 'cairo'}
        wm = subprocess.Popen(['openbox'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        app = None
        try:
            with args.report.with_suffix('.log').open('w') as output:
                app = subprocess.Popen(command, env=environment, stdout=output, stderr=output)
                deadline = time.monotonic() + 40
                window = None
                while time.monotonic() < deadline:
                    if app.poll() is not None:
                        raise RuntimeError('Installed app exited before opening a window.')
                    found = subprocess.run(['xdotool', 'search', '--onlyvisible', '--name', '^Silique$'], capture_output=True, text=True)
                    if found.returncode == 0:
                        window = found.stdout.splitlines()[-1]
                        break
                    time.sleep(.2)
                if window is None:
                    raise TimeoutError('Installed app did not display a window.')
                time.sleep(3)
                if app.poll() is not None:
                    raise RuntimeError('Installed app exited after displaying its window.')
                subprocess.run(['scrot', str(args.report.with_suffix('.png'))], check=True)
                if any(Path(temporary).rglob('silique.sqlite')):
                    raise RuntimeError('First run created a vault without choosing its location.')
                subprocess.run(['xdotool', 'windowactivate', '--sync', window], check=True)
                subprocess.run(['xdotool', 'key', '--clearmodifiers', 'alt+F4'], check=True)
                code = app.wait(timeout=15)
                if code != 0:
                    raise RuntimeError(f'Installed application closed with exit code {code}.')
                args.report.write_text(json.dumps({'passed': True, 'distro': distro,
                    'checks': ['installed-production-window', 'first-run-no-vault', 'graceful-close'], 'exitCode': code}, indent=2) + '\n')
                print(f'{distro}: installed production window, first-run location gate and graceful close passed.')
        finally:
            if app is not None and app.poll() is None:
                app.terminate()
                try:
                    app.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    app.kill()
                    app.wait()
            wm.terminate()
            wm.wait(timeout=10)


if __name__ == '__main__':
    main()
