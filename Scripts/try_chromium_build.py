#!/usr/bin/env python3
"""Build stock Chromium for macOS arm64 without changing Cio's active engine.

Uses Google's checksummed lite source archive and the binaries pinned in its
DEPS. Chromium files and toolchains stay in build/ChromiumBuild; Xcode's Metal
toolchain must already be installed through Xcode.
Rerun the same command to resume downloads or an interrupted Ninja build.
"""

import argparse
import ast
import base64
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import time
from urllib.parse import quote, urlparse
import zipfile


VERSION = "152.0.7977.83"
SOURCE_REVISION = "79460ebecaa5625e57a5fb679a735659e73dc687"
SOURCE_SHA256 = "ba910f09b487b076f79fa8badfa0cefd130cc50fcae88d61a7d92ee2d9665ad2"
SOURCE_URL = (
    "https://commondatastorage.googleapis.com/chromium-browser-official/"
    f"chromium-{VERSION}-lite.tar.xz"
)
GN_ARGS = '''target_cpu = "arm64"
is_debug = false
is_official_build = false
is_component_build = true
symbol_level = 0
blink_symbol_level = 0
v8_symbol_level = 0
use_thin_lto = false
chrome_pgo_phase = 0
use_remoteexec = false
use_siso = false
use_lld = false
proprietary_codecs = true
ffmpeg_branding = "Chrome"
'''


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class Attempt:
    def __init__(self, args):
        self.args = args
        self.root = Path(__file__).resolve().parents[1]
        self.work = self.root / "build/ChromiumBuild"
        self.source = self.work / "src"
        self.downloads = self.work / "downloads"
        self.downloads.mkdir(parents=True, exist_ok=True)
        self.env = os.environ.copy()
        self.env.update({
            "DEPOT_TOOLS_UPDATE": "0",
            "DEPOT_TOOLS_METRICS": "0",
            "CIPD_CACHE_DIR": str(self.work / "cipd-cache"),
            "VPYTHON_VIRTUALENV_ROOT": str(self.work / "vpython"),
            "XDG_CACHE_HOME": str(self.work / "cache"),
            "GOCACHE": str(self.work / "go-cache"),
            "GOMODCACHE": str(self.work / "go-modules"),
            "GOPATH": str(self.work / "go"),
            "GOTOOLCHAIN": "local",
            "PYTHONUNBUFFERED": "1",
        })
        # Chromium's Python actions import modules from their script directory.
        self.env.pop("PYTHONPATH", None)
        self.env["PATH"] += os.pathsep + str(self.work / "depot_tools")
        self.state = {
            "version": VERSION, "source_url": SOURCE_URL,
            "source_revision": SOURCE_REVISION,
            "source_sha256": SOURCE_SHA256, "jobs": args.jobs,
            "minimum_free_gib": args.minimum_free_gib,
            "source": str(self.source), "native_backend_built": False,
            "integrated_in_cio": False, "pid": os.getpid(),
        }
        self.phase = "starting"
        self.child = None

    def record(self, status, **values):
        self.state.update(values)
        self.state.update(status=status, phase=self.phase,
                          updated_at=datetime.now(timezone.utc).isoformat(),
                          available_gib=round(shutil.disk_usage(self.work).free / 2**30, 1))
        temporary = self.work / "attempt.json.tmp"
        temporary.write_text(json.dumps(self.state, indent=2) + "\n")
        temporary.replace(self.work / "attempt.json")

    def check_space(self):
        free = shutil.disk_usage(self.work).free / 2**30
        if free < self.args.minimum_free_gib:
            raise RuntimeError(f"Stopped with {free:.1f} GiB free; disk reserve is "
                               f"{self.args.minimum_free_gib} GiB")

    def run(self, phase, command, cwd=None):
        self.phase = phase
        self.check_space()
        self.record("running", command=[str(part) for part in command])
        print(f"\n[{phase}] {' '.join(map(str, command))}", flush=True)
        self.child = subprocess.Popen(command, cwd=cwd or self.work, env=self.env,
                                      start_new_session=True)
        try:
            while self.child.poll() is None:
                self.check_space()
                self.record("running")
                time.sleep(5)
            result = self.child.wait()
            if result:
                raise RuntimeError(f"{phase} failed with exit code {result}")
        finally:
            if self.child.poll() is None:
                os.killpg(self.child.pid, signal.SIGTERM)
                try:
                    self.child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(self.child.pid, signal.SIGKILL)
                    self.child.wait()
            self.child = None

    def download(self, url, output, expected=None):
        if output.exists() and expected and sha256(output) == expected:
            return
        partial = output.with_name(output.name + ".partial")
        self.run("download:" + output.name, [
            "curl", "--fail", "--location", "--retry", "5", "--retry-delay", "5",
            "--connect-timeout", "30", "--speed-limit", "1024", "--speed-time", "120",
            "--continue-at", "-", url, "--output", str(partial),
        ])
        if expected and sha256(partial) != expected:
            raise RuntimeError(f"Checksum mismatch: {partial}; preserving downloaded file")
        partial.replace(output)

    def prepare_source(self):
        marker = self.source / ".cio-source.json"
        if marker.exists():
            if json.loads(marker.read_text()).get("sha256") != SOURCE_SHA256:
                raise RuntimeError("Preserving source tree with a different source version")
            return
        archive = self.downloads / f"chromium-{VERSION}-lite.tar.xz"
        self.download(SOURCE_URL, archive, SOURCE_SHA256)
        self.source.mkdir(exist_ok=True)
        # Extraction can resume only in a tree created by this recipe.
        pending = self.work / "source-extraction.json"
        if any(self.source.iterdir()) and not pending.exists():
            raise RuntimeError("Preserving an existing source tree without a recipe marker")
        pending.write_text(json.dumps({"sha256": SOURCE_SHA256}))
        self.run("extract-source", ["tar", "-xf", str(archive), "--strip-components=1",
                                    "-C", str(self.source)])
        fields = dict(line.split("=", 1) for line in
                      (self.source / "chrome/VERSION").read_text().splitlines())
        actual = ".".join(fields[key] for key in ("MAJOR", "MINOR", "BUILD", "PATCH"))
        if actual != VERSION:
            raise RuntimeError(f"Source archive contains unexpected version {actual}")
        lastchange = (self.source / "build/util/LASTCHANGE").read_text()
        if not lastchange.startswith("LASTCHANGE=" + SOURCE_REVISION + "-"):
            raise RuntimeError("Source archive revision does not match the pinned build")
        marker.write_text(json.dumps({"version": VERSION, "sha256": SOURCE_SHA256,
                                      "revision": SOURCE_REVISION,
                                      "url": SOURCE_URL}, indent=2) + "\n")
        pending.unlink()

    def prepare_tools(self):
        # Read only literal values from DEPS; do not evaluate its Python code.
        tree = ast.parse((self.source / "DEPS").read_text())
        tables = {node.targets[0].id: node.value for node in tree.body
                  if isinstance(node, ast.Assign) and len(node.targets) == 1
                  and isinstance(node.targets[0], ast.Name)}
        variables = {ast.literal_eval(key): value for key, value in
                     zip(tables["vars"].keys, tables["vars"].values)}
        deps = {ast.literal_eval(key): value for key, value in
                zip(tables["deps"].keys, tables["deps"].values)}
        selected = (
            "third_party/llvm-build/Release+Asserts", "third_party/llvm-libclang",
            "third_party/rust-toolchain", "third_party/node/mac_arm64",
            "third_party/node/node_modules",
        )
        for name in selected:
            dep = ast.literal_eval(deps["src/" + name])
            for obj in dep["objects"]:
                object_name = obj["object_name"]
                if "condition" in obj and 'host_cpu == "arm64"' not in obj["condition"]:
                    continue
                if name.endswith("Release+Asserts") and not Path(object_name).name.startswith(
                        ("clang-llvmorg-", "llvmobjdump-")):
                    continue
                output = self.downloads / (obj["sha256sum"] + ".tar")
                url = f"https://storage.googleapis.com/{dep['bucket']}/{object_name}"
                self.download(url, output, obj["sha256sum"])
                destination = self.source / name
                destination.mkdir(parents=True, exist_ok=True)
                marker = destination / (".cio-" + obj["sha256sum"])
                if not marker.exists():
                    self.run("extract-tool:" + name, ["tar", "-xf", str(output),
                                                       "-C", str(destination)])
                    marker.touch()
        for name, package, revision in (
            ("buildtools/mac", "gn/gn/mac-arm64", ast.literal_eval(variables["gn_version"])),
            ("third_party/ninja", "infra/3pp/tools/ninja/mac-arm64",
             ast.literal_eval(variables["ninja_version"])),
            ("ui/gl/resources/angle-metal", "chromium/gpu/angle-metal-shader-libraries",
             ast.literal_eval(deps["src/ui/gl/resources/angle-metal"])["packages"][0]["version"]),
            # This revision is pinned by the nested DevTools DEPS in the same
            # checksummed source archive. The archive includes a Linux esbuild.
            ("third_party/devtools-frontend/src/third_party/esbuild",
             "infra/3pp/tools/esbuild/mac-arm64", "version:3@0.25.1.chromium.2"),
            # dawn_go_version in the nested Dawn DEPS.
            ("third_party/dawn/tools/golang/mac-arm64", "infra/3pp/tools/go/mac-arm64",
             "version:3@1.25.0"),
        ):
            destination = self.source / name
            if (destination / ".cio-cipd-version").exists():
                if (destination / ".cio-cipd-version").read_text() == revision:
                    continue
                raise RuntimeError("Preserving tools with another CIPD version")
            archive = self.downloads / (name.replace("/", "-") + ".zip")
            self.download(f"https://chrome-infra-packages.appspot.com/dl/{package}/+/"
                          + quote(revision, safe=":"), archive)
            destination.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(archive) as files:
                for member in files.infolist():
                    target = destination / member.filename
                    if not target.resolve().is_relative_to(destination.resolve()):
                        raise RuntimeError("Unsafe path in CIPD archive")
                    files.extract(member, destination)
                    mode = member.external_attr >> 16
                    if mode and target.is_file():
                        target.chmod(mode & 0o777)
            (destination / ".cio-cipd-version").write_text(revision)
        for executable in ("buildtools/mac/gn", "third_party/ninja/ninja",
                           "third_party/devtools-frontend/src/third_party/esbuild/esbuild",
                           "third_party/dawn/tools/golang/mac-arm64/bin/go"):
            (self.source / executable).chmod(0o755)
        self.prepare_devtools_modules()

    def prepare_devtools_modules(self):
        frontend = self.source / "third_party/devtools-frontend/src"
        lock = json.loads((frontend / "package-lock.json").read_text())
        for name in ("@rollup/rollup-darwin-arm64", "@esbuild/darwin-arm64"):
            relative = "node_modules/" + name
            package = lock["packages"][relative]
            integrity = package["integrity"]
            algorithm, encoded = integrity.split("-", 1)
            if algorithm != "sha512":
                raise RuntimeError("Unexpected package-lock integrity algorithm")
            destination = frontend / relative
            marker = destination / ".cio-package-integrity"
            if marker.exists() and marker.read_text() == integrity:
                continue
            url = package["resolved"]
            if urlparse(url).scheme != "https" or urlparse(url).hostname not in (
                    "npm.skia.org", "registry.npmjs.org"):
                raise RuntimeError("Unexpected locked NPM package source")
            archive = self.downloads / (name.replace("/", "-") + "-" + package["version"] + ".tgz")
            self.download(url, archive)
            with archive.open("rb") as stream:
                actual = hashlib.file_digest(stream, "sha512").digest()
            if actual != base64.b64decode(encoded, validate=True):
                raise RuntimeError("NPM package integrity mismatch: " + name)
            destination.mkdir(parents=True, exist_ok=True)
            # Extract the locked native package; do not run NPM install scripts.
            self.run("extract-module:" + name, ["tar", "-xf", str(archive),
                                                "--strip-components=1", "-C", str(destination)])
            marker.write_text(integrity)

    def build(self):
        self.run("check-metal-toolchain", ["xcrun", "metal", "--version"])
        self.prepare_source()
        self.prepare_tools()
        output = self.source / "out/CioDev"
        output.mkdir(parents=True, exist_ok=True)
        args_path = output / "args.gn"
        if args_path.exists() and args_path.read_text() != GN_ARGS:
            raise RuntimeError("Preserving existing output with different GN arguments")
        args_path.write_text(GN_ARGS)
        self.run("generate", [str(self.source / "buildtools/mac/gn"), "gen", "out/CioDev",
                              "--fail-on-unused-args"], self.source)
        self.run("compile", ["caffeinate", "-i", str(self.source / "third_party/ninja/ninja"),
                             "-C", "out/CioDev", "-j", str(self.args.jobs), "chrome"], self.source)
        app = output / "Chromium.app"
        if not (app / "Contents/MacOS/Chromium").is_file():
            raise RuntimeError("Ninja completed but Chromium.app executable is missing")
        self.phase = "complete"
        self.record("success", app=str(app), stock_chromium_built=True)
        print(f"\nBuilt stock Chromium: {app}\nRun CONFIGURATION=Debug Scripts/build.sh to compile Cio's native overlay and package the app.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--minimum-free-gib", type=int, default=20)
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("this recipe requires macOS arm64")
    if args.jobs < 1 or args.minimum_free_gib < 1:
        parser.error("jobs and disk reserve must be positive")
    def interrupt(signum, frame):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGHUP, interrupt)
    attempt = Attempt(args)
    with (attempt.work / "attempt.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("another Chromium build attempt is running")
        try:
            attempt.build()
        except (Exception, KeyboardInterrupt) as error:
            attempt.record("failed", error=str(error) or "interrupted")
            print(f"\nChromium build attempt stopped: {error}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
