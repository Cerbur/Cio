#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="$(mktemp -d "${TMPDIR:-/tmp}/cio-devtools.XXXXXX")"
trap 'rm -rf "$PROFILE"' EXIT
mkdir -p "$PROFILE/Chromium/Default"
DOCK_SIDE="${CIO_DEVTOOLS_DOCK_SIDE:-bottom}"
case "$DOCK_SIDE" in bottom|right) ;; *) exit 2 ;; esac
printf '{"devtools":{"preferences":{"currentDockState":"\\"%s\\""}}}\n' "$DOCK_SIDE" \
  > "$PROFILE/Chromium/Default/Preferences"
CIO_DATA_DIR="$PROFILE" "$REPO_ROOT/build/DerivedData/Build/Products/Debug/Cio.app/Contents/MacOS/Cio" \
  --devtools-self-test "--devtools-dock=$DOCK_SIDE" \
  '--home-url=data:text/html,<title>DevTools fixture</title><h1 id="target">Inspector fixture</h1>'
