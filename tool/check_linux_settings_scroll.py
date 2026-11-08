#!/usr/bin/env python3
"""Native mouse-wheel regression against a GTK4 production executable.

Uses a disposable HOME, keyring, DBus session and Xvfb display. Never opens the
owner's vaults or sends input to the real desktop.
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import time


def command(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True,
                          timeout=20, **kwargs).stdout.strip()


def inside(executable, report, root):
    from PIL import Image, ImageChops
    for name in ['data', 'config', 'cache', 'runtime', 'vaults']:
        (root / name).mkdir(mode=0o700, parents=True, exist_ok=True)
    support = root / 'data/pl.novanotes.nova_notes'
    support.mkdir(parents=True, exist_ok=True)
    # Explicit fixture location; production first-run behavior is not changed.
    (support / 'silique-location.txt').write_text(str(root / 'vaults'))
    command('gnome-keyring-daemon', '--unlock', '--components=secrets',
            input=secrets.token_hex(32) + '\n')
    wm = subprocess.Popen(['openbox'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    app = None
    try:
        with report.with_suffix('.log').open('w') as log:
            app = subprocess.Popen([str(executable)], stdout=log, stderr=log)
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if app.poll() is not None:
                    raise RuntimeError(f'Application exited: {app.returncode}')
                found = subprocess.run(['xdotool', 'search', '--onlyvisible', '--name', '^Silique$'], capture_output=True, text=True)
                if found.returncode == 0:
                    break
                time.sleep(.1)
            else:
                raise TimeoutError('No Silique window')
            window = found.stdout.splitlines()[-1]
            command('xdotool', 'windowactivate', '--sync', window)
            time.sleep(1)
            # Known production welcome screen on a fixed 1280x900 test display.
            command('xdotool', 'mousemove', '--sync', '639', '617', 'click', '1')
            time.sleep(.7)
            before = report.with_name(report.stem + '-before.png')
            after = report.with_name(report.stem + '-after.png')
            command('scrot', str(before))
            command('xdotool', 'mousemove', '--sync', '846', '673', 'click', '--repeat', '15', '--delay', '80', '5')
            time.sleep(.5)
            command('scrot', str(after))
            # Ignore cursor, frame and modal header; actual content must move.
            a = Image.open(before).convert('RGB').crop((350, 240, 925, 780))
            b = Image.open(after).convert('RGB').crop((350, 240, 925, 780))
            diff = ImageChops.difference(a, b)
            pixels = diff.tobytes()
            changed = sum(max(pixels[i:i + 3]) > 20 for i in range(0, len(pixels), 3))
            passed = changed > 1000
            result = {'passed': passed, 'checks': ['native-production-settings-wheel'],
                      'changedPixels': changed, 'before': str(before), 'after': str(after)}
            report.write_text(json.dumps(result, indent=2) + '\n')
            print(json.dumps(result), flush=True)
            return 0 if passed else 1
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--inside', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    executable, report = args.executable.resolve(), args.report.resolve()
    if args.inside:
        return inside(executable, report, args.inside)
    if report.exists():
        raise ValueError('Choose a new report path')
    report.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='silique-settings-native-') as temporary:
        root = Path(temporary)
        (root / 'runtime').mkdir(mode=0o700)
        env = os.environ | {'HOME': str(root), 'XDG_DATA_HOME': str(root / 'data'),
                            'XDG_CONFIG_HOME': str(root / 'config'),
                            'XDG_CACHE_HOME': str(root / 'cache'),
                            'XDG_RUNTIME_DIR': str(root / 'runtime'), 'GDK_BACKEND': 'x11',
                            'GTK_A11Y': 'none', 'GSK_RENDERER': 'cairo',
                            'LIBGL_ALWAYS_SOFTWARE': 'true'}
        return subprocess.run(['xvfb-run', '-a', '-s', '-screen 0 1280x900x24',
                               'dbus-run-session', '--', sys.executable, __file__,
                               '--executable', str(executable), '--report', str(report),
                               '--inside', str(root)], env=env, timeout=90).returncode


if __name__ == '__main__':
    sys.exit(main())
