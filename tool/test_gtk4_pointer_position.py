#!/usr/bin/env python3
"""Native GTK4 pointer-position regression (run on the disposable GTK4 builder).

Compiles a real GTK4 window (header bar + content + tiny target), lets it resize
itself, asks the driver to click the target's laid-out centre and asserts that
the position Flutter receives equals that centre. A wrong content-offset sign or
a stale offset after a resize fails here; the previous fixture set the offset by
hand and could not catch either.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent


def extract_header():
    lines = (ROOT / 'gtk4/flutter-3.47.7-gtk4.patch').read_text().splitlines()
    collecting = False
    result = []
    for line in lines:
        if line.startswith('diff --git '):
            if collecting:
                break
            collecting = line.endswith(
                ' b/engine/src/flutter/shell/platform/linux/fl_gtk.h')
            continue
        if collecting and line.startswith('+') and not line.startswith('+++'):
            result.append(line[1:])
    if not result:
        raise ValueError('No GTK4 compatibility header in the engine patch')
    return '\n'.join(result) + '\n'


def find_window(name_regex, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        found = subprocess.run(
            ['xdotool', 'search', '--onlyvisible', '--name', name_regex],
            capture_output=True, text=True)
        if found.returncode == 0 and found.stdout.split():
            return found.stdout.splitlines()[-1]
        time.sleep(0.2)
    raise TimeoutError('pointer regression window did not appear')


def geometry(window):
    pairs = dict(
        line.split('=', 1) for line in subprocess.run(
            ['xdotool', 'getwindowgeometry', '--shell', window],
            capture_output=True, text=True, check=True).stdout.splitlines())
    return int(pairs['X']), int(pairs['Y'])


def exercise(binary, report, request):
    environment = os.environ | {
        'GDK_BACKEND': 'x11', 'GTK_A11Y': 'none', 'GSK_RENDERER': 'cairo'}
    app = subprocess.Popen([str(binary), str(report), str(request)],
                           env=environment)
    try:
        window = find_window('^Silique pointer position regression$')
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and app.poll() is None:
            if request.exists():
                click = json.loads(request.read_text())
                origin_x, origin_y = geometry(window)
                subprocess.run(['xdotool', 'mousemove', '--sync',
                                str(origin_x + round(click['x'])),
                                str(origin_y + round(click['y']))],
                               check=True, timeout=10)
                subprocess.run(['xdotool', 'click', '1'], check=True, timeout=10)
                break
            time.sleep(0.1)
        return app.wait(timeout=25)
    finally:
        if app.poll() is None:
            app.terminate()
            app.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--request', type=Path)
    parser.add_argument('--binary', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    report = args.report.resolve()
    request = (args.request or report.with_suffix('.click.json')).resolve()
    if report.exists():
        raise ValueError('Choose a new report path')
    report.parent.mkdir(parents=True, exist_ok=True)
    if args.binary:
        return exercise(args.binary, report, request)
    with tempfile.TemporaryDirectory(prefix='silique-pointer-position-') as tmp:
        directory = Path(tmp)
        (directory / 'fl_gtk.h').write_text(extract_header())
        binary = directory / 'pointer-position-probe'
        flags = shlex.split(subprocess.check_output(
            ['pkg-config', '--cflags', '--libs', 'gtk4'], text=True))
        subprocess.run(
            ['g++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
             '-DFLUTTER_LINUX_GTK4=1', '-I' + str(directory),
             str(ROOT / 'gtk4/pointer_position_probe.cc'), '-o', str(binary),
             *flags], check=True, timeout=120)
        inner = (f'openbox >/dev/null 2>&1 & sleep 1; '
                 f'{shlex.quote(sys.executable)} '
                 f'{shlex.quote(str(Path(__file__).resolve()))} '
                 f'--report {shlex.quote(str(report))} '
                 f'--request {shlex.quote(str(request))} '
                 f'--binary {shlex.quote(str(binary))}')
        code = subprocess.run(
            ['xvfb-run', '-a', '-s', '-screen 0 1600x1000x24',
             'bash', '-c', inner], timeout=120).returncode
        if code != 0:
            return code
        result = json.loads(report.read_text())
        if not result.get('passed'):
            print(json.dumps(result))
            return 1
        print(json.dumps(result))
        return 0


if __name__ == '__main__':
    sys.exit(main())
