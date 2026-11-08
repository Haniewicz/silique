#!/usr/bin/env python3
"""Compile and exercise the GTK4 window resize probe under xvfb.

Runs on the Silique Linux builder (CT 104), not on AiBrain.
Skips gracefully when the GTK4 SDK is not present.
"""
import json
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def _pkg_config_available():
    try:
        subprocess.run(['pkg-config', '--exists', 'gtk4'], check=True, capture_output=True)
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def _compile(source, binary):
    flags_cflags = shlex.split(
        subprocess.check_output(['pkg-config', '--cflags', 'gtk4'], text=True))
    flags_libs = shlex.split(
        subprocess.check_output(['pkg-config', '--libs', 'gtk4'], text=True))
    cmd = ['g++', '-std=c++17', '-Wall', '-Wextra', '-Werror', *flags_cflags,
           str(source), '-o', str(binary), *flags_libs]
    subprocess.run(cmd, check=True, timeout=60)


def _run_probe(binary, report):
    env = os.environ | {'GDK_BACKEND': 'x11', 'GTK_A11Y': 'none', 'GSK_RENDERER': 'cairo'}
    subprocess.run(
        ['xvfb-run', '-a', '-s', '-screen 0 1024x768x24', str(binary), str(report)],
        env=env, check=True, timeout=30)
    return json.loads(report.read_text())


def main():
    if not _pkg_config_available():
        print('SKIP: GTK4 SDK not available (runs on the Silique Linux builder, CT 104)')
        return 0

    source = ROOT / 'gtk4' / 'window_resize_probe.cc'
    if not source.exists():
        print(f'SKIP: probe source not found at {source}')
        return 0

    with tempfile.TemporaryDirectory(prefix='silique-window-probe-') as tmp:
        tmp = Path(tmp)
        binary_true = tmp / 'window-resize-probe-true'
        binary_false = tmp / 'window-resize-probe-false'
        report_true = tmp / 'result-true.json'
        report_false = tmp / 'result-false.json'

        print('=== Compiling TRUE variant ===')
        _compile(source, binary_true)

        print('=== Compiling FALSE variant ===')
        source_text = source.read_text()
        source_false = source_text.replace(
            'gtk_window_set_resizable(window, TRUE)',
            'gtk_window_set_resizable(window, FALSE)')
        source_false = source_false.replace('after_set_resizable', 'after_set_false')
        false_source = tmp / 'probe_false.cc'
        false_source.write_text(source_false)
        _compile(false_source, binary_false)

        print('=== Running TRUE variant ===')
        result_true = _run_probe(binary_true, report_true)

        print('=== Running FALSE variant ===')
        result_false = _run_probe(binary_false, report_false)

        print(f'\nTRUE  variant: passed={result_true["passed"]}, checks={result_true["checks"]}')
        print(f'FALSE variant: passed={result_false["passed"]}, checks={result_false["checks"]}')

        ok = (result_true['passed'] is True and
              result_false['passed'] is False and
              'default_resizable=TRUE' in result_true['checks'] and
              'after_set_resizable=TRUE' in result_true['checks'] and
              'after_set_false=FALSE' in result_false['checks'])

        if ok:
            print('\nPASS: GTK4 window resize probe confirms:')
            print('  - GTK4 default resizable = TRUE')
            print('  - set_resizable(TRUE) keeps it TRUE')
            print('  - set_resizable(FALSE) makes it FALSE')
            print('  - The flag works at the GTK level')
            return 0
        else:
            print('\nFAIL: unexpected probe results')
            return 1


if __name__ == '__main__':
    sys.exit(main())