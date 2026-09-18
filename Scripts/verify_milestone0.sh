#!/usr/bin/env bash
#
# Milestone 0 acceptance checks (ARCHITECTURE.md section 38).
#
#   Scripts/verify_milestone0.sh
#
# Checks, in order:
#   1. the app launches
#   2. the AppKit/SwiftUI boundary is live
#   3. CEF initializes and shuts down cleanly
#   4. the CEF framework is integrated into the build
#   5. the macOS helper applications are configured
#
# Exits non-zero when any check fails.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
APP="$REPO_ROOT/build/DerivedData/Build/Products/$CONFIGURATION/NativeBrowser.app"
EXECUTABLE="$APP/Contents/MacOS/NativeBrowser"
FRAMEWORKS="$APP/Contents/Frameworks"
# Verification runs use their own browser data directory: Chromium encrypts
# stored cookies and passwords with a "Chromium Safe Storage" keychain item, so
# reusing a profile written by an earlier build makes macOS ask for keychain
# access on launch and blocks CEF's main thread until it is answered.
DATA_DIR="${DATA_DIR:-$REPO_ROOT/build/verification-data}"
WORK_DIR="$REPO_ROOT/build/verification"

FAILURES=0
pass() { printf '  [pass] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
# Always pass the pattern with -e: a checked string may start with "-" and would
# otherwise be read as a grep option.
check_contains() {
  if grep -qF -e "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1 (missing: $2)"; fi
}

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

echo "Milestone 0 verification"
echo "app: $APP"
echo

# ---------------------------------------------------------------------------
echo "1-3. headless CEF lifecycle (--cef-self-test)"
SELF_TEST_LOG="$WORK_DIR/self-test.log"
NATIVEBROWSER_DATA_DIR="$DATA_DIR" run_with_timeout 60 "$EXECUTABLE" --cef-self-test \
  > "$SELF_TEST_LOG" 2>&1
SELF_TEST_STATUS=$?
if [ "$SELF_TEST_STATUS" -eq 0 ]; then
  pass "CEF initialized and shut down cleanly (exit 0)"
else
  fail "CEF self-test exited with $SELF_TEST_STATUS"
fi
check_contains "CEF reported initialization" "cef:initialized" "$SELF_TEST_LOG"
check_contains "CEF message loop was pumped" "cef:message-pump-started" "$SELF_TEST_LOG"
check_contains "CEF shut down cleanly" "cef:shutdown(clean: true)" "$SELF_TEST_LOG"

echo
# The window has to be allowed to come up before the app is asked to quit: the
# first launch into a fresh data directory spends a moment building the Chromium
# profile, and terminating before the SwiftUI window exists would test nothing.
LAUNCH_TIMEOUT=15
echo "1-2. application launch, AppKit/SwiftUI boundary and clean termination"
echo "     (waits for the window, then --quit-after=${LAUNCH_TIMEOUT})"
GUI_LOG="$WORK_DIR/launch.log"
rm -rf "$DATA_DIR/launch"
NATIVEBROWSER_DATA_DIR="$DATA_DIR/launch" run_with_timeout 60 "$EXECUTABLE" \
  --wait-for-window --quit-after=$LAUNCH_TIMEOUT > "$GUI_LOG" 2>&1
GUI_STATUS=$?
if [ "$GUI_STATUS" -eq 0 ]; then
  pass "application launched and terminated with exit 0"
else
  fail "application exited with $GUI_STATUS"
fi
check_contains "CEF initialized in the app" "cef:initialized" "$GUI_LOG"
check_contains "AppKit finished launching" "appkit:did-finish-launching" "$GUI_LOG"
check_contains "SwiftUI window appeared" "swiftui:main-window-appeared" "$GUI_LOG"
check_contains "AppKit container view created (SwiftUI -> AppKit)" "appkit:chromium-container-created" "$GUI_LOG"
check_contains "CEF message pump ran on the app run loop" "cef:message-pump-started" "$GUI_LOG"
check_contains "application termination reached the delegate" "appkit:will-terminate" "$GUI_LOG"
check_contains "CEF shut down cleanly during termination" "cef:shutdown(clean: true)" "$GUI_LOG"

# ---------------------------------------------------------------------------
echo
echo "4. CEF framework integration"
if [ -f "$FRAMEWORKS/Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework" ]; then
  pass "Chromium Embedded Framework.framework is embedded"
else
  fail "Chromium Embedded Framework.framework is missing from Contents/Frameworks"
fi
MAIN_LINKAGE="$(otool -L "$EXECUTABLE" 2>/dev/null)"
if [ -z "$MAIN_LINKAGE" ]; then
  fail "could not inspect the app's linked libraries"
elif printf '%s' "$MAIN_LINKAGE" | grep -q "Chromium Embedded Framework"; then
  fail "app links the CEF framework directly (must be loaded at runtime on macOS)"
else
  pass "app loads the CEF framework at runtime (not linked directly)"
fi
if [ -f "$DATA_DIR/Logs/cef.log" ]; then
  pass "CEF wrote its log file"
else
  fail "CEF log file was not created at $DATA_DIR/Logs/cef.log"
fi

# ---------------------------------------------------------------------------
echo
echo "5. helper applications"
for SUFFIX in "" " (Alerts)" " (GPU)" " (Plugin)" " (Renderer)"; do
  HELPER="$FRAMEWORKS/NativeBrowser Helper$SUFFIX.app"
  HELPER_EXE="$HELPER/Contents/MacOS/NativeBrowser Helper$SUFFIX"
  if [ -x "$HELPER_EXE" ]; then
    pass "NativeBrowser Helper$SUFFIX.app has its executable"
  else
    fail "NativeBrowser Helper$SUFFIX.app is missing Contents/MacOS/NativeBrowser Helper$SUFFIX"
    continue
  fi
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$HELPER/Contents/Info.plist" 2>/dev/null)"
  case "$BUNDLE_ID" in
    com.example.NativeBrowser.helper*) pass "bundle identifier $BUNDLE_ID" ;;
    *) fail "unexpected helper bundle identifier: $BUNDLE_ID" ;;
  esac
  # otool mishandles paths containing parentheses, so probe a copy.
  PROBE="$WORK_DIR/helper-probe"
  cp "$HELPER_EXE" "$PROBE"
  HELPER_LINKAGE="$(otool -L "$PROBE" 2>/dev/null)"
  rm -f "$PROBE"
  if [ -z "$HELPER_LINKAGE" ]; then
    fail "could not inspect NativeBrowser Helper$SUFFIX"
  elif printf '%s' "$HELPER_LINKAGE" | grep -q "Chromium Embedded Framework"; then
    fail "NativeBrowser Helper$SUFFIX links the framework directly"
  else
    pass "NativeBrowser Helper$SUFFIX loads the framework at runtime"
  fi
done

echo
echo "signature"
if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
  pass "app, framework and helpers have a valid signature"
else
  fail "code signature verification failed"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "Milestone 0: all checks passed"
else
  echo "Milestone 0: $FAILURES check(s) failed"
fi
exit $((FAILURES > 0 ? 1 : 0))
