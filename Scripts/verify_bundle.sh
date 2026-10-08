#!/usr/bin/env bash
# Static native-runtime validation; never launches the app.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$REPO_ROOT/Scripts/verify_native_bundle.py"
