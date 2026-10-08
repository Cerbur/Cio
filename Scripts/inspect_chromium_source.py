#!/usr/bin/env python3
"""Read-only readiness report for a supplied, existing Chromium source tree."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Chromium src directory")
    args = parser.parse_args()
    source = args.source.expanduser().resolve()
    if not source.is_dir():
        parser.error("source directory does not exist")

    required = (
        "BUILD.gn",
        "DEPS",
        "chrome/VERSION",
        "chrome/app/chrome_main_delegate.h",
        "chrome/browser/ui/browser.h",
        "chrome/browser/ui/browser_window.h",
        "chrome/browser/ui/tabs/tab_strip_model.h",
        "content/public/browser/web_contents.h",
        "build/config/BUILDCONFIG.gn",
        "third_party/llvm-build/Release+Asserts/bin/clang",
    )
    missing = [name for name in required if not (source / name).is_file()]
    if not any((source / name).is_file() for name in (
            "buildtools/mac/gn", "buildtools/mac/gn/gn", "third_party/gn/gn")):
        missing.append("GN executable")
    version = None
    version_path = source / "chrome/VERSION"
    if version_path.is_file():
        values = dict(line.split("=", 1) for line in version_path.read_text().splitlines() if "=" in line)
        fields = [values.get(name) for name in ("MAJOR", "MINOR", "BUILD", "PATCH")]
        if all(value and value.isdecimal() for value in fields):
            version = ".".join(fields)

    revision = None
    archive = None
    archive_marker = source / ".cio-source.json"
    if archive_marker.is_file():
        archive = json.loads(archive_marker.read_text())
    # Only inspect a Git checkout at this root, not a parent Cio repository.
    if (source / ".git").exists():
        result = subprocess.run(
            ["git", "-C", str(source), "rev-parse", "HEAD"],
            text=True, capture_output=True, check=False,
        )
        if result.returncode == 0:
            revision = result.stdout.strip()
    free_gib = round(shutil.disk_usage(source).free / (1024 ** 3), 1)
    identity_present = revision is not None or (
        archive is not None and archive.get("version") == version
        and archive.get("sha256") and archive.get("url")
    )
    ready = bool(not missing and version is not None and identity_present)
    print(json.dumps({
        "source": str(source),
        "chromium_version": version,
        "revision": revision,
        "source_archive": archive,
        "missing": missing,
        "available_gib": free_gib,
        "source_and_tools_present": ready,
        "native_backend_built": False,
        "note": "Source readiness is not a successful build or a port of Cio's native adapter.",
    }, ensure_ascii=False, indent=2))
    return 0 if ready else 1


if __name__ == "__main__":
    sys.exit(main())
