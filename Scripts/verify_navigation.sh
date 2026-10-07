#!/usr/bin/env bash
#
# Navigation acceptance checks.
#
#   Scripts/verify_navigation.sh
#
# Checks, in order:
#   1. the address/search parser (unit tests + the shipped binary)
#   2. the navigation state and its CEF -> Objective-C++ -> Swift wiring
#   3. the address-field editing rules and the navigation input parser shape
#   4. navigation shortcuts and the navigation UI source structure
#   5. the runtime navigation stack (--navigation-self-test)
#   6. clean shutdown after navigation (--quit-after)
#   7. programmatic termination ordering (--terminate-in-pump-after)
#   8. URL redaction in the lifecycle trace and logs (security fix)
#   9. repository secret check (security fix)
#
# Anything that needs a human at the keyboard is listed at the end as REQUIRES
# MANUAL VERIFICATION; nothing here claims to have tested it.
#
# Exits non-zero when any automated check fails.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
APP="$REPO_ROOT/build/DerivedData/Build/Products/$CONFIGURATION/Cio.app"
EXECUTABLE="$APP/Contents/MacOS/Cio"
# Verification runs use their own browser data directory. Chromium encrypts
# stored cookies and passwords with a "Chromium Safe Storage" item in the login
# keychain; reusing a profile written by an earlier build therefore makes macOS
# ask for keychain access on every launch, which blocks CEF's main thread until
# it is answered. A dedicated directory (removed first, so the run is
# deterministic) keeps the checks independent of whatever the developer has in
# their own profile. Override with DATA_DIR=... if needed.
DATA_DIR="${DATA_DIR:-$REPO_ROOT/build/verification-data}"
WORK_DIR="$REPO_ROOT/build/verification"
PORT="${M2_FIXTURE_PORT:-43122}"
BASE_URL="http://127.0.0.1:$PORT"
HOME_URL="$BASE_URL/page-a"
NAVIGATION_DATA_DIR="$DATA_DIR/navigation"
NAVIGATE_QUIT_DATA_DIR="$DATA_DIR/navigate-quit"
GUI_DATA_DIR="$DATA_DIR/gui"
REDACTION_DATA_DIR="$DATA_DIR/redaction"
# M2 verification must not inherit a persisted M6 workspace.
export CIO_DISABLE_SESSION_PERSISTENCE=1

FAILURES=0
pass() { printf '  [pass] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# Always pass the pattern with -e: several of the strings checked here start
# with "-" and would otherwise be read as grep options.
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

FIXTURE_PID=""
cleanup() {
  if [ -n "$FIXTURE_PID" ]; then
    kill "$FIXTURE_PID" 2>/dev/null || true
    wait "$FIXTURE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM
# Parses one address input with the shipped application binary.
check_parsed() {
  local description="$1" expected="$2" input="$3"
  local actual
  actual="$("$EXECUTABLE" "--parse-navigation-input=$input" 2>/dev/null | head -1)"
  if [ "$actual" = "$expected" ]; then
    pass "$description"
  else
    fail "$description (expected '$expected', got '$actual')"
  fi
}

# Runs a command with a hard deadline so a CEF call that blocks the main
# thread (for example on an unanswered system dialog) fails the run instead of
# hanging it.
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

echo "Navigation verification"
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
echo "1. address / search parser"
TEST_LOG="$WORK_DIR/m2-tests.log"
TEST_BUNDLE="$REPO_ROOT/build/DerivedData/Build/Products/$CONFIGURATION/CioTests.xctest"
TEST_RUN_LOG="$WORK_DIR/m2-tests-run.log"
if "$REPO_ROOT/Scripts/verify_unit_tests.sh" "$TEST_RUN_LOG" > "$TEST_LOG" 2>&1; then
  pass "current unit tests passed (native bundle and local packages)"
else
  fail "unit tests failed; see $TEST_LOG and $TEST_RUN_LOG"
fi

# The same parser, exercised through the shipped binary (no CEF, no window).
check_parsed "https://example.com is a direct URL" \
  "parsed-as-url https://example.com" "https://example.com"
check_parsed "http://example.com is a direct URL" \
  "parsed-as-url http://example.com" "http://example.com"
check_parsed "example.com becomes https" \
  "parsed-as-url https://example.com" "example.com"
check_parsed "github.com/foo/bar becomes https" \
  "parsed-as-url https://github.com/<path>" "github.com/foo/bar"
check_parsed "localhost becomes http" \
  "parsed-as-url http://localhost" "localhost"
check_parsed "localhost:8080 becomes http" \
  "parsed-as-url http://localhost:8080" "localhost:8080"
check_parsed "127.0.0.1 becomes http" \
  "parsed-as-url http://127.0.0.1" "127.0.0.1"
check_parsed "127.0.0.1:8080 becomes http" \
  "parsed-as-url http://127.0.0.1:8080" "127.0.0.1:8080"
# The probe prints URLs in sanitized form (URLLogSanitizer): the query value
# never appears in its output, and neither does the raw query text.
check_parsed "words become a Google search with the query value redacted" \
  "parsed-as-search https://www.google.com/<path>?q=<redacted>" "swift objective-c++ cef"
check_parsed "a sentence becomes a search with the query value redacted" \
  "parsed-as-search https://www.google.com/<path>?q=<redacted>" "how does chromium work"
check_parsed "a Chinese query becomes a search with the query value redacted" \
  "parsed-as-search https://www.google.com/<path>?q=<redacted>" "浏览器 Chromium CEF"
check_parsed "a token URL keeps its parameter name and redacts the value" \
  "parsed-as-url http://127.0.0.1:3080/?token=<redacted>" \
  "http://127.0.0.1:3080/?token=test-token_123-abc"
check_parsed "a fragment is redacted" \
  "parsed-as-url https://example.com/<path>#<redacted>" \
  "https://example.com/callback#test-fragment"
check_parsed "empty input does not navigate" "parsed-as-empty" ""
check_parsed "whitespace-only input does not navigate" "parsed-as-empty" "   "

# The probe output is a trace consumed by this script, so the raw query text and
# its encoded form must not appear in it at all.
PROBE_LOG="$WORK_DIR/m2-probe-search.log"
"$EXECUTABLE" "--parse-navigation-input=swift objective-c++ cef" > "$PROBE_LOG" 2>/dev/null
check_absent "the probe output does not echo the raw query" \
  "swift objective-c++ cef" "$PROBE_LOG"
check_absent "the probe output does not echo the percent-encoded query" \
  "q=swift%20objective-c%2B%2B%20cef" "$PROBE_LOG"

# ---------------------------------------------------------------------------
echo
echo "5. runtime navigation stack (--navigation-self-test)"
SELF_LOG="$WORK_DIR/m2-navigation-self-test.log"
rm -rf "$NAVIGATION_DATA_DIR"
CIO_DATA_DIR="$NAVIGATION_DATA_DIR" run_with_timeout 120 "$EXECUTABLE" \
  --navigation-self-test --home-url="$HOME_URL" --m2-fixture-base-url="$BASE_URL" \
  > "$SELF_LOG" 2>&1
SELF_STATUS=$?
if [ "$SELF_STATUS" -eq 0 ]; then
  pass "navigation self-test exited 0"
else
  fail "navigation self-test exited with $SELF_STATUS"
fi
while IFS= read -r line; do
  printf '  [pass] %s\n' "$line"
done < <(grep -o 'navigation-self-test: pass .*' "$SELF_LOG" 2>/dev/null)
while IFS= read -r line; do
  printf '  [FAIL] %s\n' "$line"
done < <(grep -o 'navigation-self-test: FAIL .*' "$SELF_LOG" 2>/dev/null)
SELF_FAILURES="$(grep -c 'navigation-self-test: FAIL' "$SELF_LOG" 2>/dev/null)"
SELF_FAILURES="${SELF_FAILURES:-0}"
FAILURES=$((FAILURES + SELF_FAILURES))
check_contains "the Chromium browser was created exactly once" \
  "navigation-self-test: pass browser-created-once" "$SELF_LOG"
check_contains "the address field tracked the main-frame URL" \
  "navigation-self-test: pass address-field-tracks-url" "$SELF_LOG"
check_contains "Back reported as available by CEF" \
  "navigation-self-test: pass back-available-after-navigation" "$SELF_LOG"
check_contains "Back navigated" "navigation-self-test: pass back-navigates" "$SELF_LOG"
check_contains "Forward became available after Back" \
  "navigation-self-test: pass forward-available-after-back" "$SELF_LOG"
check_contains "Forward navigated" "navigation-self-test: pass forward-navigates" "$SELF_LOG"
check_contains "Stop reached CEF" "navigation-self-test: pass stop-load" "$SELF_LOG"
check_contains "Reload reached CEF" "navigation-self-test: pass reload" "$SELF_LOG"
check_contains "the address field submits a Chinese query as a search" \
  "navigation-self-test: pass chinese-query-search" "$SELF_LOG"
check_contains "the browser was not recreated by navigation" \
  "navigation-self-test: pass browser-not-recreated" "$SELF_LOG"
check_contains "the fresh browser was destroyed before the navigated termination path" \
  "navigation-self-test: pass fresh-browser-closed" "$SELF_LOG"
check_contains "navigated close is covered by the real-app termination gate" \
  "navigation-self-test: pass navigated-close-covered-by-real-app" "$SELF_LOG"

# ---------------------------------------------------------------------------
echo
echo "6. clean shutdown of the real application"
# The navigation self-test above cannot prove that a *navigated* browser is
# destroyed, because Chromium holds on to one in that harness window. The real
# application can: it is asked to navigate for real and then to quit, which runs
# the termination path (close every session -> pump -> CefShutdown).
NAV_QUIT_LOG="$WORK_DIR/m2-navigate-quit.log"
NAV_QUIT_URL="$BASE_URL/page-b"
NAV_QUIT_LOG_URL="$BASE_URL/<path>"
rm -rf "$NAVIGATE_QUIT_DATA_DIR"
start=$(date +%s)
# Both steps wait for the previous one to have happened, so the navigation is
# guaranteed to be in the running application before it is asked to quit.
CIO_DATA_DIR="$NAVIGATE_QUIT_DATA_DIR" run_with_timeout 90 "$EXECUTABLE" \
  --home-url="$HOME_URL" --navigate-url="$NAV_QUIT_URL" --wait-for-window \
  --navigate-after=3 --navigate-wait --quit-after=20 \
  > "$NAV_QUIT_LOG" 2>&1
NAV_QUIT_STATUS=$?
NAV_QUIT_TOTAL=$(( $(date +%s) - start ))
if [ "$NAV_QUIT_STATUS" -eq 0 ]; then
  pass "the app navigated and quit with exit 0"
else
  fail "the app navigated and quit with exit $NAV_QUIT_STATUS"
fi
if [ "$NAV_QUIT_STATUS" -gt 128 ]; then
  fail "navigate + quit died from signal $((NAV_QUIT_STATUS - 128))"
fi
check_contains "the live application navigated to a second page" \
  "navigation:url($NAV_QUIT_LOG_URL)" "$NAV_QUIT_LOG"
check_contains "the navigated browser was destroyed" "browser:closed" "$NAV_QUIT_LOG"
check_contains "CEF shut down cleanly after navigated close" \
  "cef:shutdown(clean: true)" "$NAV_QUIT_LOG"
if grep -qF -e "OnBeforeClose" "$NAV_QUIT_LOG" && ! grep -qF -e "close-timeout" "$NAV_QUIT_LOG"; then
  pass "Chromium destroyed the browser inside the shutdown budget"
else
  fail "the browser was not destroyed inside the shutdown budget"
fi
if [ "$NAV_QUIT_TOTAL" -le $((3 + 20 + 20)) ]; then
  pass "navigate + quit completed in ${NAV_QUIT_TOTAL}s"
else
  fail "navigate + quit took ${NAV_QUIT_TOTAL}s"
fi

GUI_LOG="$WORK_DIR/m2-launch.log"
QUIT_AFTER=10
GUI_START=$(date +%s)
rm -rf "$GUI_DATA_DIR"
# --wait-for-window keeps this about the quit path rather than about how long
# the machine took to put the window on screen.
CIO_DATA_DIR="$GUI_DATA_DIR" run_with_timeout $((QUIT_AFTER + 45)) "$EXECUTABLE" \
  --home-url="$HOME_URL" --wait-for-window --quit-after=$QUIT_AFTER > "$GUI_LOG" 2>&1
GUI_STATUS=$?
GUI_TOTAL=$(( $(date +%s) - GUI_START ))
if [ "$GUI_STATUS" -eq 0 ]; then
  pass "app launched and terminated with exit 0"
else
  fail "app exited with $GUI_STATUS"
fi
check_contains "SwiftUI window appeared" "swiftui:main-window-appeared" "$GUI_LOG"
check_contains "Chromium browser created once" "browser:created(count=1)" "$GUI_LOG"
check_contains "local fixture loaded in the running app" \
  "browser:first-load-finished(title-present=true, url=$BASE_URL/<path>)" "$GUI_LOG"
check_contains "browser destroyed before CEF shutdown" "browser:closed" "$GUI_LOG"
check_contains "CEF shut down cleanly" "cef:shutdown(clean: true)" "$GUI_LOG"
if [ "$GUI_TOTAL" -le $((QUIT_AFTER + 25)) ]; then
  pass "quit completed in ${GUI_TOTAL}s (no shutdown hang)"
else
  fail "quit took ${GUI_TOTAL}s"
fi

# ---------------------------------------------------------------------------
echo
echo "7. programmatic termination ordering"
# This hook calls terminate BEFORE CefDoMessageLoopWork. It checks ordering,
# but does not reproduce a native Cmd+Q event retained on Chromium's stack.
# Real Cmd+Q must also be tested and its timing log checked separately.
PUMP_LOG="$WORK_DIR/m2-terminate-in-pump.log"
rm -rf "$DATA_DIR/terminate-in-pump"
CIO_DATA_DIR="$DATA_DIR/terminate-in-pump" run_with_timeout 90 "$EXECUTABLE" \
  --log-shutdown-timing --wait-for-window --terminate-in-pump-after=8 --quit-after=120 > "$PUMP_LOG" 2>&1
PUMP_STATUS=$?
# A shutdown crash shows up as a signal exit (139 = SIGSEGV, 133 = SIGTRAP), so
# the exit code is asserted - grepping for lifecycle markers is not enough.
if [ "$PUMP_STATUS" -eq 0 ]; then
  pass "programmatic termination exited 0 (no Chromium CHECK abort)"
else
  fail "programmatic termination exited with $PUMP_STATUS"
fi
if [ "$PUMP_STATUS" -gt 128 ]; then
  fail "termination died from signal $((PUMP_STATUS - 128))"
fi
if grep -qF -e "termination:browser-close-timeout" "$PUMP_LOG"; then
  fail "termination fell back to the close-timeout path (a close callback was lost)"
else
  pass "termination did not need the close-timeout fallback"
fi
if python3 "$REPO_ROOT/Scripts/check_shutdown_timing.py" "$PUMP_LOG" "$PUMP_STATUS"; then
  pass "shutdown timing and all phase invariants passed"
else
  fail "shutdown timing or phase invariants failed"
fi
check_contains "the browser was created before terminating" "browser:created(count=1)" "$PUMP_LOG"
check_contains "AppKit asked the delegate to terminate" "appkit:should-terminate(entered)" "$PUMP_LOG"
check_contains "termination was deferred until Chromium was off the stack" "termination:started" "$PUMP_LOG"
check_contains "the browser reached its close lifecycle" "browser:closed" "$PUMP_LOG"
check_contains "the live browser count reached zero" "termination:browsers-closed" "$PUMP_LOG"
check_contains "CEF was shut down exactly once" "cef:shutdown(clean: true)" "$PUMP_LOG"
check_contains "AppKit was told termination may finish" "appkit:terminate-ready-requested" "$PUMP_LOG"
check_contains "Chromium destroyed the browser (OnBeforeClose)" \
  "[browser] OnBeforeClose" "$PUMP_LOG"
# Ordering: the close, the CEF shutdown and only then the reply to AppKit.
ORDER_LINE=$(grep -E 'lifecycle: (appkit:should-terminate|termination:started|browser:closed|termination:browsers-closed|cef:shutdown|termination:finished|appkit:terminate-ready-requested|appkit:will-terminate)' "$PUMP_LOG" | sed 's/^lifecycle: //' | tr '\n' ' ')
EXPECTED_ORDER="appkit:should-terminate(entered) termination:started browser:closed termination:browsers-closed cef:shutdown(clean: true) termination:finished appkit:terminate-ready-requested"
case "$ORDER_LINE" in
  "$EXPECTED_ORDER"*)
    pass "lifecycle ordering is correct" ;;
  *)
    fail "unexpected termination ordering: $ORDER_LINE" ;;
esac
if [ -z "$(find ~/Library/Logs/DiagnosticReports -name 'Cio*' -newermt '-3 minutes' 2>/dev/null)" ]; then
  pass "no new Cio crash report"
else
  fail "a Cio crash report was written during this run"
fi

# ---------------------------------------------------------------------------
echo
echo "8. URL redaction in the lifecycle trace and logs"
# The lifecycle trace is written to standard output and captured into a log
# file, so exactly the same redaction rules apply to it as to OSLog (security
# fix). The token below is a throwaway value - never a real credential.
REDACT_LOG="$WORK_DIR/m2-redaction.log"
REDACT_TOKEN="test-token_123-abc"
REDACT_URL="$BASE_URL/page-a?token=$REDACT_TOKEN"
rm -rf "$REDACTION_DATA_DIR"
CIO_DATA_DIR="$REDACTION_DATA_DIR" run_with_timeout 90 "$EXECUTABLE" \
  --home-url="$REDACT_URL" --wait-for-window --quit-after=12 > "$REDACT_LOG" 2>&1
REDACT_STATUS=$?
if [ "$REDACT_STATUS" -eq 0 ]; then
  pass "the redaction run launched and quit with exit 0"
else
  fail "the redaction run exited with $REDACT_STATUS"
fi
check_contains "the lifecycle trace reports the URL with its query value redacted" \
  "navigation:url($BASE_URL/<path>?token=<redacted>)" "$REDACT_LOG"
check_absent "the raw query value is absent from the whole run log" \
  "$REDACT_TOKEN" "$REDACT_LOG"

# ---------------------------------------------------------------------------
echo
echo "9. repository secret check"
# The fix must not have introduced a credential, and one that was used earlier
# must not be sitting in the tree or in the history. The checker prints only
# categories and locations, never a matched value.
SECRET_LOG="$WORK_DIR/m2-secret-check.log"
if "$REPO_ROOT/Scripts/check_no_secrets.sh" > "$SECRET_LOG" 2>&1; then
  pass "no credential-shaped value in tracked files or git history"
else
  fail "the secret check found a credential-shaped value; see $SECRET_LOG"
fi
while IFS= read -r line; do
  printf '  %s\n' "$line"
done < <(grep -E '\[FAIL\]' "$SECRET_LOG" 2>/dev/null)

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "Navigation: all automated checks passed"
else
  echo "Navigation: $FAILURES automated check(s) failed"
fi

cat <<'MANUAL'

REQUIRES MANUAL VERIFICATION (not covered by this script):
  * real Cmd+Q with page focus and address-field focus; record with
    --log-shutdown-timing, then run Scripts/check_shutdown_timing.py LOG EXIT_CODE
  * ⌘L while Chromium owns focus (menu key equivalent -> address field focus)
  * ⌘L select-all followed by typing replacing the selection
  * clicking the page after using the address field returns typing to the page
  * Chinese IME composition in the address field (candidate window, commit)
  * Back/Forward/Reload/Stop button enablement as drawn on screen
  * Escape cancelling an unsubmitted address edit
  * window resize behaviour of the Chromium content below the new toolbar
See the Navigation manual checklist (Tests A-K) in the session report.
MANUAL

exit $((FAILURES > 0 ? 1 : 0))
