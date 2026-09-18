#!/usr/bin/env bash
#
# Milestone 1 acceptance checks (ARCHITECTURE.md section 38).
#
#   Scripts/verify_milestone1.sh
#
# Checks:
#   1. the app launches and the SwiftUI window comes up
#   2. https://www.google.com loads inside the NSView-backed CEF browser
#   3. the page title and URL callbacks reach the application
#   4. the Chromium view resizes with its container
#   5. the browser is destroyed before CEF shuts down, and quitting is clean
#
# Exits non-zero when any check fails.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
APP="$REPO_ROOT/build/DerivedData/Build/Products/$CONFIGURATION/NativeBrowser.app"
EXECUTABLE="$APP/Contents/MacOS/NativeBrowser"
DATA_DIR="$REPO_ROOT/build/cef-data"
WORK_DIR="$REPO_ROOT/build/verification"

FAILURES=0
pass() { printf '  [pass] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check_contains() {
  if grep -qF "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1 (missing: $2)"; fi
}

mkdir -p "$DATA_DIR" "$WORK_DIR"

if [ ! -x "$EXECUTABLE" ]; then
  echo "error: $EXECUTABLE not found; run Scripts/build.sh first" >&2
  exit 1
fi

echo "Milestone 1 verification"
echo "app: $APP"
echo

# ---------------------------------------------------------------------------
echo "1-2. page load and resize (--browser-self-test)"
SELF_LOG="$WORK_DIR/self-test.log"
NATIVEBROWSER_DATA_DIR="$DATA_DIR" "$EXECUTABLE" --browser-self-test > "$SELF_LOG" 2>&1
SELF_STATUS=$?
if [ "$SELF_STATUS" -eq 0 ]; then
  pass "self-test exited 0"
else
  fail "self-test exited with $SELF_STATUS"
fi
check_contains "CEF initialized" "cef:initialized" "$SELF_LOG"
check_contains "Chromium browser created" "browser:created" "$SELF_LOG"
check_contains "google.com reported its title and URL" \
  "browser:first-load-finished(title=Google, url=https://www.google.com/)" "$SELF_LOG"
check_contains "page load completed without a navigation error" "selftest:loaded=true" "$SELF_LOG"
check_contains "resize propagated to the container" "selftest:resized=900x620" "$SELF_LOG"
check_contains "Chromium view matched the container size" "resized: container=900x620 view=900x620" "$SELF_LOG"
check_contains "browser destroyed before shutdown" "browser-closed=true" "$SELF_LOG"
check_contains "CEF shut down cleanly" "cef:shutdown(clean: true)" "$SELF_LOG"

# ---------------------------------------------------------------------------
echo
echo "1-3-5. application launch, navigation callbacks and clean termination"
GUI_LOG="$WORK_DIR/launch.log"
QUIT_AFTER=10
GUI_START=$(date +%s)
NATIVEBROWSER_DATA_DIR="$DATA_DIR" "$EXECUTABLE" --quit-after=$QUIT_AFTER > "$GUI_LOG" 2>&1
GUI_STATUS=$?
GUI_TOTAL=$(( $(date +%s) - GUI_START ))
if [ "$GUI_STATUS" -eq 0 ]; then
  pass "app launched and terminated with exit 0"
else
  fail "app exited with $GUI_STATUS"
fi
check_contains "SwiftUI window appeared" "swiftui:main-window-appeared" "$GUI_LOG"
check_contains "AppKit container view created" "appkit:chromium-container-created" "$GUI_LOG"
check_contains "Chromium browser created for the session" "browser:created" "$GUI_LOG"
check_contains "google.com loaded in the running app" \
  "browser:first-load-finished(title=Google, url=https://www.google.com/)" "$GUI_LOG"
check_contains "page received keyboard focus" "[browser] focus granted" "$GUI_LOG"
check_contains "browser destroyed before CEF shutdown" "browser:closed" "$GUI_LOG"
check_contains "CEF shut down cleanly" "cef:shutdown(clean: true)" "$GUI_LOG"

# Quitting must not hang: the browser close has to finish well inside the
# application's shutdown budget.
if [ "$GUI_TOTAL" -le $((QUIT_AFTER + 6)) ]; then
  pass "quit completed in ${GUI_TOTAL}s (no shutdown hang)"
else
  fail "quit took ${GUI_TOTAL}s"
fi

CLOSE_START=$(grep -oE '^[0-9-]+ [0-9:.]+' "$GUI_LOG" | head -1)
DO_CLOSE=$(grep -m1 'DoClose' "$GUI_LOG" | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+' | head -1)
BEFORE_CLOSE=$(grep -m1 'OnBeforeClose' "$GUI_LOG" | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+' | head -1)
if [ -n "$DO_CLOSE" ] && [ -n "$BEFORE_CLOSE" ]; then
  # Compare as seconds within the same minute-independent clock.
  CLOSE_MS=$(( $(date -j -f "%H:%M:%S" "${BEFORE_CLOSE%%.*}" +%s) - $(date -j -f "%H:%M:%S" "${DO_CLOSE%%.*}" +%s) ))
  if [ "$CLOSE_MS" -le 5 ]; then
    pass "browser close completed in about ${CLOSE_MS}s"
  else
    fail "browser close took about ${CLOSE_MS}s"
  fi
else
  fail "could not measure the browser close duration"
fi

# ---------------------------------------------------------------------------
echo
echo "signature and runtime"
if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
  pass "app, framework and helpers have a valid signature"
else
  fail "code signature verification failed"
fi
if [ -f "$DATA_DIR/Logs/cef.log" ]; then
  pass "CEF wrote its log file"
else
  fail "CEF log file was not created"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "Milestone 1: all checks passed"
else
  echo "Milestone 1: $FAILURES check(s) failed"
fi
exit $((FAILURES > 0 ? 1 : 0))
