#!/usr/bin/env python3
"""Regression: password preferences must start with no Apple extension installed.

Launches only the repository Debug app, using disposable profiles and Chromium's
mock keychain. Does not install an extension or access the user's password data.
"""
import os
from pathlib import Path
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'build/DerivedData/Build/Products/Debug/Cio.app'
WORK = ROOT / 'build/verification/password-startup'


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    data = Path(tempfile.mkdtemp(prefix='cio-password-startup-'))
    # Same isolated profile: first launch without the extension, then restart.
    environment = dict(os.environ, CIO_DATA_DIR=str(data),
                       CIO_DISABLE_SESSION_PERSISTENCE='1')
    for name in ('first-launch', 'restart'):
        log = WORK / (name + '.log')
        with log.open('w') as output:
            process = subprocess.Popen([
                str(APP / 'Contents/MacOS/Cio'), '-ApplePersistenceIgnoreState', 'YES',
                '--use-mock-keychain', '--home-url=about:blank',
                '--quit-after=5', '--wait-for-window',
            ], env=environment, stdout=output, stderr=subprocess.STDOUT,
               start_new_session=True)
            try:
                code = process.wait(timeout=45)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                raise RuntimeError(f'{name}: startup/shutdown timed out; see {log}')
        result = log.read_text()
        if (code != 0 or 'FATAL:' in result or
                'browser:first-load-finished' not in result or
                'cef:shutdown(clean: true)' not in result):
            raise RuntimeError(f'{name}: password initialization failed (exit {code}); see {log}')
        print(f'PASS: {name}, no Apple extension, window loaded and clean shutdown', flush=True)


if __name__ == '__main__':
    main()
