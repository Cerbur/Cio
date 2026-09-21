#!/usr/bin/env python3
"""Deterministic loopback fixture server for the Milestone 7 verifier."""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


PAYLOAD = (b"NativeBrowser Milestone 7 fixture payload\n" * 1024)


class FixtureHandler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args: object) -> None:
        # Verification logs must contain no accidental URL/query echo.
        return

    def do_GET(self) -> None:  # noqa: N802 - stdlib handler API
        path = urlsplit(self.path).path
        if path == "/healthz":
            self._send(200, b"ok\n", "text/plain; charset=utf-8")
        elif path == "/page-a":
            self._page("Page A", "This is deterministic fixture Page A.")
        elif path == "/page-b":
            self._page("Page B", "This is deterministic fixture Page B.")
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
        self.wfile.write(payload)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), FixtureHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
