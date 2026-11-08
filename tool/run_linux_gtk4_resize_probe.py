#!/usr/bin/env python3
"""Run on the disposable builder: launches Silique under xvfb+openbox and tests window resize via xdotool."""
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout.strip()


def find_window(name_regex='^Silique$', timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = run('xdotool', 'search', '--onlyvisible', '--name', name_regex)
            lines = result.splitlines()
            if lines:
                return lines[-1]
        except subprocess.CalledProcessError:
            pass
        time.sleep(0.5)
    raise TimeoutError(f'Window matching "{name_regex}" not found within {timeout}s')


def get_geometry(window_id):
    pairs = dict(line.split('=', 1) for line in run('xdotool', 'getwindowgeometry', '--shell', window_id).splitlines())
    return int(pairs['WIDTH']), int(pairs['HEIGHT']), int(pairs['X']), int(pairs['Y'])


def resize_and_verify(window_id, target_w, target_h, label, tolerance=4):
    run('xdotool', 'windowactivate', '--sync', window_id)
    run('xdotool', 'windowsize', window_id, str(target_w), str(target_h))
    time.sleep(0.5)  # Let WM process the resize
    # Force a sync by activating again
    run('xdotool', 'windowactivate', '--sync', window_id)
    time.sleep(0.3)
    w, h, x, y = get_geometry(window_id)
    w_ok = abs(w - target_w) <= tolerance
    h_ok = abs(h - target_h) <= tolerance
    ok = w_ok and h_ok
    return {'label': label, 'target': f'{target_w}x{target_h}', 'actual': f'{w}x{h}',
            'x': x, 'y': y, 'width_ok': w_ok, 'height_ok': h_ok, 'passed': ok}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    parser.add_argument('result', type=Path)
    parser.add_argument('--wayland', action='store_true')
    args = parser.parse_args()

    display = 'WAYLAND_DISPLAY' if args.wayland else 'DISPLAY'
    if not os.environ.get('DBUS_SESSION_BUS_ADDRESS') or not os.environ.get(display):
        raise ValueError('Use an isolated DBus session with the selected display backend.')

    if args.result.exists():
        raise ValueError('Use a new result path.')

    results = []
    window_manager = None if args.wayland else subprocess.Popen(
        ['openbox'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    environment = os.environ | {
        'GDK_BACKEND': 'wayland' if args.wayland else 'x11',
        'LIBGL_ALWAYS_SOFTWARE': 'true',
        'GSK_RENDERER': 'cairo',
        'GTK_A11Y': 'none',
    }

    log = args.result.with_suffix('.log')
    try:
        with log.open('w') as output:
            app = subprocess.Popen([str(args.executable.resolve())], env=environment,
                                   stdout=output, stderr=output)
            try:
                window_id = find_window(timeout=120)

                # --- Initial geometry ---
                init_w, init_h, init_x, init_y = get_geometry(window_id)
                results.append({'label': 'initial', 'width': init_w, 'height': init_h,
                                'x': init_x, 'y': init_y, 'passed': True})

                # --- Resize to 980x640 ---
                results.append(resize_and_verify(window_id, 980, 640, 'resize_980x640'))

                # --- Resize to 1400x900 ---
                results.append(resize_and_verify(window_id, 1400, 900, 'resize_1400x900'))

                # --- Resize smaller than initial (400x300) ---
                results.append(resize_and_verify(window_id, 400, 300, 'resize_small_400x300'))

                # --- Return to near-initial size ---
                results.append(resize_and_verify(window_id, init_w, init_h, 'restore_initial'))

                all_passed = all(r.get('passed', False) for r in results)
                report = {'passed': all_passed, 'results': results,
                          'checks': [r['label'] for r in results]}
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

    args.result.write_text(json.dumps(report, indent=2))
    if all_passed:
        print(f'Resize probe PASSED: {len(results)} steps, all ok')
    else:
        failed = [r['label'] for r in results if not r.get('passed', True)]
        print(f'Resize probe FAILED: {failed}')
        sys.exit(1)


if __name__ == '__main__':
    main()