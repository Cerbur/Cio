#!/usr/bin/env bash
#
# Milestone 6 acceptance checks: durable workspace restore and lazy runtimes.
#
# This verifier deliberately launches two separate NativeBrowser processes.
# The external watchdog is test infrastructure only; production shutdown still
# waits for typed OnBeforeClose callbacks without a timeout fallback.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
APP="$REPO_ROOT/build/DerivedData/Build/Products/$CONFIGURATION/NativeBrowser.app"
EXECUTABLE="$APP/Contents/MacOS/NativeBrowser"
DATA_DIR="${DATA_DIR:-$REPO_ROOT/build/verification-data/milestone6}"
WORK_DIR="$REPO_ROOT/build/verification/milestone6"
TEST_BUNDLE="$REPO_ROOT/build/DerivedData/Build/Products/$CONFIGURATION/NativeBrowserTests.xctest"

FAILURES=0
pass() { printf '  [pass] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

check_contains() {
  if grep -qF -e "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1 (missing: $2)"; fi
}

check_absent() {
  if grep -qF -e "$2" "$3" 2>/dev/null; then fail "$1 (found: $2)"; else pass "$1"; fi
}

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

rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR" "$WORK_DIR"

if [ ! -x "$EXECUTABLE" ]; then
  echo "error: $EXECUTABLE not found; run Scripts/build.sh first" >&2
  exit 1
fi

echo "Milestone 6 verification"
echo "app: $APP"
echo "data: $DATA_DIR"
echo

# ---------------------------------------------------------------------------
echo "1. CEF-free persistence unit tests"
if command -v xcodegen >/dev/null 2>&1 \
  && xcodegen generate > "$WORK_DIR/xcodegen.log" 2>&1 \
  && "$REPO_ROOT/Scripts/sync_scheme.sh" > "$WORK_DIR/scheme.log" 2>&1; then
  pass "Xcode project and test scheme regenerated"
else
  fail "Xcode project/test scheme regeneration failed"
fi

xcodebuild \
  -project "$REPO_ROOT/NativeBrowser.xcodeproj" \
  -scheme NativeBrowser \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$REPO_ROOT/build/DerivedData" \
  build-for-testing > "$WORK_DIR/build.log" 2>&1
BUILD_CODE=$?
if [ "$BUILD_CODE" -eq 0 ] && [ -d "$TEST_BUNDLE" ]; then
  pass "unit test bundle built"
else
  fail "unit test bundle build failed"
  rg -n "error:" "$WORK_DIR/build.log" | head -10 || true
fi

if [ -d "$TEST_BUNDLE" ]; then
  xcrun xctest "$TEST_BUNDLE" > "$WORK_DIR/tests.log" 2>&1
  TEST_CODE=$?
  if [ "$TEST_CODE" -eq 0 ]; then
    TEST_COUNT="$(grep -c '^Test Case .* passed' "$WORK_DIR/tests.log" 2>/dev/null || true)"
    pass "unit tests passed ($TEST_COUNT test cases)"
  else
    fail "unit tests failed"
    rg -n "XCTAssert|failed|error:" "$WORK_DIR/tests.log" | head -20 || true
  fi
else
  TEST_CODE=1
fi

for CASE in \
  testFreshWorkspaceSnapshotRoundTrips \
  testSpaceAndTabOrderingAndSelectionsArePreserved \
  testSpaceAndTabIdentitiesArePreservedAcrossRestore \
  testURLsAndTitlesRoundTripExactly \
  testTransientLoadingAndRecentlyClosedStateIsNotPersisted \
  testSnapshotEqualityIgnoresRuntimeOnlyStateByConstruction \
  testUnsupportedSchemaIsRejected \
  testDuplicateSpaceIDIsRejected \
  testDuplicateTabIDIsRejected \
  testDanglingSelectedSpaceIsRejected \
  testDanglingSelectedTabIsRejected \
  testInvalidURLIsRejected \
  testMalformedJSONFailsSafely; do
  check_contains "persistence test: $CASE" "${CASE}]' passed" "$WORK_DIR/tests.log"
done

# ---------------------------------------------------------------------------
echo
echo "2. Seed process"
SEED_LOG="$WORK_DIR/seed.log"
FAKE_SECRET="fake-secret-value"
FAKE_FRAGMENT="fragment-secret"
HOME_URL="https://example.com/?code=$FAKE_SECRET#$FAKE_FRAGMENT"
NATIVEBROWSER_DATA_DIR="$DATA_DIR" \
NATIVEBROWSER_DISABLE_SESSION_PERSISTENCE=0 \
run_with_timeout 300 "$EXECUTABLE" \
  --session-restore-self-test=seed \
  --home-url="$HOME_URL" > "$SEED_LOG" 2>&1
SEED_CODE=$?
if [ "$SEED_CODE" -eq 0 ]; then pass "seed process exited 0"; else fail "seed process exited $SEED_CODE"; fi
if [ "$SEED_CODE" -gt 128 ]; then fail "seed process died from signal $((SEED_CODE - 128))"; fi

SESSION_FILE="$DATA_DIR/session-v1.json"
if [ -f "$SESSION_FILE" ]; then pass "session snapshot exists"; else fail "session snapshot is missing"; fi
if [ -f "$SESSION_FILE" ]; then cp "$SESSION_FILE" "$WORK_DIR/seed-session-v1.json"; fi
if [ -f "$SESSION_FILE" ] && grep -qF "$FAKE_SECRET" "$SESSION_FILE"; then
  pass "full committed URL including query was persisted"
else
  fail "full committed URL was not found in the snapshot"
fi
if [ -f "$SESSION_FILE" ] && stat -f '%Lp' "$SESSION_FILE" | grep -q '^600$'; then
  pass "session snapshot has private permissions"
else
  fail "session snapshot permissions are not 600"
fi
check_contains "seed created three Spaces" \
  "session-restore-self-test: pass seeded-three-spaces-and-two-tabs" "$SEED_LOG"
check_contains "seed created multiple tabs" \
  "domain-tabs=6" "$SEED_LOG"
check_contains "seed shut CEF down cleanly" \
  "lifecycle: cef:shutdown(clean: true)" "$SEED_LOG"

# ---------------------------------------------------------------------------
echo
echo "3. Verify process and lazy activation"
VERIFY_LOG="$WORK_DIR/verify.log"
NATIVEBROWSER_DATA_DIR="$DATA_DIR" \
NATIVEBROWSER_DISABLE_SESSION_PERSISTENCE=0 \
run_with_timeout 300 "$EXECUTABLE" \
  --session-restore-self-test=verify > "$VERIFY_LOG" 2>&1
VERIFY_CODE=$?
if [ "$VERIFY_CODE" -eq 0 ]; then pass "verify process exited 0"; else fail "verify process exited $VERIFY_CODE"; fi
if [ "$VERIFY_CODE" -gt 128 ]; then fail "verify process died from signal $((VERIFY_CODE - 128))"; fi

for CHECK in \
  startup-restored-domain-before-lazy-activation \
  startup-selected-tab-only-runtime \
  startup-selected-browser-ready \
  lazy-tab-had-no-session-before-selection \
  lazy-tab-created-on-first-activation \
  switching-back-reuses-both-sessions \
  lazy-space-selected-tab-had-no-session \
  lazy-space-instantiates-only-remembered-tab \
  closing-lazy-tab-does-not-create-runtime; do
  check_contains "self-test: $CHECK" "session-restore-self-test: pass $CHECK" "$VERIFY_LOG"
done

SEED_GRAPH="$(grep 'session-restore-self-test: seed-persisted' "$SEED_LOG" | tail -1 | sed 's/.* graph=//')"
VERIFY_GRAPH="$(grep 'session-restore-self-test: restored graph=' "$VERIFY_LOG" | tail -1 | sed 's/.* graph=//' | sed 's/ selected-space=.*//')"
if [ -n "$SEED_GRAPH" ] && [ "$SEED_GRAPH" = "$VERIFY_GRAPH" ]; then
  pass "Space/tab ordering and UUID identities survived relaunch"
else
  fail "restored Space/tab graph differs from seed"
fi

check_contains "startup has all six domain tabs" \
  "spaces=3 domain-tabs=6 live-sessions=1" "$VERIFY_LOG"
check_contains "shutdown closes only instantiated sessions" \
  "lifecycle: session:close-all(count=3)" "$VERIFY_LOG"
check_contains "CEF shutdown is recorded once" \
  "lifecycle: cef:shutdown(clean: true)" "$VERIFY_LOG"
SHUTDOWN_COUNT="$(grep -cF 'lifecycle: cef:shutdown(clean: true)' "$VERIFY_LOG" 2>/dev/null || true)"
if [ "$SHUTDOWN_COUNT" -eq 1 ]; then pass "CEF shutdown trace occurred once"; else fail "CEF shutdown trace occurred $SHUTDOWN_COUNT times"; fi

# ---------------------------------------------------------------------------
echo
echo "4. Privacy and production-architecture checks"
check_absent "fake query secret is absent from seed logs" "$FAKE_SECRET" "$SEED_LOG"
check_absent "fake fragment secret is absent from seed logs" "$FAKE_FRAGMENT" "$SEED_LOG"
check_absent "fake query secret is absent from verify logs" "$FAKE_SECRET" "$VERIFY_LOG"
check_absent "raw snapshot JSON is absent from verify logs" '"spaces"' "$VERIFY_LOG"
check_absent "production shutdown has no timeout fallback" "browser-close-timeout" "$VERIFY_LOG"
check_absent "lazy activation did not create synthetic close-only browsers" \
  "session-restore-self-test: FAIL" "$VERIFY_LOG"
check_contains "snapshot schema is version 1" '"schemaVersion" : 1' "$SESSION_FILE"
check_contains "seeded useful titles are persisted" 'Main secondary' "$WORK_DIR/seed-session-v1.json"

echo
echo "Evidence:"
echo "  unit tests: $WORK_DIR/tests.log"
echo "  seed log:   $SEED_LOG"
echo "  verify log: $VERIFY_LOG"
echo "  snapshot:   $SESSION_FILE"

if [ "$FAILURES" -eq 0 ]; then
  echo "Milestone 6: all automated checks passed"
else
  echo "Milestone 6: $FAILURES check(s) failed"
fi
exit $((FAILURES > 0 ? 1 : 0))
