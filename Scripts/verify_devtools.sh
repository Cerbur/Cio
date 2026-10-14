#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="$(mktemp -d "${TMPDIR:-/tmp}/cio-devtools.XXXXXX")"
trap 'rm -rf "$PROFILE"' EXIT
mkdir -p "$PROFILE/Chromium/Default"
cat > "$PROFILE/Chromium/Default/Preferences" <<'JSON'
{"devtools":{"preferences":{"currentDockState":"\"bottom\""}}}
JSON
CIO_DATA_DIR="$PROFILE" "$REPO_ROOT/build/DerivedData/Build/Products/Debug/Cio.app/Contents/MacOS/Cio" \
  --devtools-self-test '--home-url=data:text/html,<title>DevTools fixture</title><h1 id="target">Inspector fixture</h1>'
