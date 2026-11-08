#!/usr/bin/env python3
"""Run only on the disposable builder, inside dbus-run-session + xvfb-run."""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    parser.add_argument('result', type=Path)
    parser.add_argument('--fedora-rootfs', type=Path)
    parser.add_argument('--proot', default='proot')
    parser.add_argument('--wayland', action='store_true')
    args = parser.parse_args()
    display = 'WAYLAND_DISPLAY' if args.wayland else 'DISPLAY'
    if not os.environ.get('DBUS_SESSION_BUS_ADDRESS') or not os.environ.get(display):
        raise ValueError('Use an isolated DBus session with the selected display backend.')
    if args.result.exists():
        raise ValueError('Use a new result path.')
    # Persist only this disposable builder's keyring password, outside sources,
    # so repeated probes can unlock their existing test-only login collection.
    password_file = Path.home() / '.local/share/silique-test-only/keyring-password'
    password_file.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    try:
        descriptor = os.open(password_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as stream:
            stream.write(secrets.token_hex(32))
    except FileExistsError:
        pass
    if password_file.stat().st_mode & 0o077:
        raise ValueError('Test keyring password must be private to the builder.')
    subprocess.run(['gnome-keyring-daemon', '--unlock', '--components=secrets'],
                   input=password_file.read_text() + '\n', text=True,
                   capture_output=True, check=True, timeout=20)
    window_manager = None if args.wayland else subprocess.Popen(['openbox'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    environment = os.environ | {'GDK_BACKEND': 'wayland' if args.wayland else 'x11', 'LIBGL_ALWAYS_SOFTWARE': 'true', 'GSK_RENDERER': 'cairo'}
    phase_path = Path(str(args.result) + '.phase')
    log = args.result.with_suffix('.log')
    command = [str(args.executable.resolve())]
    if args.fedora_rootfs:
        command = [args.proot, '-R', str(args.fedora_rootfs.resolve()), '-w', '/tmp', *command]
    try:
        with log.open('w') as output:
            app = subprocess.Popen(command, env=environment, stdout=output, stderr=output)
            try:
                deadline = time.monotonic() + 180
                last_phase = None
                while app.poll() is None and time.monotonic() < deadline:
                    if phase_path.exists():
                        try:
                            state = json.loads(phase_path.read_text())
                            phase = state['phase']
                        except (json.JSONDecodeError, KeyError):
                            time.sleep(.1)
                            continue
                        if phase != last_phase:
                            time.sleep(.7)
                            if phase == 'click-title':
                                window = run('xdotool', 'search', '--onlyvisible', '--name', '^Silique$').splitlines()[-1]
                                geometry = dict(line.split('=', 1) for line in run('xdotool', 'getwindowgeometry', '--shell', window).splitlines())
                                run('xdotool', 'windowactivate', '--sync', window)
                                run('xdotool', 'mousemove', '--sync', str(int(geometry['X']) + round(state['x'])), str(int(geometry['Y']) + round(state['y'])))
                                run('xdotool', 'click', '1')
                            elif phase == 'keyboard':
                                window = run('xdotool', 'search', '--onlyvisible', '--name', '^Silique$').splitlines()[-1]
                                run('xdotool', 'windowactivate', '--sync', window)
                                run('xdotool', 'key', '--clearmodifiers', 'ctrl+a')
                                run('xdotool', 'type', '--clearmodifiers', '--delay', '40', 'GTK4 keyboard test')
                            elif phase == 'choose-folder':
                                # The actual GTK4 dialog opens in the supplied temporary folder.
                                run('xdotool', 'key', '--clearmodifiers', 'alt+s')
                            elif phase == 'cancel-folder':
                                run('xdotool', 'key', '--clearmodifiers', 'Escape')
                            elif phase == 'drop-image':
                                helper = subprocess.Popen([sys.executable, str(Path(__file__).parent / 'gtk4/drag_probe.py'), state['path']], env=environment, stdout=output, stderr=output)
                                try:
                                    time.sleep(1)
                                    source = run('xdotool', 'search', '--onlyvisible', '--name', '^Silique GTK4 drag source$').splitlines()[-1]
                                    run('xdotool', 'windowmove', source, '20', '20')
                                    run('xdotool', 'windowactivate', '--sync', source)
                                    main_window = run('xdotool', 'search', '--onlyvisible', '--name', '^Silique$').splitlines()[-1]
                                    geometry = dict(line.split('=', 1) for line in run('xdotool', 'getwindowgeometry', '--shell', main_window).splitlines())
                                    x = int(geometry['X']) + round(state['x'] * state['scale'])
                                    y = int(geometry['Y']) + round(state['y'] * state['scale'])
                                    run('xdotool', 'mousemove', '--sync', '120', '85')
                                    run('xdotool', 'mousedown', '1')
                                    time.sleep(.2)
                                    for step in range(1, 11):
                                        run('xdotool', 'mousemove', '--sync', str(round(120 + (x - 120) * step / 10)), str(round(85 + (y - 85) * step / 10)))
                                        time.sleep(.08)
                                    time.sleep(.5)
                                    run('xdotool', 'mouseup', '1')
                                    time.sleep(.5)
                                finally:
                                    helper.terminate()
                                    helper.wait(timeout=10)
                            last_phase = phase
                    time.sleep(.1)
                if app.poll() is None:
                    raise TimeoutError('GTK4 production probe did not finish within 180 seconds.')
                if not args.result.exists():
                    raise RuntimeError(f'Probe exited without a result (code {app.returncode}); inspect its private log.')
                result = json.loads(args.result.read_text())
                if app.returncode != 0 or result.get('passed') is not True:
                    raise RuntimeError(f'GTK4 production probe failed; inspect {args.result}.')
                print('GTK4 production probe passed: ' + ', '.join(result['checks']))
            finally:
                if app.poll() is None:
                    app.terminate()
                    try:
                        app.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        app.kill()
                        app.wait()
    finally:
        if window_manager is not None:
            window_manager.terminate()
            window_manager.wait(timeout=10)


if __name__ == '__main__':
    main()
