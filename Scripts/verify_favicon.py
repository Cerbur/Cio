#!/usr/bin/env python3
"""Exercise Chromium's CSS-styled SVG favicon through the packaged Debug Cio."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import os
import signal
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'build/verification/favicon'
APP = ROOT / 'build/DerivedData/Build/Products/Debug/Cio.app/Contents/MacOS/Cio'
SVG = b'''<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" fill="none">
<style>:root { fill: #008000; }</style><rect x="4" y="4" width="24" height="24"/></svg>'''
PAGE = b'''<!doctype html><title>Styled SVG favicon regression</title>
<link rel="icon" type="image/svg+xml" href="/favicon.svg"><h1>Styled SVG favicon</h1>'''


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/favicon.svg':
            content, mime = SVG, 'image/svg+xml'
        elif self.path == '/':
            content, mime = PAGE, 'text/html'
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def log_message(self, *_):
        pass


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    with ThreadingHTTPServer(('127.0.0.1', 0), Fixture) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        with tempfile.TemporaryDirectory(prefix='profile-', dir=WORK) as profile:
            process = subprocess.Popen(
                [str(APP), '--enable-logging=stderr', '--use-mock-keychain',
                 '--home-url=http://127.0.0.1:' + str(server.server_port) + '/',
                 '--favicon-self-test', '--quit-after=5'],
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
            passed = process.returncode == 0 and 'favicon-self-test: PASS' in trace
            passed = passed and 'FATAL:' not in trace and 'renderer:terminated' not in trace
            for line in trace.splitlines():
                if 'favicon-self-test:' in line or 'FATAL:' in line:
                    print(line)
            server.shutdown()
            if not passed:
                raise SystemExit('FAIL: native CSS-styled SVG favicon did not render')
            print('PASS: real Chromium favicon artwork is visible and its SVG CSS is applied')


if __name__ == '__main__':
    main()
