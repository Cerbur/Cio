#!/usr/bin/env python3
"""Render the real nested CSS fallback in Cio's pinned native Blink engine.

Run after CONFIGURATION=Debug Scripts/build.sh. This checks computed style,
renderer survival and the real page-load callback in the packaged Debug app.
"""
from pathlib import Path
import os
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / 'build/DerivedData/Build/Products/Debug/Cio.app/Contents/MacOS/Cio'
FIXTURE = ROOT / 'Engine/CioChromium/Tests/CSSVariableFallback.html'
WORK = ROOT / 'build/verification/css-variable-fallback'


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='profile-', dir=WORK) as profile:
        process = subprocess.Popen(
            [str(ENGINE), '--enable-logging=stderr', '--use-mock-keychain',
             '--home-url=' + FIXTURE.as_uri(),
             '--quit-after=5'],
            env={**os.environ, 'CIO_DATA_DIR': profile, 'CIO_DISABLE_SESSION_PERSISTENCE': '1'},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            start_new_session=True)
        try:
            output, errors = process.communicate(timeout=20)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            output, errors = process.communicate()
        trace = output + errors
        (WORK / 'runtime.log').write_text(trace)
        loaded = 'browser:first-load-finished(title-present=true,' in trace
        crashed = 'renderer:terminated' in trace or 'FATAL:' in trace
        computed_style_passed = 'css-variable-fallback: PASS' in trace
        if process.returncode != 0 or not loaded or crashed or not computed_style_passed:
            print('FAIL: nested CSS fallback verification '
                  f'(exit={process.returncode}, loaded={loaded}, '
                  f'computed-style={computed_style_passed}, crashed={crashed})')
            for line in errors.splitlines():
                if 'FATAL:' in line or 'DCHECK failed' in line or 'css-variable-fallback: FAIL' in line:
                    print(line)
            raise SystemExit(1)
        print('PASS: nested CSS fallback renders rgb(0, 128, 0) in Cio without a renderer crash')


if __name__ == '__main__':
    main()
