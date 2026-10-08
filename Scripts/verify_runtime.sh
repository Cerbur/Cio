#!/usr/bin/env bash
# Native Chromium runtime acceptance. Historical callers keep this entry point.
# Build first with CONFIGURATION=Debug Scripts/build.sh.
# Pass --mock-keychain explicitly to isolate keychain access in test profiles.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CONFIGURATION="${CONFIGURATION:-Debug}"
"$REPO_ROOT/Scripts/verify_bundle.sh"
exec env PYTHONDONTWRITEBYTECODE=1 python3 "$REPO_ROOT/Scripts/verify_native_runtime.py" "$@"
