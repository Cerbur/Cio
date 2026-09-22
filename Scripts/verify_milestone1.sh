#!/usr/bin/env bash
#
# Milestone 1 acceptance checks (ARCHITECTURE.md section 38).
#
#   Scripts/verify_milestone1.sh
#
# Checks:
#   1. the app launches and the SwiftUI window comes up
#   2. the deterministic local fixture loads inside the NSView-backed CEF browser
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
# Verification runs use their own browser data directory: Chromium encrypts
# stored cookies and passwords with a "Chromium Safe Storage" keychain item, so
# reusing a profile written by an earlier build makes macOS ask for keychain
# access on launch and blocks CEF's main thread until it is answered.
DATA_DIR="${DATA_DIR:-$REPO_ROOT/build/verification-data}"
WORK_DIR="$REPO_ROOT/build/verification"
PORT="${M1_FIXTURE_PORT:-43121}"
BASE_URL="http://127.0.0.1:$PORT"
HOME_URL="$BASE_URL/page-a"
# M1 verifies one-tab rendering/lifecycle, not workspace restore.
export NATIVEBROWSER_DISABLE_SESSION_PERSISTENCE=1

FAILURES=0
pass() { printf '  [pass] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
# Always pass the pattern with -e: a checked string may start with "-" and would
# otherwise be read as a grep option.
check_contains() {
  if grep -qF -e "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1 (missing: $2)"; fi
}

FIXTURE_PID=""
cleanup() {
  if [ -n "$FIXTURE_PID" ]; then
    kill "$FIXTURE_PID" 2>/dev/null || true
    wait "$FIXTURE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# Runs a command with a hard deadline so a CEF call blocked on an unanswered
# system dialog fails the run instead of hanging it.
# Runs a command with a hard deadline.
#
# The command is started in the foreground (through caffeinate, which is
# otherwise a no-op) rather than with "&": a GUI application launched into the
# background from a non-interactive shell is not guaranteed to be given a
# window by the window server, which made the application checks flaky. The
# deadline is enforced by a watchdog that kills the process group.
run_with_timeout() {
  local seconds="$1"
  shift
  local caffeinate=""
  if command -v caffeinate >/dev/null 2>&1; then
    caffeinate="caffeinate -i"
  fi
  $caffeinate "$@" &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$seconds" ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

if [ -n "${RESET_DATA_DIR:-}" ]; then
  rm -rf "$DATA_DIR"
fi
mkdir -p "$DATA_DIR" "$WORK_DIR"

if [ ! -x "$EXECUTABLE" ]; then
  echo "error: $EXECUTABLE not found; run Scripts/build.sh first" >&2
  exit 1
fi

echo "Milestone 1 verification"
echo "app: $APP"
echo

python3 "$REPO_ROOT/Scripts/milestone7_fixture_server.py" --port "$PORT" &
FIXTURE_PID=$!
FIXTURE_READY=0
for _ in $(seq 1 50); do
  if curl -fsS "$BASE_URL/healthz" >/dev/null 2>&1; then
    FIXTURE_READY=1
    break
  fi
  sleep 0.1
done
if [ "$FIXTURE_READY" -eq 1 ]; then
  pass "loopback fixture server started"
else
  fail "loopback fixture server started"
fi

# ---------------------------------------------------------------------------
echo "1-2. page load and resize (--browser-self-test)"
SELF_LOG="$WORK_DIR/self-test.log"
NATIVEBROWSER_DATA_DIR="$DATA_DIR" run_with_timeout 90 "$EXECUTABLE" \
  --browser-self-test --home-url="$HOME_URL" \
  > "$SELF_LOG" 2>&1
SELF_STATUS=$?
if [ "$SELF_STATUS" -eq 0 ]; then
  pass "self-test exited 0"
else
  fail "self-test exited with $SELF_STATUS"
fi
# A shutdown crash appears as a signal exit; markers alone would not catch it.
if [ "$SELF_STATUS" -gt 128 ]; then
  fail "self-test died from signal $((SELF_STATUS - 128))"
fi
check_contains "CEF initialized" "cef:initialized" "$SELF_LOG"
check_contains "Chromium browser created" "browser:created" "$SELF_LOG"
check_contains "local fixture reported its title and URL" \
  "browser:first-load-finished(title-present=true, url=$BASE_URL/<path>)" "$SELF_LOG"
check_contains "page load completed without a navigation error" "selftest:loaded=true" "$SELF_LOG"
check_contains "resize propagated to the container" "selftest:resized=900x620" "$SELF_LOG"
check_contains "the browser container reached the requested resize" \
  "browser-self-test: resized-container=900x620" "$SELF_LOG"
check_contains "browser destroyed before shutdown" "browser:closed" "$SELF_LOG"
check_contains "CEF shut down cleanly" "cef:shutdown(clean: true)" "$SELF_LOG"

# ---------------------------------------------------------------------------
echo
echo "1-3-5. application launch, navigation callbacks and clean termination"
GUI_LOG="$WORK_DIR/launch.log"
QUIT_AFTER=10
GUI_START=$(date +%s)
NATIVEBROWSER_DATA_DIR="$DATA_DIR" run_with_timeout $((QUIT_AFTER + 25)) "$EXECUTABLE" \
  --home-url="$HOME_URL" --quit-after=$QUIT_AFTER > "$GUI_LOG" 2>&1
GUI_STATUS=$?
GUI_TOTAL=$(( $(date +%s) - GUI_START ))
if [ "$GUI_STATUS" -eq 0 ]; then
  pass "app launched and terminated with exit 0"
else
  fail "app exited with $GUI_STATUS"
fi
if [ "$GUI_STATUS" -gt 128 ]; then
  fail "app died from signal $((GUI_STATUS - 128))"
fi
check_contains "SwiftUI window appeared" "swiftui:main-window-appeared" "$GUI_LOG"
check_contains "AppKit container view created" "appkit:chromium-container-created" "$GUI_LOG"
check_contains "Chromium browser created for the session" "browser:created" "$GUI_LOG"
check_contains "local fixture loaded in the running app" \
  "browser:first-load-finished(title-present=true, url=$BASE_URL/<path>)" "$GUI_LOG"
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

# A browser that reached OnBeforeClose is what "the browser was really
# destroyed" means. The direct self-test and the real application launch each
# exercise that typed CEF callback; neither infers destruction from a timer.
check_contains "the self-test reached typed OnBeforeClose" "[browser] OnBeforeClose" "$SELF_LOG"
check_contains "the application reached typed OnBeforeClose" "[browser] OnBeforeClose" "$GUI_LOG"

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
