#!/usr/bin/env bash
#
# Milestone 4 acceptance checks: Spaces.
#
#   Scripts/verify_milestone4.sh
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
APP="$REPO_ROOT/build/DerivedData/Build/Products/$CONFIGURATION/NativeBrowser.app"
EXECUTABLE="$APP/Contents/MacOS/NativeBrowser"
DATA_DIR="${DATA_DIR:-$REPO_ROOT/build/verification-data}"
WORK_DIR="$REPO_ROOT/build/verification"
# M4 verifies in-memory Spaces and CEF lifecycle; do not load/save M6 state.
export NATIVEBROWSER_DISABLE_SESSION_PERSISTENCE=1

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

echo "Milestone 4 verification"
echo "app: $APP"
echo

# ---------------------------------------------------------------------------
echo "1. CEF-free workspace model"
TEST_LOG="$WORK_DIR/m4-tests-build.log"
TEST_BUNDLE="$REPO_ROOT/build/DerivedData/Build/Products/$CONFIGURATION/NativeBrowserTests.xctest"
TEST_RUN_LOG="$WORK_DIR/m4-tests-run.log"

# Keep the generated project and shared TestAction in sync when the verifier is
# run directly after a source checkout.
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate > "$WORK_DIR/m4-xcodegen.log" 2>&1
  if [ $? -eq 0 ] && "$REPO_ROOT/Scripts/sync_scheme.sh" > "$WORK_DIR/m4-scheme.log" 2>&1; then
    pass "Xcode project and test scheme regenerated"
  else
    fail "Xcode project/test scheme regeneration failed"
  fi
else
  fail "xcodegen is not installed"
fi

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
  xcrun xctest "$TEST_BUNDLE" > "$TEST_RUN_LOG" 2>&1
  if [ $? -eq 0 ]; then
    TEST_COUNT="$(grep -c "^Test Case .* passed" "$TEST_RUN_LOG" 2>/dev/null)"
    TEST_COUNT="${TEST_COUNT:-0}"
    pass "unit tests passed ($TEST_COUNT test cases)"
  else
    fail "unit tests failed; see $TEST_RUN_LOG"
    grep -E "XCTAssert|error:" "$TEST_RUN_LOG" | head -10
  fi
  check_contains "WorkspaceCollectionTests suite passed" \
    "Test Suite 'WorkspaceCollectionTests' passed" "$TEST_RUN_LOG"
  for CASE in \
    testInitialWorkspaceContainsExactlyOneSpace \
    testCreatingSpaceAppendsPredictablyAndSelectsItsFreshTab \
    testSwitchingSpaceUpdatesSelectedSpace \
    testEachSpaceRemembersItsSelectedTabIndependently \
    testTabsBelongToExactlyOneSpace \
    testCreateTabAddsOnlyToSelectedSpace \
    testTabOrderIsIndependentPerSpace \
    testSelectingCurrentSpaceTabWorks \
    testSelectingForeignSpaceTabIsRejected \
    testExplicitSpaceAndTabSelectionIsTheOnlyForeignEscapeHatch \
    testClosingSelectedTabChoosesRightNeighbourInSameSpace \
    testClosingBackgroundTabLeavesSpaceSelectionIntact \
    testClosingLastTabRequestsReplacementInItsOwnSpace \
    testTerminationCloseDoesNotCreateReplacementOrRecentlyClosedEntry \
    testRecentlyClosedSnapshotRecordsOriginSpaceAndIndex \
    testRestoreReturnsTabToOriginalSpaceAndIndexWithNewID \
    testRenameTrimsWhitespace \
    testEmptyRenameIsRejectedAndKeepsSafeName \
    testUnknownSpaceAndTabOperationsAreSafe \
    testDuplicateTabCannotBelongToTwoSpaces \
    testSpaceAndTabOrderIsDeterministic \
    testRecentlyClosedStackIsBoundedAndLIFO; do
    if grep -qF -e "$CASE]' passed" "$TEST_RUN_LOG" 2>/dev/null; then
      pass "workspace rule: $CASE"
    else
      fail "workspace rule not verified: $CASE"
    fi
  done
fi

# ---------------------------------------------------------------------------
echo
echo "2. Spaces ownership and lifecycle structure"
SPACE="$REPO_ROOT/NativeBrowser/Browser/BrowserSpace.swift"
COLLECTION="$REPO_ROOT/NativeBrowser/Browser/WorkspaceCollection.swift"
STORE="$REPO_ROOT/NativeBrowser/Browser/BrowserWorkspaceStore.swift"
MANAGER="$REPO_ROOT/NativeBrowser/Browser/BrowserSessionManager.swift"
RUNTIME="$REPO_ROOT/NativeBrowser/App/ApplicationRuntime.swift"

for FILE in "$SPACE" "$COLLECTION" "$REPO_ROOT/NativeBrowser/Browser/BrowserTab.swift"; do
  check_file_absent "pure workspace file has no AppKit import" "import AppKit" "$FILE"
  check_file_absent "pure workspace file has no CEF browser type" "CefBrowser" "$FILE"
done
check_file_contains "BrowserSpace is a CEF-free domain value" "$SPACE" \
  "struct BrowserSpace: Identifiable, Equatable, Sendable"
check_file_contains "WorkspaceCollection owns ordered Spaces" "$COLLECTION" \
  "private(set) var spaces: [BrowserSpace]"
check_file_contains "WorkspaceCollection owns domain tabs" "$COLLECTION" \
  "private(set) var tabsByID: [UUID: BrowserTab]"
check_file_contains "closed snapshots carry their Space" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserTab.swift" "let spaceID: UUID"
check_file_contains "the runtime manager owns sessions only" "$MANAGER" \
  "private var sessions: [UUID: BrowserSession] = [:]"
check_file_contains "the manager retains closing runtimes" "$MANAGER" \
  "private var closingTabIDs: [UUID] = []"
check_file_contains "the manager owns one container per live session" "$MANAGER" \
  "private var containers: [UUID: ChromiumContainerView] = [:]"
check_file_contains "the manager exposes a typed close callback" "$MANAGER" \
  "var onLiveSessionDidClose: ((BrowserSession) -> Void)?"
check_file_absent "the manager does not own a domain workspace" \
  "private var workspace" "$MANAGER"
check_file_absent "the manager does not own domain tab ordering" \
  "private(set) var tabs: [BrowserTab]" "$MANAGER"
check_file_absent "the manager does not own recently closed history" \
  "recentlyClosed" "$MANAGER"
check_file_absent "the manager does not own effective tab selection" \
  "private(set) var selectedTabID" "$MANAGER"
check_file_contains "the workspace store owns the pure collection" "$STORE" \
  "private var workspace: WorkspaceCollection"
check_file_contains "Space and tab selection share one transition" "$STORE" \
  "private func withSelectionTransition<T>(_ change: () -> T) -> T"
check_file_contains "the runtime owns the workspace store" "$RUNTIME" \
  "let workspaceStore: BrowserWorkspaceStore"
check_file_absent "the runtime does not declare a second manager owner" \
  "let sessionManager: BrowserSessionManager" "$RUNTIME"
check_file_contains "the stable surface presents all live containers" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserSurfaceHostView.swift" \
  "func present(containers: [UUID: ChromiumContainerView], selectedTabID: UUID?)"
check_file_contains "popups route through the source session" \
  "$REPO_ROOT/NativeBrowser/Bridge/CEFClientHandler.mm" "browserDidRequestPopup"
check_file_contains "popup routing resolves the source Space" "$STORE" \
  "let sourceSpaceID = workspace.spaceID(containing: session.tabID)"
check_file_absent "runtime session lifecycle has no delay" "asyncAfter" "$MANAGER"
check_file_absent "runtime session lifecycle has no sleep" "sleep(" "$MANAGER"
check_file_absent "production shutdown has no timeout fallback" "browserShutdownTimeout" "$RUNTIME"
check_file_absent "production shutdown has no close-timeout branch" "browser-close-timeout" "$RUNTIME"
check_file_absent "production shutdown never skips CEF for a live browser" \
  "skipped-cef-shutdown" "$RUNTIME"
check_file_contains "Command-T creates a tab in the workspace" \
  "$REPO_ROOT/NativeBrowser/App/AppCommands.swift" "workspace.createTab(url: nil)"
check_file_contains "Command-W closes the selected tab in the workspace" \
  "$REPO_ROOT/NativeBrowser/App/AppCommands.swift" "workspace.closeSelectedTab()"
check_file_contains "the sidebar renders Spaces" \
  "$REPO_ROOT/NativeBrowser/UI/Sidebar/TabSidebarView.swift" "Text(\"Spaces\")"

# ---------------------------------------------------------------------------
echo
echo "3. real multi-Space CEF self-test"
SELF_LOG="$WORK_DIR/m4-spaces-self-test.log"
rm -rf "$DATA_DIR/spaces-self-test"
REDACT_TOKEN="m4-test-token_123-abc"
HOME_URL="https://example.com/?token=$REDACT_TOKEN"
NATIVEBROWSER_DATA_DIR="$DATA_DIR/spaces-self-test" run_with_timeout 600 "$EXECUTABLE" \
  --spaces-self-test --home-url="$HOME_URL" > "$SELF_LOG" 2>&1
SELF_STATUS=$?
if [ "$SELF_STATUS" -eq 0 ]; then
  pass "spaces self-test exited 0"
else
  fail "spaces self-test exited with $SELF_STATUS"
fi
if [ "$SELF_STATUS" -gt 128 ]; then
  fail "spaces self-test died from signal $((SELF_STATUS - 128))"
fi
while IFS= read -r line; do
  printf '  [pass] %s\n' "$line"
done < <(grep -o 'spaces-self-test: pass .*' "$SELF_LOG" 2>/dev/null)
while IFS= read -r line; do
  printf '  [FAIL] %s\n' "$line"
done < <(grep -o 'spaces-self-test: FAIL .*' "$SELF_LOG" 2>/dev/null)
SELF_FAILURES="$(grep -c 'spaces-self-test: FAIL' "$SELF_LOG" 2>/dev/null)"
SELF_FAILURES="${SELF_FAILURES:-0}"
FAILURES=$((FAILURES + SELF_FAILURES))

for CHECK in \
  three-spaces-created \
  space-ids-unique \
  each-space-has-one-fresh-tab \
  space-browsers-created \
  multiple-tabs-per-space \
  distinct-space-browser-identities \
  all-existing-sessions-created-once \
  independent-space-selections \
  switch-spaces-restores-remembered-tabs \
  switch-spaces-does-not-recreate \
  only-selected-space-tab-is-visible \
  space-switch-moves-page-focus \
  address-field-owns-keyboard-before-space-switch \
  space-switch-does-not-steal-address-focus \
  space-creation-race-was-async \
  late-space-browser-stays-hidden \
  inactive-space-callback-updated-source-tab \
  inactive-space-callback-keeps-selection \
  background-close-only-removes-own-space-tab \
  background-close-keeps-active-page-focus \
  closing-tabs-affects-only-own-space \
  last-tab-replacement-stays-in-space \
  last-tab-replacement-created-once \
  recently-closed-remembers-space \
  reopen-creates-new-runtime \
  reopen-restores-original-index \
  reopen-selects-original-space \
  popup-from-inactive-space-uses-source-space \
  inactive-popup-does-not-switch-space-or-focus \
  all-spaces-shutdown-closes-every-runtime \
  termination-creates-no-replacement-or-history \
  onbeforeclose-before-cef-shutdown \
  shutdown-waits-for-onbeforeclose \
  cef-shutdown-once; do
  check_contains "self-test: $CHECK" "spaces-self-test: pass $CHECK" "$SELF_LOG"
done
check_contains "self-test reported zero failures" "spaces-self-test: checks=" "$SELF_LOG"
check_contains "self-test summary reports failures=0" "failures=0" "$SELF_LOG"
check_contains "CEF shut down exactly once" "lifecycle: cef:shutdown(clean: true)" "$SELF_LOG"
SHUTDOWN_COUNT="$(grep -cF -e "lifecycle: cef:shutdown(clean: true)" "$SELF_LOG" 2>/dev/null)"
SHUTDOWN_COUNT="${SHUTDOWN_COUNT:-0}"
if [ "$SHUTDOWN_COUNT" -eq 1 ]; then pass "CEF shutdown trace occurred once"; else fail "CEF shutdown trace occurred $SHUTDOWN_COUNT times"; fi
check_absent "self-test did not use a timeout fallback" "termination:browser-close-timeout" "$SELF_LOG"
check_absent "self-test did not skip CEF with live browsers" "termination:skipped-cef-shutdown" "$SELF_LOG"

# ---------------------------------------------------------------------------
echo
echo "4. redaction and manual checks"
check_contains "sanitized query shape is observable" \
  "navigation:url(https://example.com/?token=<redacted>)" "$SELF_LOG"
check_absent "raw test token is absent from the self-test log" "$REDACT_TOKEN" "$SELF_LOG"
check_file_contains "URLLogSanitizer remains the single URL redaction policy" \
  "$REPO_ROOT/NativeBrowser/App/URLLogSanitizer.swift" "enum URLLogSanitizer"

echo
echo "REQUIRES MANUAL VERIFICATION"
echo "  - click between Spaces and confirm the one visible Chromium surface follows selection"
echo "  - type into the address field, switch Spaces, and confirm text/focus are preserved"
echo "  - use Cmd-T/Cmd-W/Cmd-Shift-T and Cmd-1…Cmd-9 in multiple Spaces"
echo "  - rename a Space and confirm empty names are rejected"
echo "  - open a real target=_blank popup from an inactive Space and inspect its destination"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "Milestone 4: all automated checks passed"
else
  echo "Milestone 4: $FAILURES check(s) failed"
fi
exit $((FAILURES > 0 ? 1 : 0))
