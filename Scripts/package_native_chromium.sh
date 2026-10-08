#!/usr/bin/env bash
set -euo pipefail
PYTHONDONTWRITEBYTECODE=1 python3 "$SRCROOT/Scripts/package_native_chromium.py"
