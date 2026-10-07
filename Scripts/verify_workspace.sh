#!/usr/bin/env bash
#
# Workspace acceptance checks: Spaces.
#
#   Scripts/verify_workspace.sh
#
# Checks, in order:
#   1. the CEF-free workspace model (unit tests)
#   2. domain/runtime ownership and stable-surface structure
#   3. the real multi-Space CEF application (--spaces-self-test)
#   4. shutdown ordering and URL-redaction invariants
#
# The real self-test is deliberately bounded by this script's watchdog. The
# application itself has no shutdown timeout fallback: CefShutdown is reached
# only after every live session reports typed OnBeforeClose.
#
# Exits non-zero when any automated check fails. Keyboard/menu polish and visual
# layout remain listed as manual checks at the end.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
APP="$REPO_ROOT/build/DerivedData/Build/Products/$CONFIGURATION/Cio.app"
EXECUTABLE="$APP/Contents/MacOS/Cio"
DATA_DIR="${DATA_DIR:-$REPO_ROOT/build/verification-data}"
WORK_DIR="$REPO_ROOT/build/verification"
# M4 verifies in-memory Spaces and CEF lifecycle; do not load/save M6 state.
export CIO_DISABLE_SESSION_PERSISTENCE=1

FAILURES=0
pass() { printf '  [pass] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

check_contains() {
  if grep -qF -e "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1 (missing: $2)"; fi
}

check_absent() {
  if grep -qF -e "$2" "$3" 2>/dev/null; then fail "$1 (found: $2)"; else pass "$1"; fi
}

check_file_contains() {
  if [ ! -f "$2" ]; then fail "$1 (missing file: $2)"; return; fi
  check_contains "$1" "$3" "$2"
}

check_file_absent() {
  if [ ! -f "$3" ]; then fail "$1 (missing file: $3)"; return; fi
  check_absent "$1" "$2" "$3"
}

# Keep a hung CEF callback from hanging the verification shell forever. This is
# an external test watchdog, not a production shutdown policy.
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

echo "Workspace verification"
echo "app: $APP"
echo

# ---------------------------------------------------------------------------
echo
echo "3. real multi-Space CEF self-test"
SELF_LOG="$WORK_DIR/m4-spaces-self-test.log"
rm -rf "$DATA_DIR/spaces-self-test"
REDACT_TOKEN="m4-test-token_123-abc"
HOME_URL="https://example.com/?token=$REDACT_TOKEN"
CIO_DATA_DIR="$DATA_DIR/spaces-self-test" run_with_timeout 600 "$EXECUTABLE" \
  -ApplePersistenceIgnoreState YES \
  --spaces-self-test --home-url="$HOME_URL" > "$SELF_LOG" 2>&1
SELF_STATUS=$?
if python3 "$REPO_ROOT/Scripts/check_workspace_report.py" "$SELF_LOG" "$SELF_STATUS"; then
  pass "current workspace/runtime invariants passed"
else
  fail "workspace/runtime verification failed"
fi

# ---------------------------------------------------------------------------
echo
echo "4. redaction and manual checks"
check_contains "sanitized query shape is observable" \
  "navigation:url(https://example.com/?token=<redacted>)" "$SELF_LOG"
check_absent "raw test token is absent from the self-test log" "$REDACT_TOKEN" "$SELF_LOG"

echo
echo "REQUIRES MANUAL VERIFICATION"
echo "  - click between Spaces and confirm the one visible Chromium surface follows selection"
echo "  - type into the address field, switch Spaces, and confirm text/focus are preserved"
echo "  - use Cmd-T/Cmd-W/Cmd-Shift-T and Cmd-1…Cmd-9 in multiple Spaces"
echo "  - rename a Space and confirm empty names are rejected"
echo "  - open a real target=_blank popup from an inactive Space and inspect its destination"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "Workspace: all automated checks passed"
else
  echo "Workspace: $FAILURES check(s) failed"
fi
exit $((FAILURES > 0 ? 1 : 0))
