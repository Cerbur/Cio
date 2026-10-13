#!/usr/bin/env python3
"""Real Chromium cookie mutation flush, force-quit and relaunch acceptance.

Build first with CONFIGURATION=Debug Scripts/build.sh. All data is disposable;
the default run uses the real encrypted cookie store. --mock-keychain is an
explicit alternative and cannot establish real Keychain acceptance.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import threading
import time
from http.cookies import SimpleCookie
from http.server import ThreadingHTTPServer
from urllib.parse import urlsplit

from verification_fixture_server import FixtureHandler

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mock-keychain", action="store_true")
    args = parser.parse_args()
    app = ROOT / "build/DerivedData/Build/Products/Debug/Cio.app/Contents/MacOS/Cio"
    if not app.is_file():
        parser.error("Build the Debug app with Scripts/build.sh first")
    work = ROOT / "build/verification/daily-persistence"
    work.mkdir(parents=True, exist_ok=True)
    data = Path(tempfile.mkdtemp(prefix="cio-daily-persistence-"))
    print(f"Disposable profile: {data}", flush=True)
    restored = threading.Event()
    hold_restore = threading.Event()
    restore_requested = threading.Event()
    release_restore = threading.Event()

    class Handler(FixtureHandler):
        def do_GET(self):
            if urlsplit(self.path).path == "/daily/login":
                self.do_POST()  # Explicit test-only seed, not a product login API.
                return
            super().do_GET()

        def _daily_page(self):
            if hold_restore.is_set():
                restore_requested.set()
                release_restore.wait(timeout=40)
            cookies = SimpleCookie()
            cookies.load(self.headers.get("Cookie", ""))
            if all(cookies.get(name) and cookies[name].value == "fixture"
                   for name in ("cio_test_session", "cio_test_persistent")):
                restored.set()
            super()._daily_page()

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    process = None

    def launch(name, seed=False):
        command = [str(app), "-ApplePersistenceIgnoreState", "YES",
                   "--wait-for-window", "--home-url=" + base + ("/daily/login" if seed else "/page-b")]
        if not seed:
            command.append("--quit-after=20")
        if args.mock_keychain:
            command.append("--use-mock-keychain")
        with (work / f"{name}.log").open("w") as output:
            return subprocess.Popen(command, env=dict(os.environ, CIO_DATA_DIR=str(data)),
                                    stdout=output, stderr=subprocess.STDOUT, start_new_session=True)

    def stop(process):
        if process is not None and process.poll() is None:
            # Only the group started by this verifier. Never target a user's Cio.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()

    try:
        process = launch("seed", seed=True)
        if not restored.wait(45):
            raise RuntimeError("Fixture sign-in did not complete (check Keychain authorization and seed.log)")
        cookies_file = data / "Chromium/Default/Cookies"
        deadline = time.monotonic() + 10
        durable = False
        while time.monotonic() < deadline:
            try:
                with sqlite3.connect(f"file:{cookies_file}?mode=ro", uri=True) as database:
                    rows = database.execute(
                        "SELECT name, length(value), length(encrypted_value) FROM cookies "
                        "WHERE name IN ('cio_test_session', 'cio_test_persistent')").fetchall()
                durable = len(rows) == 2 and all(plain == 0 and encrypted > 0 for _, plain, encrypted in rows)
            except sqlite3.Error:
                durable = False
            if durable:
                break
            time.sleep(0.1)
        if not durable:
            raise RuntimeError("Cookie mutations were not encrypted and flushed within 10 seconds")
        deadline = time.monotonic() + 20
        snapshot = None
        while time.monotonic() < deadline:
            candidate = json.loads((data / "session-v1.json").read_text())
            if any(tab.get("url") == base + "/daily" and tab.get("title") == "Daily browser acceptance"
                   for space in candidate["spaces"] for tab in space["tabs"]):
                snapshot = candidate
                break
            time.sleep(0.1)
        if snapshot is None:
            raise RuntimeError("Fixture login never committed to the durable workspace")
        (work / "seed-workspace.json").write_text(json.dumps(snapshot, indent=2))
        stop(process)
        process = None
        print("PASS: live cookie mutations reached encrypted storage before force quit", flush=True)

        for phase in ("after-force-quit", "after-clean-quit"):
            restored.clear()
            if phase == "after-force-quit":
                hold_restore.set()
            process = launch(phase)
            if phase == "after-force-quit":
                if not restore_requested.wait(15):
                    raise RuntimeError("Restored navigation did not reach the fixture server")
                # Keep the response pending while bootstrap callbacks settle.
                time.sleep(1)
                pending = json.loads((data / "session-v1.json").read_text())
                if pending != snapshot:
                    raise RuntimeError("Bootstrap page replaced the saved workspace during restoration")
                print("PASS: pending restore retained saved URL, title and workspace identity", flush=True)
                hold_restore.clear()
                release_restore.set()
            if not restored.wait(45):
                raise RuntimeError(f"{phase}: restored page did not receive both login cookies")
            if process.wait(timeout=45) != 0:
                raise RuntimeError(f"{phase}: app did not quit cleanly")
            process = None
            log = (work / f"{phase}.log").read_text()
            if "cef:shutdown(clean: true)" not in log:
                raise RuntimeError(f"{phase}: missing clean engine shutdown")
            current = json.loads((data / "session-v1.json").read_text())
            if current != snapshot:
                raise RuntimeError(f"{phase}: durable workspace changed across relaunch")
            print(f"PASS: {phase} restored exact workspace and both HttpOnly login cookies", flush=True)
        print("Keychain mode: " + ("MOCK (real authorization unverified)" if args.mock_keychain else "REAL"))
        print(f"Evidence: {work}; disposable profile: {data}")
    finally:
        release_restore.set()
        stop(process)
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
