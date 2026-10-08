#!/usr/bin/env python3
"""Exercise native Chromium load, resize and shutdown with isolated profiles.

Build first with CONFIGURATION=Debug Scripts/build.sh. This launches that exact
product and uses Cio's existing integration-test entry point, not a mock engine.
"""
import os
import argparse
from pathlib import Path
import subprocess
import threading
import tempfile
import signal
from http.server import ThreadingHTTPServer

from verification_fixture_server import FixtureHandler

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mock-keychain", action="store_true",
                        help="Use Chromium's test keychain only for these disposable test profiles")
    args = parser.parse_args()
    work = ROOT / "build/verification/native-runtime"
    work.mkdir(parents=True, exist_ok=True)
    # Keep test data outside Documents: changing an ad-hoc Debug signature can
    # otherwise leave a TCC folder prompt blocking Chromium's worker threads.
    data = Path(tempfile.mkdtemp(prefix="cio-native-runtime-"))
    server = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    executable = ROOT / "build/DerivedData/Build/Products/Debug/Cio.app/Contents/MacOS/Cio"
    try:
        for name, url in (("normal", base + "/native-bridge"),
                          ("page", base + "/native-bridge"),
                          ("settings", "chrome://settings/languages"),
                          ("repeat", base + "/page-b"),
                          ("beforeunload-cancel", base + "/beforeunload"),
                          ("beforeunload-accept", base + "/beforeunload")):
            environment = dict(os.environ, CIO_DATA_DIR=str(data / name),
                               CIO_DOWNLOADS_DIR=str(data / "downloads"),
                               CIO_DISABLE_SESSION_PERSISTENCE="1")
            choice = name.removeprefix("beforeunload-") if name.startswith("beforeunload-") else None
            if choice:
                environment["CIO_BEFOREUNLOAD_AUTORESPONSE"] = choice
            log = work / f"{name}.log"
            with log.open("w") as output:
                mode = (["--quit-after=15", "--wait-for-window"] if name == "normal" else
                        ["--beforeunload-self-test=" + choice if choice else "--browser-self-test"])
                command = [str(executable), "-ApplePersistenceIgnoreState", "YES", *mode,
                           "--home-url=" + url]
                if args.mock_keychain:
                    command.append("--use-mock-keychain")
                process = subprocess.Popen(command,
                                           env=environment, stdout=output, stderr=subprocess.STDOUT,
                                           start_new_session=True)
                try:
                    code = process.wait(timeout=90)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                    raise RuntimeError(f"{name}: load/shutdown timed out; see {log}")
            result = log.read_text()
            loaded = ("browser:first-load-finished" in result if name == "normal" else
                      "browser-self-test: loaded=true" in result)
            passed = (f"beforeunload-self-test: choice={choice} failures=0" in result
                      if choice else (loaded and "termination:cookies-flushed" in result))
            if (code != 0 or not passed or "cef:shutdown(clean: true)" not in result or "FATAL:" in result):
                raise RuntimeError(f"{name}: integration failure (exit {code}); see {log}")
            print(f"PASS: {name} completed in native Chromium and exited cleanly", flush=True)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
