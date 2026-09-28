#!/usr/bin/env bash
# Run after CONFIGURATION=Debug Scripts/build.sh from the repository root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXECUTABLE="$REPO_ROOT/build/DerivedData/Build/Products/Debug/NativeBrowser.app/Contents/MacOS/NativeBrowser"
LOG="$REPO_ROOT/build/appearance-verification.log"
DATA_DIR="$REPO_ROOT/build/verification-data/appearance-regression"

mkdir -p "$DATA_DIR"
if ! NATIVEBROWSER_DISABLE_SESSION_PERSISTENCE=1 NATIVEBROWSER_DATA_DIR="$DATA_DIR" \
  caffeinate -i "$EXECUTABLE" --browser-self-test --appearance-self-test \
  --home-url="file://$REPO_ROOT/Scripts/appearance_fixture.html" > "$LOG" 2>&1; then
  cat "$LOG"
  exit 1
fi

grep -qF 'browser-self-test: loaded=true' "$LOG"
for check in light dark light-again; do
  grep -qF "appearance-self-test: $check=true" "$LOG"
done
grep -qF 'lifecycle: browser:closed' "$LOG"
grep -qF 'lifecycle: cef:shutdown(clean: true)' "$LOG"
grep 'appearance-self-test:' "$LOG"
