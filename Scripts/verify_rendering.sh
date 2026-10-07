#!/usr/bin/env bash
#
# Rendering acceptance checks.
#
#   Scripts/verify_rendering.sh
#
# Checks:
#   1. the app launches and the SwiftUI window comes up
#   2. the deterministic local fixture loads inside the NSView-backed CEF browser
#   3. the page title and URL callbacks reach the application
# Window resizing remains a manual content-bounds check.
#   5. the browser is destroyed before CEF shuts down, and quitting is clean
#
# Exits non-zero when any check fails.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
APP="$REPO_ROOT/build/DerivedData/Build/Products/$CONFIGURATION/Cio.app"
EXECUTABLE="$APP/Contents/MacOS/Cio"
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
export CIO_DISABLE_SESSION_PERSISTENCE=1

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
# Rendering is stateless. Keep each launch isolated from profiles left by other
# acceptance drivers; preserve the profile for inspection under build/.
PROFILE_DIR="$(mktemp -d "$DATA_DIR/rendering.XXXXXX")"

if [ ! -x "$EXECUTABLE" ]; then
  echo "error: $EXECUTABLE not found; run Scripts/build.sh first" >&2
  exit 1
fi

echo "Rendering verification"
echo "app: $APP"
echo

python3 "$REPO_ROOT/Scripts/verification_fixture_server.py" --port "$PORT" &
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
echo
echo "Rendering, navigation callbacks and real application termination"
GUI_LOG="$WORK_DIR/launch.log"
QUIT_AFTER=10
GUI_START=$(date +%s)
CIO_DATA_DIR="$PROFILE_DIR" run_with_timeout $((QUIT_AFTER + 25)) "$EXECUTABLE" \
  -ApplePersistenceIgnoreState YES \
  --log-shutdown-timing --home-url="$HOME_URL" --quit-after=$QUIT_AFTER > "$GUI_LOG" 2>&1
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

# Measure the existing termination phases, not startup plus the residence timer.
# Keep the original six-second shutdown budget; the process watchdog still bounds
# the full launch. App/module initialization time is not a shutdown duration.
if python3 "$REPO_ROOT/Scripts/check_shutdown_timing.py" "$GUI_LOG" "$GUI_STATUS" 6000; then
  pass "quit phase timing/order passed (total launch ${GUI_TOTAL}s)"
else
  fail "shutdown timing/order verification failed"
fi

# A typed OnBeforeClose callback proves the real application released its browser.
check_contains "the application reached typed OnBeforeClose" "[browser] OnBeforeClose" "$GUI_LOG"

# ---------------------------------------------------------------------------
echo
echo "signature and runtime"
if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
  pass "app, framework and helpers have a valid signature"
else
  fail "code signature verification failed"
fi
if [ -f "$PROFILE_DIR/Logs/cef.log" ]; then
  pass "CEF wrote its log file"
else
  fail "CEF log file was not created"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "Rendering: all checks passed"
else
  echo "Rendering: $FAILURES check(s) failed"
fi
echo "REQUIRES MANUAL VERIFICATION: resize the window and inspect Chromium content bounds"
exit $((FAILURES > 0 ? 1 : 0))
