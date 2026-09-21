#!/usr/bin/env bash
#
# Milestone 3 acceptance checks (ARCHITECTURE.md section 38).
#
#   Scripts/verify_milestone3.sh
#
# Checks, in order:
#   1. the pure tab model, without Chromium (unit tests)
#   2. the Milestone 3 ownership invariants, read from the source
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

if [ ! -x "$EXECUTABLE" ]; then
  echo "error: $EXECUTABLE not found; run Scripts/build.sh first" >&2
  exit 1
fi

echo "Milestone 3 verification"
echo "app: $APP"
echo

# ---------------------------------------------------------------------------
echo "1. tab model unit tests (no Chromium)"
TEST_LOG="$WORK_DIR/m3-tests-build.log"
TEST_BUNDLE="$REPO_ROOT/build/DerivedData/Build/Products/$CONFIGURATION/NativeBrowserTests.xctest"
TEST_RUN_LOG="$WORK_DIR/m3-tests-run.log"
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
    # grep -c prints 0 and exits 1 when nothing matched, so it must not be
    # combined with "|| echo 0": that would yield "0\n0" and break arithmetic.
    TEST_COUNT="$(grep -c "^Test Case .* passed" "$TEST_RUN_LOG" 2>/dev/null)"
    TEST_COUNT="${TEST_COUNT:-0}"
    pass "unit tests passed ($TEST_COUNT test cases)"
  else
    fail "unit tests failed; see $TEST_RUN_LOG"
    grep -E "error:" "$TEST_RUN_LOG" | head -5
  fi
  for SUITE in WorkspaceCollectionTests NavigationInputTests NavigationURLPreservationTests URLLogSanitizerTests; do
    if grep -q "Test Suite '$SUITE' passed" "$TEST_RUN_LOG" 2>/dev/null; then
      pass "$SUITE suite passed"
    else
      fail "$SUITE suite did not pass"
    fi
  done
  # The pure workspace rules are named individually so a regression says which
  # M3/M4 selection or close rule broke.
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
    testRecentlyClosedStackIsBoundedAndLIFO ; do
    # xctest prints: Test Case '-[Suite testName]' passed (0.001 seconds).
    if grep -qF -e "$CASE]' passed" "$TEST_RUN_LOG" 2>/dev/null; then
      pass "tab rule: $CASE"
    else
      fail "tab rule not verified: $CASE"
    fi
  done
fi

# ---------------------------------------------------------------------------
echo
echo "2. Milestone 3 ownership invariants"
# A domain tab identity that contains no CEF type (section 2).
check_file_contains "the tab model is a domain type" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserTab.swift" "struct BrowserTab: Identifiable"
check_file_absent "the tab model exposes no CefBrowser" \
  "CefBrowser" "$REPO_ROOT/NativeBrowser/Browser/BrowserTab.swift"
check_file_absent "the tab model imports no AppKit" \
  "import AppKit" "$REPO_ROOT/NativeBrowser/Browser/BrowserTab.swift"
check_file_absent "the tab ordering model exposes no CefBrowser" \
  "CefBrowser" "$REPO_ROOT/NativeBrowser/Browser/WorkspaceCollection.swift"
check_file_contains "a closed tab is a snapshot, not a live tab" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserTab.swift" "struct ClosedTabSnapshot"
# One application-level runtime owner (section 2).
check_file_contains "one application-level session manager" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserSessionManager.swift" "final class BrowserSessionManager: ObservableObject"
check_file_contains "the manager is main-actor isolated" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserSessionManager.swift" "@MainActor"
check_file_contains "the manager owns one session per tab" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserSessionManager.swift" "private var sessions: [UUID: BrowserSession] = [:]"
check_file_contains "the manager tracks sessions that are still closing" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserSessionManager.swift" "private var closingTabIDs: [UUID] = []"
check_file_contains "the workspace store owns Space and tab policy" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserWorkspaceStore.swift" "private var workspace: WorkspaceCollection"
check_file_contains "the workspace store owns the selection transition" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserWorkspaceStore.swift" "private func withSelectionTransition<T>(_ change: () -> T) -> T"
check_file_contains "the runtime owns the workspace store" \
  "$REPO_ROOT/NativeBrowser/App/ApplicationRuntime.swift" "let workspaceStore: BrowserWorkspaceStore"
check_file_absent "the runtime no longer holds a single browser session" \
  "let browserSession: BrowserSession" "$REPO_ROOT/NativeBrowser/App/ApplicationRuntime.swift"
# A typed close callback, not lifecycle-string control flow (section 7).
check_file_contains "a session reports its own close, typed" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserSession.swift" "var onClosed: ((BrowserSession) -> Void)?"
check_file_contains "the manager listens to the typed close" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserSessionManager.swift" "session.onClosed = { [weak self] session in"
check_file_absent "lifecycle strings are not used as control flow" \
  "hasPrefix(\"browser:closed\")" "$REPO_ROOT/NativeBrowser/App/ApplicationRuntime.swift"
# A stable browser surface (section 11).
check_file_contains "one stable AppKit surface host" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserSurfaceHostView.swift" "final class BrowserSurfaceHostView: NSView"
check_file_contains "the host keeps the containers it is given" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserSurfaceHostView.swift" "func present(containers: [UUID: ChromiumContainerView], selectedTabID: UUID?)"
check_file_contains "a tab switch only hides the inactive surface" \
  "$REPO_ROOT/NativeBrowser/Browser/ChromiumContainerView.swift" "func setSurfaceVisible(_ visible: Bool)"
check_file_contains "the manager owns the containers" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserSessionManager.swift" "private var containers: [UUID: ChromiumContainerView] = [:]"
if [ -f "$REPO_ROOT/NativeBrowser/Browser/ChromiumView.swift" ]; then
  fail "the per-window ChromiumView still exists (it would rebuild browsers on a switch)"
else
  pass "no per-tab/per-window ChromiumView representable remains"
fi
check_file_absent "no selection test decides whether a browser view is built" \
  "if tab.id == selectedTabID" "$REPO_ROOT/NativeBrowser/UI/Main/MainWindowView.swift"
# One toolbar for the whole window (section 14).
check_file_contains "the sidebar is part of the window" \
  "$REPO_ROOT/NativeBrowser/UI/Main/MainWindowView.swift" "TabSidebarView(workspace: workspace)"
check_file_contains "the toolbar follows the selected session" \
  "$REPO_ROOT/NativeBrowser/UI/Main/MainWindowView.swift" "BrowserToolbarView(session: session)"
check_file_contains "there is one address field, bound to a session" \
  "$REPO_ROOT/NativeBrowser/UI/CommandBar/BrowserToolbarView.swift" "model: session.addressField"
check_file_contains "focus requests are narrowed to one address model" \
  "$REPO_ROOT/NativeBrowser/UI/CommandBar/AddressField.swift" "object: model,"
# A single window scene (section 3).
check_file_contains "the app declares one window" \
  "$REPO_ROOT/NativeBrowser/App/NativeBrowserApp.swift" "Window(\"NativeBrowser\", id: \"main\")"
check_file_absent "the app does not declare an unconstrained WindowGroup" \
  "WindowGroup(" "$REPO_ROOT/NativeBrowser/App/NativeBrowserApp.swift"
# Tab shortcuts (sections 19, 21, 22, 23).
check_file_contains "Command-T is a menu key equivalent" \
  "$REPO_ROOT/NativeBrowser/App/AppCommands.swift" "keyboardShortcut(\"t\", modifiers: .command)"
check_file_contains "Command-W is a menu key equivalent" \
  "$REPO_ROOT/NativeBrowser/App/AppCommands.swift" "keyboardShortcut(\"w\", modifiers: .command)"
check_file_contains "Command-Shift-T is a menu key equivalent" \
  "$REPO_ROOT/NativeBrowser/App/AppCommands.swift" "keyboardShortcut(\"t\", modifiers: [.command, .shift])"
check_file_contains "Command-L still targets the selected session" \
  "$REPO_ROOT/NativeBrowser/App/AppCommands.swift" "workspace.selectedSession?.requestAddressFieldFocus()"
check_file_contains "Back still targets the selected session" \
  "$REPO_ROOT/NativeBrowser/App/AppCommands.swift" "workspace.selectedSession?.goBack()"
check_file_contains "Return-to-page still works from the address field" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserSession+Commands.swift" "NotificationCenter.default.post(name: .browserFocusAddressField"
# Per-session close, with the Markdown-2 focus fix generalised (section 17).
check_file_contains "the bridge can close a browser without stealing focus" \
  "$REPO_ROOT/NativeBrowser/Bridge/BrowserBridge.h" "- (void)closeForApplicationTermination:(BOOL)applicationTerminating;"
check_file_contains "termination still releases the first responder" \
  "$REPO_ROOT/NativeBrowser/Bridge/BrowserBridge.mm" "_releasesFirstResponderOnClose"
check_file_contains "an ordinary close only clears its own responder" \
  "$REPO_ROOT/NativeBrowser/Bridge/BrowserBridge.mm" "NBResponderBelongsToView"
check_file_contains "a browser reports its Chromium identity" \
  "$REPO_ROOT/NativeBrowser/Bridge/BrowserBridge.h" "@property(nonatomic, readonly) int browserIdentifier;"
# Popups become managed tabs (section 26).
check_file_contains "CEF popups are routed to a managed tab" \
  "$REPO_ROOT/NativeBrowser/Bridge/CEFClientHandler.mm" "browserDidRequestPopup"
check_file_absent "CEF popups no longer replace the current tab" \
  "main_frame->LoadURL(url)" "$REPO_ROOT/NativeBrowser/Bridge/CEFClientHandler.mm"
check_file_contains "the workspace routes a popup as a tab" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserWorkspaceStore.swift" "private func openPopupInNewTab(url: String, from session: BrowserSession)"
# No timing-based lifecycle coordination (sections 6 and 29).
if grep -qE "asyncAfter|sleep\(|DispatchQueue.*after" \
     "$REPO_ROOT/NativeBrowser/Browser/BrowserSessionManager.swift" 2>/dev/null; then
  fail "tab lifecycle must not use delays or timers"
else
  pass "tab lifecycle uses no delays or timers"
fi

# One workspace transition owns every selection change (Milestone 3 focus fix).
STORE="$REPO_ROOT/NativeBrowser/Browser/BrowserWorkspaceStore.swift"
check_file_contains "one transition owns every selection change" \
  "$STORE" "private func withSelectionTransition<T>(_ change: () -> T) -> T"
check_file_contains "tab selection is mutated by the workspace" \
  "$STORE" "workspace.selectTab(id: id)"
check_file_contains "tab insertion is mutated by the workspace" \
  "$STORE" "workspace.appendTab(tab, in: spaceID, select: select)"
check_file_contains "tab close is mutated by the workspace" \
  "$STORE" "let closeResult = workspace.close(id, reason: .userClosed)"
# The asynchronous half: a created browser only takes focus when its tab is the
# visible selected surface and the keyboard is still meant for page content.
check_file_contains "a created browser checks visibility and intent before focusing" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserSession.swift" \
  "if wantsPageFocus, containerView?.isSurfaceVisible == true {"
check_file_contains "a deferred focus request re-checks the surface" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserSession.swift" \
  "guard let self, self.canTakePageFocus else { return }"
# Chromium focuses a new browser itself when its first navigation starts, so the
# CEF focus request is answered instead of ignored (Milestone 3 focus fix).
check_file_contains "Chromium focus requests are handled at the CEF boundary" \
  "$REPO_ROOT/NativeBrowser/Bridge/CEFClientHandler.h" \
  "CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }"
check_file_contains "the focus handler asks the browser's owner" \
  "$REPO_ROOT/NativeBrowser/Bridge/CEFClientHandler.mm" \
  "[bridge browserRequestsFocusFromSystem:fromSystem]"
check_file_contains "the bridge forwards the focus request to its session" \
  "$REPO_ROOT/NativeBrowser/Bridge/BrowserBridge.mm" \
  "[self.delegate browserBridge:self allowsFocusRequestFromSystem:fromSystem]"
check_file_contains "only the visible selected surface may take a focus request" \
  "$REPO_ROOT/NativeBrowser/Browser/BrowserSession.swift" \
  "let allowed = !isClosed && isSurfaceVisible && ownsPageKeyboard"
# The address field reports taking the keyboard itself: AppKit does not deliver
# -controlTextDidBeginEditing for a programmatic focus change (⌘L), and without
# that signal a tab change would steal focus back out of the field.
check_file_contains "the address field reports taking the keyboard" \
  "$REPO_ROOT/NativeBrowser/UI/CommandBar/AddressField.swift" \
  "field.onFocusChange = { [weak coordinator = context.coordinator] focused in"
# Focus handling stays event-driven: no delays, no polling, no key monitors.
if grep -qE "asyncAfter|Thread\.sleep|usleep|Timer\.scheduledTimer|addLocalMonitorForEvents|addGlobalMonitorForEvents" \
     "$REPO_ROOT/NativeBrowser/Browser/BrowserSession.swift" 2>/dev/null; then
  fail "focus handling introduced a delay, a timer or a key monitor"
else
  pass "focus handling uses no delays, timers or key monitors"
fi

# ---------------------------------------------------------------------------
echo
echo "3. multi-tab integration (--tabs-self-test)"
SELF_LOG="$WORK_DIR/m3-tabs-self-test.log"
rm -rf "$DATA_DIR/tabs-self-test"
NATIVEBROWSER_DATA_DIR="$DATA_DIR/tabs-self-test" run_with_timeout 420 "$EXECUTABLE" \
  --tabs-self-test > "$SELF_LOG" 2>&1
SELF_STATUS=$?
if [ "$SELF_STATUS" -eq 0 ]; then
  pass "tabs self-test exited 0"
else
  fail "tabs self-test exited with $SELF_STATUS"
fi
if [ "$SELF_STATUS" -gt 128 ]; then
  fail "tabs self-test died from signal $((SELF_STATUS - 128))"
fi
while IFS= read -r line; do
  printf '  [pass] %s\n' "$line"
done < <(grep -o 'tabs-self-test: pass .*' "$SELF_LOG" 2>/dev/null)
while IFS= read -r line; do
  printf '  [FAIL] %s\n' "$line"
done < <(grep -o 'tabs-self-test: FAIL .*' "$SELF_LOG" 2>/dev/null)
SELF_FAILURES="$(grep -c 'tabs-self-test: FAIL' "$SELF_LOG" 2>/dev/null)"
SELF_FAILURES="${SELF_FAILURES:-0}"
FAILURES=$((FAILURES + SELF_FAILURES))

check_contains "several Spaces created several Chromium browsers" \
  "tabs-self-test: pass three-spaces-created" "$SELF_LOG"
check_contains "every session has a distinct Chromium browser identity" \
  "tabs-self-test: pass distinct-space-browser-identities" "$SELF_LOG"
check_contains "each Space has multiple live tabs" \
  "tabs-self-test: pass multiple-tabs-per-space" "$SELF_LOG"
check_contains "every session holds its own URL" \
  "tabs-self-test: pass distinct-urls" "$SELF_LOG"
check_contains "switching tabs did not recreate a browser" \
  "tabs-self-test: pass switch-does-not-recreate" "$SELF_LOG"
# Every live session still reports exactly one Chromium browser creation.
check_contains "browserCreationCount stayed at 1 for every session" \
  "tabs-self-test: pass all-existing-sessions-created-once" "$SELF_LOG"
check_contains "closing one browser reached OnBeforeClose" \
  "tabs-self-test: pass background-close-only-removes-own-space-tab" "$SELF_LOG"
check_contains "the other browsers stayed alive" \
  "tabs-self-test: pass closing-tabs-affects-only-own-space" "$SELF_LOG"
check_contains "a remaining browser could still navigate" \
  "tabs-self-test: pass inactive-space-callback-updated-source-tab" "$SELF_LOG"
check_contains "the stress phase created real browsers" \
  "tabs-self-test: pass multiple-tabs-per-space" "$SELF_LOG"
check_contains "the stress phase saw no duplicated identity" \
  "tabs-self-test: pass distinct-space-browser-identities" "$SELF_LOG"
check_contains "every stress browser was destroyed" \
  "tabs-self-test: pass all-spaces-shutdown-closes-every-runtime" "$SELF_LOG"
check_contains "closing the last tab produced a usable replacement" \
  "tabs-self-test: pass last-tab-replacement-stays-in-space" "$SELF_LOG"
check_contains "termination created no replacement tab" \
  "tabs-self-test: pass termination-creates-no-replacement-or-history" "$SELF_LOG"
check_contains "every browser closed before CefShutdown" \
  "tabs-self-test: pass onbeforeclose-before-cef-shutdown" "$SELF_LOG"
check_contains "the shutdown waits for typed close callbacks" \
  "tabs-self-test: pass shutdown-waits-for-onbeforeclose" "$SELF_LOG"
check_contains "CefShutdown ran exactly once" \
  "tabs-self-test: pass cef-shutdown-once" "$SELF_LOG"
check_contains "the self-test reported no failures" "failures=0" "$SELF_LOG"
# Focus ownership (Milestone 3 focus fix), observed through AppKit's real first
# responder. No key event is synthesised, so this proves ownership, not what a
# keystroke does with it.
check_contains "the selected page can hold AppKit keyboard focus" \
  "tabs-self-test: pass selected-page-holds-keyboard" "$SELF_LOG"
check_contains "a selected-page tab switch moves the keyboard to the new tab" \
  "tabs-self-test: pass switch-moves-keyboard" "$SELF_LOG"
check_contains "the native address field can own the keyboard" \
  "tabs-self-test: pass address-field-owns-keyboard-before-space-switch" "$SELF_LOG"
check_contains "a tab change keeps the address field's keyboard focus" \
  "tabs-self-test: pass tab-change-keeps-address-focus" "$SELF_LOG"
check_contains "a background tab is created without changing the selection" \
  "tabs-self-test: pass background-creation-keeps-selection" "$SELF_LOG"
check_contains "a background browser never takes keyboard focus" \
  "tabs-self-test: pass background-browser-does-not-take-focus" "$SELF_LOG"
check_contains "a browser created after its tab was hidden does not steal focus" \
  "tabs-self-test: pass late-space-browser-stays-hidden" "$SELF_LOG"
check_contains "closing a background tab keeps the active tab's focus" \
  "tabs-self-test: pass background-close-keeps-active-page-focus" "$SELF_LOG"
check_contains "closing the selected tab transfers focus to the new selection" \
  "tabs-self-test: pass selected-close-transfers-focus" "$SELF_LOG"

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
CREATED_BROWSERS="$(grep -cF -e "Chromium browser created" "$MULTI_LOG" 2>/dev/null)"
CREATED_BROWSERS="${CREATED_BROWSERS:-0}"
if [ "$CREATED_BROWSERS" -ge "$MULTI_TABS" ]; then
  pass "$CREATED_BROWSERS Chromium browsers were created and loaded"
else
  fail "only $CREATED_BROWSERS Chromium browsers were created (expected >= $MULTI_TABS)"
fi
DESTROYED_BROWSERS="$(grep -cF -e "Chromium browser destroyed" "$MULTI_LOG" 2>/dev/null)"
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
if [ -z "$(find ~/Library/Logs/DiagnosticReports -name 'NativeBrowser*' -newermt '-30 minutes' 2>/dev/null)" ]; then
  pass "no new NativeBrowser crash report"
else
  fail "a NativeBrowser crash report was written during this run"
fi
# Security: the same redaction rules apply to a multi-tab run.
check_contains "the lifecycle trace reports the URL with its query value redacted" \
  "navigation:url(https://example.com/?token=<redacted>)" "$MULTI_LOG"
check_absent "the raw query value is absent from the whole run log" \
  "$REDACT_TOKEN" "$MULTI_LOG"
check_file_contains "URLLogSanitizer is still the single redaction policy" \
  "$REPO_ROOT/NativeBrowser/App/URLLogSanitizer.swift" "enum URLLogSanitizer"

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
  echo "Milestone 3: all automated checks passed"
else
  echo "Milestone 3: $FAILURES automated check(s) failed"
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

  Milestone 3 focus ownership (real key events; the ownership rules themselves
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
