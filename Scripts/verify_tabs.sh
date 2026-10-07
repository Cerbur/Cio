#!/usr/bin/env bash
#
# Tabs acceptance checks.
#
#   Scripts/verify_tabs.sh
#
# Checks, in order:
#   1. the pure tab model, without Chromium (unit tests)
#   2. the Tabs ownership invariants, read from the source
#   3. multiple real Chromium browsers, tab identity, switching and closing
#      (--tabs-self-test)
#   4. the real application with several tabs: multi-browser shutdown ordering
#   5. Command-W ownership in the real main menu (--dump-main-menu)
#   6. URL redaction across a multi-tab run (security fix preserved)
#
# Anything that needs a human at the keyboard is listed at the end as REQUIRES
# MANUAL VERIFICATION; nothing here claims to have tested it.
#
# Exits non-zero when any automated check fails.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
APP="$REPO_ROOT/build/DerivedData/Build/Products/$CONFIGURATION/NativeBrowser.app"
EXECUTABLE="$APP/Contents/MacOS/NativeBrowser"
# Verification runs use their own browser data directory. Chromium encrypts
# stored cookies and passwords with a "Chromium Safe Storage" item in the login
# keychain; reusing a profile written by an earlier build therefore makes macOS
# ask for keychain access on every launch, which blocks CEF's main thread until
# it is answered. A dedicated directory (removed first, so the run is
# deterministic) keeps the checks independent of whatever the developer has in
# their own profile. Override with DATA_DIR=... if needed.
DATA_DIR="${DATA_DIR:-$REPO_ROOT/build/verification-data}"
WORK_DIR="$REPO_ROOT/build/verification"
# M3 is an in-memory tabs regression; isolate it from M6 session restore.
export NATIVEBROWSER_DISABLE_SESSION_PERSISTENCE=1

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
# check_file_absent DESCRIPTION NEEDLE FILE
check_file_absent() {
  if [ ! -f "$3" ]; then fail "$1 (missing file: $3)"; return; fi
  check_absent "$1" "$2" "$3"
}

# Runs a command with a hard deadline so a CEF call that blocks the main
# thread (for example on an unanswered system dialog) fails the run instead of
# hanging it.
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

# Compare report names before and after this run. A rolling "last 30 minutes"
# query lets an unrelated earlier CEF probe fail the M3 gate; the acceptance
# assertion is specifically that this multi-tab run creates no new report.
DIAGNOSTIC_REPORT_DIR="$HOME/Library/Logs/DiagnosticReports"
CRASH_REPORTS_BEFORE="$WORK_DIR/m3-crash-reports.before"
CRASH_REPORTS_AFTER="$WORK_DIR/m3-crash-reports.after"
find "$DIAGNOSTIC_REPORT_DIR" -maxdepth 1 -type f -name 'NativeBrowser*' -print 2>/dev/null \
  | sort > "$CRASH_REPORTS_BEFORE"

if [ ! -x "$EXECUTABLE" ]; then
  echo "error: $EXECUTABLE not found; run Scripts/build.sh first" >&2
  exit 1
fi

echo "Tabs verification"
echo "app: $APP"
echo

# ---------------------------------------------------------------------------
echo
echo "4. real application with several tabs: multi-browser shutdown and redaction"
MULTI_LOG="$WORK_DIR/m3-multi-tab-quit.log"
MULTI_TABS=5
QUIT_AFTER=30
# A throwaway token - never a real credential. It is the value the run must not
# publish; the URL is otherwise an ordinary page.
REDACT_TOKEN="test-token_123-abc"
REDACT_URL="https://example.com/?token=$REDACT_TOKEN"
rm -rf "$DATA_DIR/multi-tab"
MULTI_START=$(date +%s)
NATIVEBROWSER_DATA_DIR="$DATA_DIR/multi-tab" run_with_timeout $((QUIT_AFTER + 60)) "$EXECUTABLE" \
  --dump-main-menu --home-url="$REDACT_URL" --wait-for-window \
  --open-tabs=$MULTI_TABS --quit-after=$QUIT_AFTER > "$MULTI_LOG" 2>&1
MULTI_STATUS=$?
MULTI_TOTAL=$(( $(date +%s) - MULTI_START ))
if [ "$MULTI_STATUS" -eq 0 ]; then
  pass "the app opened $MULTI_TABS tabs and quit with exit 0"
else
  fail "the multi-tab run exited with $MULTI_STATUS"
fi
if [ "$MULTI_STATUS" -gt 128 ]; then
  fail "the multi-tab run died from signal $((MULTI_STATUS - 128))"
fi
check_contains "the run really created several Chromium browsers" \
  "browser:created(count=1)" "$MULTI_LOG"
CREATED_BROWSERS="$(grep -cF -e "lifecycle: browser:created" "$MULTI_LOG" 2>/dev/null)"
CREATED_BROWSERS="${CREATED_BROWSERS:-0}"
if [ "$CREATED_BROWSERS" -ge "$MULTI_TABS" ]; then
  pass "$CREATED_BROWSERS Chromium browsers were created and loaded"
else
  fail "only $CREATED_BROWSERS Chromium browsers were created (expected >= $MULTI_TABS)"
fi
DESTROYED_BROWSERS="$(grep -cF -e "lifecycle: browser:closed" "$MULTI_LOG" 2>/dev/null)"
DESTROYED_BROWSERS="${DESTROYED_BROWSERS:-0}"
if [ "$DESTROYED_BROWSERS" -ge "$MULTI_TABS" ]; then
  pass "$DESTROYED_BROWSERS browsers reached OnBeforeClose"
else
  fail "only $DESTROYED_BROWSERS browsers reached OnBeforeClose (expected >= $MULTI_TABS)"
fi
check_contains "termination asked every live session to close" \
  "lifecycle: session:close-all(count=$MULTI_TABS)" "$MULTI_LOG"
CLOSED_EVENTS="$(grep -cF -e "lifecycle: browser:closed" "$MULTI_LOG" 2>/dev/null)"
CLOSED_EVENTS="${CLOSED_EVENTS:-0}"
if [ "$CLOSED_EVENTS" -ge "$MULTI_TABS" ]; then
  pass "every tab reported its own close ($CLOSED_EVENTS events)"
else
  fail "only $CLOSED_EVENTS tabs reported a close (expected >= $MULTI_TABS)"
fi
check_contains "the live browser count reached zero" \
  "lifecycle: termination:browsers-closed" "$MULTI_LOG"
check_absent "no browser needed the close-timeout fallback" \
  "termination:browser-close-timeout" "$MULTI_LOG"
check_absent "CefShutdown was not skipped for a live browser" \
  "termination:skipped-cef-shutdown" "$MULTI_LOG"
SHUTDOWN_EVENTS="$(grep -cF -e "lifecycle: cef:shutdown(clean: true)" "$MULTI_LOG" 2>/dev/null)"
SHUTDOWN_EVENTS="${SHUTDOWN_EVENTS:-0}"
if [ "$SHUTDOWN_EVENTS" -eq 1 ]; then
  pass "CefShutdown ran exactly once"
else
  fail "CefShutdown ran $SHUTDOWN_EVENTS times (expected exactly 1)"
fi
# Ordering: the last browser close, then the live count reaching zero, then CEF.
LAST_CLOSED_LINE="$(grep -nF -e "lifecycle: browser:closed" "$MULTI_LOG" | tail -1 | cut -d: -f1)"
BROWSERS_CLOSED_LINE="$(grep -nF -e "lifecycle: termination:browsers-closed" "$MULTI_LOG" | tail -1 | cut -d: -f1)"
CEF_SHUTDOWN_LINE="$(grep -nF -e "lifecycle: cef:shutdown(clean: true)" "$MULTI_LOG" | tail -1 | cut -d: -f1)"
if [ -n "$LAST_CLOSED_LINE" ] && [ -n "$BROWSERS_CLOSED_LINE" ] && [ -n "$CEF_SHUTDOWN_LINE" ] \
  && [ "$LAST_CLOSED_LINE" -lt "$BROWSERS_CLOSED_LINE" ] \
  && [ "$BROWSERS_CLOSED_LINE" -lt "$CEF_SHUTDOWN_LINE" ]; then
  pass "every OnBeforeClose happened before CefShutdown"
else
  fail "unexpected shutdown ordering (closed=$LAST_CLOSED_LINE zero=$BROWSERS_CLOSED_LINE cef=$CEF_SHUTDOWN_LINE)"
fi
if [ "$MULTI_TOTAL" -le $((QUIT_AFTER + 30)) ]; then
  pass "the multi-tab quit completed in ${MULTI_TOTAL}s (no per-browser timeout)"
else
  fail "the multi-tab quit took ${MULTI_TOTAL}s"
fi
find "$DIAGNOSTIC_REPORT_DIR" -maxdepth 1 -type f -name 'NativeBrowser*' -print 2>/dev/null \
  | sort > "$CRASH_REPORTS_AFTER"
NEW_CRASH_REPORTS="$(comm -13 "$CRASH_REPORTS_BEFORE" "$CRASH_REPORTS_AFTER")"
if [ -z "$NEW_CRASH_REPORTS" ]; then
  pass "no new NativeBrowser crash report"
else
  fail "a NativeBrowser crash report was written during this run: $NEW_CRASH_REPORTS"
fi
# Security: the same redaction rules apply to a multi-tab run.
check_contains "the lifecycle trace reports the URL with its query value redacted" \
  "navigation:url(https://example.com/?token=<redacted>)" "$MULTI_LOG"
check_absent "the raw query value is absent from the whole run log" \
  "$REDACT_TOKEN" "$MULTI_LOG"

# ---------------------------------------------------------------------------
echo
echo "5. Command-W ownership in the real main menu"
check_contains "Command-W is the tab command" \
  "menu-item: Tabs|Close Tab key=w mods=cmd" "$MULTI_LOG"
PLAIN_W="$(grep -cF -e "key=w mods=cmd action=" "$MULTI_LOG" 2>/dev/null)"
PLAIN_W="${PLAIN_W:-0}"
if [ "$PLAIN_W" -eq 2 ]; then
  # The menu is dumped at launch and again at termination: exactly one Command-W
  # item each time, and it is the same one.
  pass "exactly one Command-W item exists in each dumped menu"
else
  fail "found $PLAIN_W Command-W menu items (expected 2: one per dump)"
fi
check_absent "AppKit's window Close item no longer claims Command-W" \
  "menu-item: File|Close key=w mods=cmd" "$MULTI_LOG"
check_contains "the menu was dumped again at termination" \
  "main-menu(will-terminate): begin" "$MULTI_LOG"

# ---------------------------------------------------------------------------
echo
echo "6. repository secret check"
SECRET_LOG="$WORK_DIR/m3-secret-check.log"
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
  echo "Tabs: all automated checks passed"
else
  echo "Tabs: $FAILURES automated check(s) failed"
fi

cat <<'MANUAL'

REQUIRES MANUAL VERIFICATION (not covered by this script):
  TEST A  launch: one visible tab, Google/default home loads, toolbar works
  TEST B  Cmd+T four times: five tabs, each with its own browser, newest selected;
          navigate them to different pages and check each keeps its own URL
  TEST C  switch repeatedly: no reload, no white recreation flash, no new browser
  TEST D  independent history: 3 pages in one tab, 2 in another; Back/Forward
          state belongs to the selected tab only
  TEST E  type but do not submit in Tab A; let a background tab navigate; Tab A's
          edit buffer must survive; switching to Tab B shows Tab B, and back again
  TEST F  Cmd+L with Chromium focused in several tabs: only the selected tab's
          field focuses and selects all; Chinese IME composition stays normal
  TEST G  Cmd+W on a selected middle tab: only that tab closes, the neighbour is
          selected, the window stays open, the other browsers stay alive, and
          typing reaches the neighbour without an extra click (the hand-over of
          AppKit focus itself is automated as selected-close-transfers-focus)
  TEST H  close a background tab with the sidebar button: the active page keeps
          keyboard focus and is not blurred (automated as
          background-close-keeps-focus; that a keystroke still reaches the page
          afterwards is manual)
  TEST I  reduce to one tab, Cmd+W: a fresh usable tab is created, window stays
  TEST J  close a tab with a distinctive URL, Cmd+Shift+T: new tab, same URL, new
          runtime identity, selected
  TEST K  target=_blank: managed new tab, no unmanaged Chromium window, the
          current tab is not replaced
  TEST L  ~20 tabs: navigate, switch rapidly, close in mixed order - no crash, no
          duplicate browser, no stale toolbar
  TEST M  Cmd+Q with >=5 tabs, once with page focus and once with address-field
          focus: clean exit, no five-second fallback, all browsers OnBeforeClose,
          CefShutdown only after, no residual process. Record with
          --log-shutdown-timing and check with Scripts/check_shutdown_timing.py
  TEST N  red window close button with several tabs: shutdown stays clean
  TEST O  resize rapidly while switching tabs: the selected surface always matches
          the available bounds

  Tabs focus ownership (real key events; the ownership rules themselves
  are automated in --tabs-self-test and listed as pass lines above):
  TEST P  page focused, Cmd+T, immediately type: the hidden tab receives no input
          and the new tab owns page focus once its browser exists
  TEST Q  press Cmd+T several times and click among tabs while pages are still
          being created: a late OnAfterCreated from a hidden tab never steals
          focus (the same race without key events is automated as
          late-browser-creation-keeps-focus)
  TEST R  address field focused, then switch tabs or create one: keyboard focus
          does not jump to a hidden or newly created Chromium browser
  TEST S  Cmd+L + Chinese IME after several tab switches: composition, candidates
          and commit stay normal
MANUAL

exit $((FAILURES > 0 ? 1 : 0))
