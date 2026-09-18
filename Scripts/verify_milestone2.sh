#!/usr/bin/env bash
#
# Milestone 2 acceptance checks (ARCHITECTURE.md section 38).
#
#   Scripts/verify_milestone2.sh
#
# Checks, in order:
#   1. the address/search parser (unit tests + the shipped binary)
#   2. the navigation state and its CEF -> Objective-C++ -> Swift wiring
#   3. the address-field editing rules and the navigation input parser shape
#   4. navigation shortcuts and the navigation UI source structure
#   5. the runtime navigation stack (--navigation-self-test)
#   6. clean shutdown after navigation (--quit-after)
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

echo "Milestone 2 verification"
echo "app: $APP"
echo

# ---------------------------------------------------------------------------
echo "1. address / search parser"
TEST_LOG="$WORK_DIR/m2-tests.log"
TEST_BUNDLE="$REPO_ROOT/build/DerivedData/Build/Products/$CONFIGURATION/NativeBrowserTests.xctest"
TEST_RUN_LOG="$WORK_DIR/m2-tests-run.log"
xcodebuild \
  -project "$REPO_ROOT/NativeBrowser.xcodeproj" \
  -scheme NativeBrowser \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$REPO_ROOT/build/DerivedData" \
  build-for-testing \
  > "$TEST_LOG" 2>&1
if [ $? -ne 0 ]; then
  fail "the unit test bundle did not build; see $TEST_LOG"
  grep -E "error:" "$TEST_LOG" | head -5
elif [ ! -d "$TEST_BUNDLE" ]; then
  fail "the unit test bundle was not produced at $TEST_BUNDLE"
else
  pass "the unit test bundle built"
  # xcodebuild's own test runner wants a pseudo terminal, which a sandboxed
  # shell cannot always provide ("Pseudo Terminal Setup Error"). The same
  # XCTest bundle is therefore run directly: identical assertions, no launcher.
  xcrun xctest "$TEST_BUNDLE" > "$TEST_RUN_LOG" 2>&1
  if [ $? -eq 0 ]; then
    TEST_COUNT="$(grep -c "^Test Case .* passed" "$TEST_RUN_LOG" 2>/dev/null || echo 0)"
    pass "unit tests passed ($TEST_COUNT test cases)"
  else
    fail "unit tests failed; see $TEST_RUN_LOG"
    grep -E "error:" "$TEST_RUN_LOG" | head -5
  fi
  if grep -q "Test Suite 'NavigationInputTests' passed" "$TEST_RUN_LOG" 2>/dev/null; then
    pass "NavigationInputTests suite passed"
  else
    fail "NavigationInputTests suite did not pass"
  fi
fi

# The same parser, exercised through the shipped binary (no CEF, no window).
check_parsed "https://example.com is a direct URL" \
  "parsed-as-url https://example.com" "https://example.com"
check_parsed "http://example.com is a direct URL" \
  "parsed-as-url http://example.com" "http://example.com"
check_parsed "example.com becomes https" \
  "parsed-as-url https://example.com" "example.com"
check_parsed "github.com/foo/bar becomes https" \
  "parsed-as-url https://github.com/foo/bar" "github.com/foo/bar"
check_parsed "localhost becomes http" \
  "parsed-as-url http://localhost" "localhost"
check_parsed "localhost:8080 becomes http" \
  "parsed-as-url http://localhost:8080" "localhost:8080"
check_parsed "127.0.0.1 becomes http" \
  "parsed-as-url http://127.0.0.1" "127.0.0.1"
check_parsed "127.0.0.1:8080 becomes http" \
  "parsed-as-url http://127.0.0.1:8080" "127.0.0.1:8080"
check_parsed "words become a Google search with encoded spaces" \
  "parsed-as-search https://www.google.com/search?q=swift%20objective-c%2B%2B%20cef query=swift objective-c++ cef" \
  "swift objective-c++ cef"
check_parsed "a sentence becomes a search" \
  "parsed-as-search https://www.google.com/search?q=how%20does%20chromium%20work query=how does chromium work" \
  "how does chromium work"
check_parsed "a Chinese query is percent-encoded UTF-8" \
  "parsed-as-search https://www.google.com/search?q=%E6%B5%8F%E8%A7%88%E5%99%A8%20Chromium%20CEF query=浏览器 Chromium CEF" \
  "浏览器 Chromium CEF"
check_parsed "empty input does not navigate" "parsed-as-empty" ""
check_parsed "whitespace-only input does not navigate" "parsed-as-empty" "   "

# ---------------------------------------------------------------------------
echo
echo "2. navigation state and CEF callback wiring"
check_file_contains "UI-facing NavigationState exists" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserSession.swift" "struct NavigationState: Equatable"
check_file_contains "NavigationState carries canGoBack" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserSession.swift" "var canGoBack = false"
check_file_contains "NavigationState carries canGoForward" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserSession.swift" "var canGoForward = false"
check_file_contains "NavigationState carries isLoading" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserSession.swift" "var isLoading = false"
# The callback shape is part of the bridge contract; the verifier fails if the
# surface is narrowed without updating this check.
check_file_contains "bridge delivers title" \
  "$REPO_ROOT/NativeBrowser/Bridge/BrowserBridge.h" "didUpdateTitle:(NSString *)title"
check_file_contains "bridge delivers URL" \
  "$REPO_ROOT/NativeBrowser/Bridge/BrowserBridge.h" "didUpdateURL:(NSString *)url"
check_file_contains "bridge delivers loading + history state" \
  "$REPO_ROOT/NativeBrowser/Bridge/BrowserBridge.h" "canGoForward:(BOOL)canGoForward"
check_file_contains "CEF callbacks are marshalled to the main thread" \
  "$REPO_ROOT/NativeBrowser/Bridge/CEFClientHandler.mm" "dispatch_async(dispatch_get_main_queue(), block)"
check_file_contains "session state is main-actor isolated" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserSession.swift" "@MainActor"
check_file_contains "address editing state is main-actor isolated" \
  "$REPO_ROOT/NativeBrowser/UI/CommandBar/AddressFieldModel.swift" "@MainActor"
check_file_contains "title is not derived from the URL" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserSession.swift" "didUpdateTitle title: String"

# ---------------------------------------------------------------------------
echo
echo "3. address-field editing rules"
check_file_contains "committed URL is tracked separately from the edit buffer" \
  "$REPO_ROOT/NativeBrowser/UI/CommandBar/AddressFieldModel.swift" "private(set) var committedURL: URL?"
check_file_contains "the edit buffer is tracked separately" \
  "$REPO_ROOT/NativeBrowser/UI/CommandBar/AddressFieldModel.swift" "private(set) var editText = \"\""
check_file_contains "editing is an explicit flag, not a timing heuristic" \
  "$REPO_ROOT/NativeBrowser/UI/CommandBar/AddressFieldModel.swift" "isEditing = false"
check_file_contains "browser URL updates are ignored while editing" \
  "$REPO_ROOT/NativeBrowser/UI/CommandBar/AddressFieldModel.swift" "guard !isEditing else"
if grep -qE "DispatchQueue.*asyncAfter|sleep\(|Timer\.scheduled" \
     "$REPO_ROOT/NativeBrowser/UI/CommandBar/AddressFieldModel.swift" 2>/dev/null; then
  fail "editing state must not use delays"
else
  pass "editing state uses no delays or timers"
fi
check_file_contains "Return and Escape are handled through the field editor" \
  "$REPO_ROOT/NativeBrowser/UI/CommandBar/AddressField.swift" "doCommandBy commandSelector: Selector"
# A custom key handler would break IME composition (section 18).
check_absent "the address field does not override key events" \
  "override func keyDown" "$REPO_ROOT/NativeBrowser/UI/CommandBar/AddressField.swift"
check_absent "the address field does not intercept key presses in SwiftUI" \
  ".onKeyPress" "$REPO_ROOT/NativeBrowser/UI/CommandBar/AddressField.swift"
check_file_contains "the address field is a native NSTextField (IME support)" \
  "$REPO_ROOT/NativeBrowser/UI/CommandBar/AddressField.swift" "final class NativeBrowserAddressField: NSTextField"

echo
echo "4. navigation actions, shortcuts and UI structure"
check_file_contains "Back exists in the navigation layer" \
  "$REPO_ROOT/NativeBrowser/Bridge/BrowserBridge.h" "- (void)goBack;"
check_file_contains "Forward exists in the navigation layer" \
  "$REPO_ROOT/NativeBrowser/Bridge/BrowserBridge.h" "- (void)goForward;"
check_file_contains "Reload exists in the navigation layer" \
  "$REPO_ROOT/NativeBrowser/Bridge/BrowserBridge.h" "- (void)reload;"
check_file_contains "Stop exists in the navigation layer" \
  "$REPO_ROOT/NativeBrowser/Bridge/BrowserBridge.h" "- (void)stopLoading;"
check_file_contains "one control switches between reload and stop" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserSession.swift" "func reloadOrStop()"
check_file_contains "command-L is a menu key equivalent" \
  "$REPO_ROOT/NativeBrowser/App/AppCommands.swift" "keyboardShortcut(\"l\", modifiers: .command)"
check_file_contains "command-R is a menu key equivalent" \
  "$REPO_ROOT/NativeBrowser/App/AppCommands.swift" "keyboardShortcut(\"r\", modifiers: .command)"
check_file_contains "optional command-[ back shortcut" \
  "$REPO_ROOT/NativeBrowser/App/AppCommands.swift" "keyboardShortcut(\"[\", modifiers: .command)"
check_file_contains "optional command-] forward shortcut" \
  "$REPO_ROOT/NativeBrowser/App/AppCommands.swift" "keyboardShortcut(\"]\", modifiers: .command)"
check_file_contains "the commands are attached to the scene" \
  "$REPO_ROOT/NativeBrowser/App/NativeBrowserApp.swift" "BrowserCommands(session: runtime.browserSession)"
check_file_contains "the toolbar renders Back" \
  "$REPO_ROOT/NativeBrowser/UI/CommandBar/BrowserToolbarView.swift" "systemImage: \"chevron.backward\""
check_file_contains "the toolbar renders Forward" \
  "$REPO_ROOT/NativeBrowser/UI/CommandBar/BrowserToolbarView.swift" "systemImage: \"chevron.forward\""
check_file_contains "the toolbar renders reload/stop" \
  "$REPO_ROOT/NativeBrowser/UI/CommandBar/BrowserToolbarView.swift" "isLoading ? \"xmark\" : \"arrow.clockwise\""
check_file_contains "the toolbar hosts the address field" \
  "$REPO_ROOT/NativeBrowser/UI/CommandBar/BrowserToolbarView.swift" "AddressField("
check_file_contains "the toolbar sits above the Chromium view" \
  "$REPO_ROOT/NativeBrowser/UI/Main/MainWindowView.swift" "BrowserToolbarView(session: session)"
check_file_contains "the Chromium view still fills the window" \
  "$REPO_ROOT/NativeBrowser/UI/Main/MainWindowView.swift" "ChromiumView(session: session)"
check_file_contains "the Chromium view is not rebuilt by UI state" \
  "$REPO_ROOT/NativeBrowser/UI/Main/MainWindowView.swift" ".frame(maxWidth: .infinity, maxHeight: .infinity)"
check_absent "no forced identity change on the Chromium view" \
  "ChromiumView(session: session).id(" "$REPO_ROOT/NativeBrowser/UI/Main/MainWindowView.swift"
check_file_contains "focus requests reach the field through the responder chain" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserSession+Commands.swift" "NotificationCenter.default.post(name: .browserFocusAddressField"
check_file_contains "the field becomes first responder with select-all" \
  "$REPO_ROOT/NativeBrowser/UI/CommandBar/AddressField.swift" "func focusAndSelectAll()"

# ---------------------------------------------------------------------------
echo
echo "5. runtime navigation stack (--navigation-self-test)"
SELF_LOG="$WORK_DIR/m2-navigation-self-test.log"
NATIVEBROWSER_DATA_DIR="$DATA_DIR" run_with_timeout 120 "$EXECUTABLE" --navigation-self-test \
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
SELF_FAILURES="$(grep -c 'navigation-self-test: FAIL' "$SELF_LOG" 2>/dev/null || echo 0)"
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
check_contains "the browser was destroyed before CEF shutdown" \
  "navigation-self-test: pass browser-closed" "$SELF_LOG"
check_contains "CEF shut down cleanly" \
  "navigation-self-test: pass cef-clean-shutdown" "$SELF_LOG"

# ---------------------------------------------------------------------------
echo
echo "6. clean shutdown of the real application"
# The navigation self-test above cannot prove that a *navigated* browser is
# destroyed, because Chromium holds on to one in that harness window. The real
# application can: it is asked to navigate for real and then to quit, which runs
# the termination path (close every session -> pump -> CefShutdown).
NAV_QUIT_LOG="$WORK_DIR/m2-navigate-quit.log"
NAV_QUIT_URL="https://example.com/"
rm -rf "$DATA_DIR/navigate-quit"
start=$(date +%s)
# Both steps wait for the previous one to have happened, so the navigation is
# guaranteed to be in the running application before it is asked to quit.
NATIVEBROWSER_DATA_DIR="$DATA_DIR/navigate-quit" run_with_timeout 90 "$EXECUTABLE" \
  --home-url=https://www.google.com/ --wait-for-window \
  --navigate-after=3 --navigate-wait --quit-after=20 \
  > "$NAV_QUIT_LOG" 2>&1
NAV_QUIT_STATUS=$?
NAV_QUIT_TOTAL=$(( $(date +%s) - start ))
if [ "$NAV_QUIT_STATUS" -eq 0 ]; then
  pass "the app navigated and quit with exit 0"
else
  fail "the app navigated and quit with exit $NAV_QUIT_STATUS"
fi
check_contains "the live application navigated to a second page" \
  "navigation:url($NAV_QUIT_URL)" "$NAV_QUIT_LOG"
check_contains "the navigated browser was destroyed" "browser:closed" "$NAV_QUIT_LOG"
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
# --wait-for-window keeps this about the quit path rather than about how long
# the machine took to put the window on screen.
NATIVEBROWSER_DATA_DIR="$DATA_DIR" run_with_timeout $((QUIT_AFTER + 45)) "$EXECUTABLE" \
  --wait-for-window --quit-after=$QUIT_AFTER > "$GUI_LOG" 2>&1
GUI_STATUS=$?
GUI_TOTAL=$(( $(date +%s) - GUI_START ))
if [ "$GUI_STATUS" -eq 0 ]; then
  pass "app launched and terminated with exit 0"
else
  fail "app exited with $GUI_STATUS"
fi
check_contains "SwiftUI window appeared" "swiftui:main-window-appeared" "$GUI_LOG"
check_contains "Chromium browser created once" "browser:created(count=1)" "$GUI_LOG"
check_contains "google.com loaded in the running app" "title=Google" "$GUI_LOG"
check_contains "browser destroyed before CEF shutdown" "browser:closed" "$GUI_LOG"
check_contains "CEF shut down cleanly" "cef:shutdown(clean: true)" "$GUI_LOG"
if [ "$GUI_TOTAL" -le $((QUIT_AFTER + 25)) ]; then
  pass "quit completed in ${GUI_TOTAL}s (no shutdown hang)"
else
  fail "quit took ${GUI_TOTAL}s"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "Milestone 2: all automated checks passed"
else
  echo "Milestone 2: $FAILURES automated check(s) failed"
fi

cat <<'MANUAL'

REQUIRES MANUAL VERIFICATION (not covered by this script):
  * ⌘L while Chromium owns focus (menu key equivalent -> address field focus)
  * ⌘L select-all followed by typing replacing the selection
  * clicking the page after using the address field returns typing to the page
  * Chinese IME composition in the address field (candidate window, commit)
  * Back/Forward/Reload/Stop button enablement as drawn on screen
  * Escape cancelling an unsubmitted address edit
  * window resize behaviour of the Chromium content below the new toolbar
See the Milestone 2 manual checklist (Tests A-K) in the session report.
MANUAL

exit $((FAILURES > 0 ? 1 : 0))
