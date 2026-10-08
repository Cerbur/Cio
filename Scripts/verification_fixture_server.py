#!/usr/bin/env python3
"""Deterministic loopback fixture server for browser verification."""

from __future__ import annotations

import argparse
import time
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


PAYLOAD = (b"Cio Milestone 7 fixture payload\n" * 1024)
SLOW_PAYLOAD = (b"Cio slow fixture payload\n" * 4096)


class FixtureHandler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args: object) -> None:
        # Verification logs must contain no accidental URL/query echo.
        return

    def do_GET(self) -> None:  # noqa: N802 - stdlib handler API
        request = urlsplit(self.path)
        path = request.path
        query = parse_qs(request.query)
        if path == "/healthz":
            self._send(200, b"ok\n", "text/plain; charset=utf-8")
        elif path == "/page-a":
            self._page("Page A", "This is deterministic fixture Page A.")
        elif path == "/page-b":
            secondary_titles = {
                "main": "Main secondary",
                "work": "Work secondary",
                "personal": "Personal secondary",
            }
            title = secondary_titles.get(query.get("space", [""])[0], "Page B")
            self._page(title, "This is deterministic fixture Page B.")
        elif path == "/slow-page":
            time.sleep(1.0)
            self._page("Slow Page", "This page intentionally delays its response.")
        elif path == "/beforeunload":
            self._beforeunload_page()
        elif path == "/popup":
            self._popup_page()
        elif path == "/native-bridge":
            self._native_bridge_page()
        elif path == "/native-child":
            self._send(200, b'''<!doctype html><meta charset=utf-8>
                <title>Native child</title><h1>Native child</h1><p id=result></p>
                <script>document.querySelector('#result').textContent =
                window.opener ? 'PASS: original popup retained opener' : 'FAIL: opener missing';
                if(window.opener) window.opener.postMessage('popup-opener-pass', location.origin);
                </script>''', "text/html; charset=utf-8")
        elif path == "/native-media":
            self._send(200, b'''<!doctype html><meta charset=utf-8><title>Native codec acceptance</title>
              <h1>Native codec acceptance</h1><p id=h264>H264 pending</p><p id=h265>H265 pending</p>
              <script>for(const name of ['h264','h265']) {
                const v=document.createElement('video'); v.muted=true; v.autoplay=true;
                v.width=320; v.src='/'+name+'.mp4'; document.body.append(v);
                v.onerror=()=>document.getElementById(name).textContent=name+' FAIL '+v.error.code;
                v.ontimeupdate=()=>{if(v.currentTime>0.5)
                  document.getElementById(name).textContent=name+' PASS decoded '+v.currentTime.toFixed(2)+'s'};
              }</script>''', "text/html; charset=utf-8")
        elif path in ("/h264.mp4", "/h265.mp4"):
            fixture = Path(__file__).resolve().parents[1] / "build/verification/native-bridge" / path[1:]
            if fixture.exists():
                self._send(200, fixture.read_bytes(), "video/mp4")
            else:
                self._send(404, b"Generate codec fixtures with ffmpeg first", "text/plain")
        elif path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/page-b")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif path == "/download":
            self._send(
                200,
                PAYLOAD,
                "application/octet-stream",
                extra={
                    "Content-Disposition": 'attachment; filename="fixture.bin"',
                },
            )
        elif path == "/archive.zip":
            self._send(200, PAYLOAD, "application/zip")
        elif path == "/opaque":
            self._send(200, PAYLOAD, "application/pdf")
        elif path == "/slow-download":
            self._slow_download()
        else:
            self._send(404, b"not found\n", "text/plain; charset=utf-8")

    def _page(self, title: str, body: str) -> None:
        payload = (
            "<!doctype html><meta charset=utf-8>"
            f"<title>{title}</title><main><h1>{title}</h1><p>{body}</p>"
            '<a data-m7-download-1 href="/download">Download fixture 1</a>'
            '<a data-m7-download-2 href="/download">Download fixture 2</a></main>'
        ).encode("utf-8")
        self._send(200, payload, "text/html; charset=utf-8")

    def _beforeunload_page(self) -> None:
        payload = (
            "<!doctype html><meta charset=utf-8>"
            "<title>Beforeunload fixture</title>"
            "<main><h1>Beforeunload fixture</h1>"
            "<p>This page asks Chromium to confirm an ordinary tab close.</p>"
            "<script>window.addEventListener('beforeunload', event => {"
            "event.preventDefault(); event.returnValue = '';"
            "});</script></main>"
        ).encode("utf-8")
        self._send(200, payload, "text/html; charset=utf-8")

    def _popup_page(self) -> None:
        payload = (
            "<!doctype html><meta charset=utf-8>"
            "<title>Popup fixture</title>"
            "<main><h1>Popup fixture</h1>"
            '<button id="open" onclick="window.open(\'/page-b\', \'_blank\')">'
            "Open popup</button></main>"
        ).encode("utf-8")
        self._send(200, payload, "text/html; charset=utf-8")

    def _native_bridge_page(self) -> None:
        # These are disposable loopback test cookies, never user credentials.
        payload = b'''<!doctype html><meta charset=utf-8><title>Native bridge acceptance</title>
        <h1>Native bridge acceptance</h1>
        <p id=cookies></p><p id=language></p><p id=popup>Popup pending</p>
        <button onclick="document.cookie='cio_session=acceptance;path=/';
          document.cookie='cio_persistent=acceptance;path=/;max-age=86400'; render()">Seed test cookies</button>
        <p><a href=/page-b>Navigate to Page B</a></p>
        <button onclick="window.open('/native-child', '_blank')">Open original popup</button>
        <p><a href=/native-child target=_blank>Open target blank</a></p>
        <p><a href=/download>Download fixture</a></p>
        <p><a href=/beforeunload>Beforeunload fixture</a></p>
        <script>function render(){document.querySelector('#cookies').textContent=
          'Test cookies: '+(document.cookie||'(none)')}
        render(); document.querySelector('#language').textContent='Language: '+navigator.language;
        addEventListener('message', e=>{if(e.origin===location.origin)
          document.querySelector('#popup').textContent=e.data});</script>'''
        self._send(200, payload, "text/html; charset=utf-8")

    def _slow_download(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(SLOW_PAYLOAD)))
        self.send_header(
            "Content-Disposition", 'attachment; filename="slow-fixture.bin"'
        )
        self.end_headers()
        chunk_size = 4096
        for offset in range(0, len(SLOW_PAYLOAD), chunk_size):
            try:
                self.wfile.write(SLOW_PAYLOAD[offset : offset + chunk_size])
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return
            time.sleep(0.01)

    def _send(
        self,
        status: int,
        payload: bytes,
        content_type: str,
        extra: dict[str, str] | None = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            # A browser watchdog or canceled download can close the loopback
            # socket after the response headers were sent. That is expected
            # fixture-client behavior, not a server failure.
            pass


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), FixtureHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
