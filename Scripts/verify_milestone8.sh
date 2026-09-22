#!/usr/bin/env bash
#
# Milestone 8 orchestrator. The external timeout in this script is test
# infrastructure only; production shutdown never turns a timeout into
# CefShutdown while a browser is live.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
APP="$REPO_ROOT/build/DerivedData/Build/Products/$CONFIGURATION/NativeBrowser.app"
EXECUTABLE="$APP/Contents/MacOS/NativeBrowser"
TEST_BUNDLE="$REPO_ROOT/build/DerivedData/Build/Products/$CONFIGURATION/NativeBrowserTests.xctest"
WORK_DIR="$REPO_ROOT/build/verification/milestone8"
DATA_DIR="$REPO_ROOT/build/verification-data/milestone8"
DOWNLOADS_DIR="$REPO_ROOT/build/verification-downloads/milestone8"
LAZY_DATA_DIR="$REPO_ROOT/build/verification-data/milestone8-lazy"
PORT="${M8_FIXTURE_PORT:-43128}"
BASE_URL="http://127.0.0.1:$PORT"

FAILURES=0
FIXTURE_PID=""
pass() { printf '  [pass] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

check_contains() {
  if grep -qF -e "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1 (missing: $2)"; fi
}

check_no_process() {
  if pgrep -f -e "$EXECUTABLE" >/dev/null 2>&1; then
    fail "$1 (NativeBrowser process remains)"
  else
    pass "$1"
  fi
}

run_with_timeout() {
  local seconds="$1"
  shift
  if command -v caffeinate >/dev/null 2>&1; then
    caffeinate -i "$@" &
  else
    "$@" &
  fi
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$seconds" ]; then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

run_step() {
  local label="$1"
  shift
  echo
  echo "$label"
  if "$@"; then
    pass "$label"
  else
    fail "$label"
  fi
}

cleanup() {
  if [ -n "$FIXTURE_PID" ]; then
    kill "$FIXTURE_PID" 2>/dev/null || true
    wait "$FIXTURE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

rm -rf "$WORK_DIR" "$DATA_DIR" "$DOWNLOADS_DIR" "$LAZY_DATA_DIR"
mkdir -p "$WORK_DIR" "$DATA_DIR" "$DOWNLOADS_DIR" "$LAZY_DATA_DIR"

echo "Milestone 8 verification"
echo "configuration: $CONFIGURATION"
echo "app: $APP"

echo
echo "1. clean Debug build and unit tests"
if xcodegen generate > "$WORK_DIR/xcodegen.log" 2>&1 \
  && "$REPO_ROOT/Scripts/sync_scheme.sh" > "$WORK_DIR/scheme.log" 2>&1 \
  && xcodebuild \
       -project "$REPO_ROOT/NativeBrowser.xcodeproj" \
       -scheme NativeBrowser \
       -configuration "$CONFIGURATION" \
       -derivedDataPath "$REPO_ROOT/build/DerivedData" \
       clean build > "$WORK_DIR/debug-build.log" 2>&1 \
  && xcodebuild \
       -project "$REPO_ROOT/NativeBrowser.xcodeproj" \
       -scheme NativeBrowser \
       -configuration "$CONFIGURATION" \
       -derivedDataPath "$REPO_ROOT/build/DerivedData" \
       build-for-testing >> "$WORK_DIR/debug-build.log" 2>&1; then
  pass "clean Debug build-for-testing"
else
  fail "clean Debug build-for-testing"
fi
if [ -d "$TEST_BUNDLE" ] && xcrun xctest "$TEST_BUNDLE" > "$WORK_DIR/unit-tests.log" 2>&1; then
  TEST_COUNT="$(grep -c '^Test Case .* passed' "$WORK_DIR/unit-tests.log" 2>/dev/null || true)"
  pass "unit tests passed ($TEST_COUNT test cases)"
else
  fail "unit tests passed"
fi

echo
echo "2. earlier milestone regression"
if [ "${RUN_FULL_REGRESSION:-1}" = "1" ]; then
  for milestone in 0 1 2 3 4 6 7; do
    log="$WORK_DIR/milestone$milestone.log"
    if CONFIGURATION="$CONFIGURATION" \
      DATA_DIR="$REPO_ROOT/build/verification-data/milestone8-m$milestone" \
      DOWNLOADS_DIR="$REPO_ROOT/build/verification-downloads/milestone8-m$milestone" \
      "$REPO_ROOT/Scripts/verify_milestone$milestone.sh" > "$log" 2>&1; then
      pass "Milestone $milestone regression"
    else
      fail "Milestone $milestone regression (see $log)"
    fi
  done
else
  echo "  [skip] RUN_FULL_REGRESSION=0"
fi

echo
echo "3. loopback fixture and M8 stress drivers"
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
if [ "$FIXTURE_READY" -eq 1 ]; then pass "loopback fixture server started"; else fail "loopback fixture server started"; fi

STRESS_LOG="$WORK_DIR/stress.log"
NATIVEBROWSER_DATA_DIR="$DATA_DIR" \
NATIVEBROWSER_DOWNLOADS_DIR="$DOWNLOADS_DIR" \
NATIVEBROWSER_DISABLE_SESSION_PERSISTENCE=1 \
run_with_timeout 600 "$EXECUTABLE" \
  --use-mock-keychain \
  --milestone8-self-test=stress \
  --home-url="$BASE_URL/page-a" \
  --m8-fixture-base-url="$BASE_URL" > "$STRESS_LOG" 2>&1
STRESS_CODE=$?
if [ "$STRESS_CODE" -eq 0 ]; then pass "M8 rapid tabs/Spaces stress"; else fail "M8 rapid tabs/Spaces stress (exit $STRESS_CODE)"; fi
check_contains "M8 created 20+ tabs and five Spaces" "m8-self-test: pass twenty-tabs-five-spaces-created -" "$STRESS_LOG"
check_contains "M8 stress verified one browser creation per tab" "m8-self-test: pass every-stress-session-created-once -" "$STRESS_LOG"
check_contains "M8 stress verified one visible surface" "m8-self-test: pass rapid-tab-space-switch-keeps-one-visible-surface -" "$STRESS_LOG"
check_contains "M8 stress verified close/reopen" "m8-self-test: pass recently-closed-tab-reopens-with-new-runtime -" "$STRESS_LOG"
check_contains "M8 stress verified ordered shutdown" "m8-self-test: pass all-live-sessions-close-before-single-cef-shutdown -" "$STRESS_LOG"
check_no_process "M8 stress left no residual process"

echo
echo "4. lazy restore stress"
LAZY_SEED_LOG="$WORK_DIR/lazy-seed.log"
NATIVEBROWSER_DATA_DIR="$LAZY_DATA_DIR" \
NATIVEBROWSER_DOWNLOADS_DIR="$DOWNLOADS_DIR" \
NATIVEBROWSER_DISABLE_SESSION_PERSISTENCE=0 \
run_with_timeout 600 "$EXECUTABLE" \
  --use-mock-keychain \
  --milestone8-self-test=lazy-seed \
  --home-url="$BASE_URL/page-a" \
  --m8-fixture-base-url="$BASE_URL" > "$LAZY_SEED_LOG" 2>&1
LAZY_SEED_CODE=$?
if [ "$LAZY_SEED_CODE" -eq 0 ]; then pass "lazy seed exited 0"; else fail "lazy seed exited $LAZY_SEED_CODE"; fi
check_contains "lazy seed persisted 50 domain tabs" "m8-self-test: pass lazy-seed-fifty-domain-tabs -" "$LAZY_SEED_LOG"
check_no_process "lazy seed left no residual process"

LAZY_VERIFY_LOG="$WORK_DIR/lazy-verify.log"
NATIVEBROWSER_DATA_DIR="$LAZY_DATA_DIR" \
NATIVEBROWSER_DOWNLOADS_DIR="$DOWNLOADS_DIR" \
NATIVEBROWSER_DISABLE_SESSION_PERSISTENCE=0 \
run_with_timeout 600 "$EXECUTABLE" \
  --use-mock-keychain \
  --milestone8-self-test=lazy-verify \
  --home-url="$BASE_URL/page-a" \
  --m8-fixture-base-url="$BASE_URL" > "$LAZY_VERIFY_LOG" 2>&1
LAZY_VERIFY_CODE=$?
if [ "$LAZY_VERIFY_CODE" -eq 0 ]; then pass "lazy verify exited 0"; else fail "lazy verify exited $LAZY_VERIFY_CODE"; fi
check_contains "lazy startup had one live session" "m8-self-test: pass lazy-restore-starts-with-one-live-session -" "$LAZY_VERIFY_LOG"
check_contains "lazy activation stayed scoped to selected tabs" "m8-self-test: pass lazy-restore-activates-only-selected-space-tabs -" "$LAZY_VERIFY_LOG"
check_no_process "lazy verify left no residual process"

echo
echo "5. deterministic beforeunload integration"
for response in cancel accept; do
  beforeunload_log="$WORK_DIR/beforeunload-$response.log"
  NATIVEBROWSER_BEFOREUNLOAD_AUTORESPONSE="$response" \
  NATIVEBROWSER_DATA_DIR="$REPO_ROOT/build/verification-data/milestone8-beforeunload-$response" \
  NATIVEBROWSER_DOWNLOADS_DIR="$DOWNLOADS_DIR" \
  NATIVEBROWSER_DISABLE_SESSION_PERSISTENCE=1 \
  run_with_timeout 180 "$EXECUTABLE" \
    --use-mock-keychain \
    --beforeunload-self-test="$response" \
    --home-url="$BASE_URL/beforeunload" > "$beforeunload_log" 2>&1
  beforeunload_code=$?
  if [ "$beforeunload_code" -eq 0 ]; then
    pass "beforeunload $response self-test exited 0"
  else
    fail "beforeunload $response self-test exited $beforeunload_code"
  fi
  if [ "$response" = "cancel" ]; then
    check_contains "beforeunload cancel keeps tab and session" \
      "beforeunload-self-test: pass cancel-keeps-tab-and-session-live" "$beforeunload_log"
    check_contains "beforeunload cancel leaves recently-closed empty" \
      "beforeunload-self-test: pass cancel-does-not-add-recently-closed" "$beforeunload_log"
  else
    check_contains "beforeunload accept removes tab" \
      "beforeunload-self-test: pass accept-removes-tab" "$beforeunload_log"
    check_contains "beforeunload accept reaches OnBeforeClose" \
      "beforeunload-self-test: pass accept-reaches-onbeforeclose" "$beforeunload_log"
    check_contains "beforeunload accept closes exactly once" \
      "beforeunload-self-test: pass accept-onbeforeclose-exactly-once" "$beforeunload_log"
  fi
  check_contains "beforeunload $response cleans remaining runtimes" \
    "beforeunload-self-test: pass termination-closes-remaining-runtimes" "$beforeunload_log"
  check_contains "beforeunload $response shuts CEF down once" \
    "beforeunload-self-test: pass cef-shutdown-count-is-one" "$beforeunload_log"
  check_no_process "beforeunload $response left no residual process"
done

echo
echo "6. fixture and privacy checks"
if curl -fsS "$BASE_URL/beforeunload" | grep -qF "beforeunload"; then
  pass "beforeunload fixture is available (native alert is integration-tested; GUI remains manual)"
else
  fail "beforeunload fixture is available"
fi
if curl -fsS "$BASE_URL/popup" | grep -qF "window.open"; then pass "popup fixture is available"; else fail "popup fixture is available"; fi
if curl -fsS "$BASE_URL/slow-download" >/dev/null; then pass "slow-download fixture is available"; else fail "slow-download fixture is available"; fi
if "$REPO_ROOT/Scripts/check_no_secrets.sh" > "$WORK_DIR/secret-scan.log" 2>&1; then
  pass "repository secret scan"
else
  fail "repository secret scan"
fi

echo
echo "7. bounded quit soak"
for iteration in 1 2; do
  soak_log="$WORK_DIR/soak-$iteration.log"
  NATIVEBROWSER_DATA_DIR="$REPO_ROOT/build/verification-data/milestone8-soak-$iteration" \
  NATIVEBROWSER_DOWNLOADS_DIR="$DOWNLOADS_DIR" \
  NATIVEBROWSER_DISABLE_SESSION_PERSISTENCE=1 \
  run_with_timeout 240 "$EXECUTABLE" \
    --use-mock-keychain \
    --wait-for-window \
    --open-tabs=24 \
    --quit-after=12 \
    --home-url="$BASE_URL/page-a" > "$soak_log" 2>&1
  soak_code=$?
  if [ "$soak_code" -eq 0 ]; then pass "soak iteration $iteration exited 0"; else fail "soak iteration $iteration exited $soak_code"; fi
  check_contains "soak iteration $iteration closed browsers before CEF" "lifecycle: termination:browsers-closed" "$soak_log"
  check_contains "soak iteration $iteration shut CEF down once" "lifecycle: cef:shutdown(clean: true)" "$soak_log"
  check_no_process "soak iteration $iteration left no residual process"
done

echo
echo "8. release candidate"
if "$REPO_ROOT/Scripts/verify_release_candidate.sh" > "$WORK_DIR/release-candidate.log" 2>&1; then
  pass "Release candidate verification"
else
  fail "Release candidate verification (see $WORK_DIR/release-candidate.log)"
fi

echo
echo "9. static hardening gates"
check_contains "ordinary close uses cancelable CloseBrowser(false)" "force_close=*/false" "$REPO_ROOT/NativeBrowser/Bridge/BrowserBridge.mm"
check_contains "termination force-closes explicitly" "force_close=*/true" "$REPO_ROOT/NativeBrowser/Bridge/BrowserBridge.mm"
check_contains "CEF shutdown has a live-browser guard" "guard !workspaceStore.hasLiveSessions" "$REPO_ROOT/NativeBrowser/App/ApplicationRuntime.swift"
check_contains "address monitor removes on window move" "removeAddressFieldMouseMonitor()" "$REPO_ROOT/NativeBrowser/UI/Main/MainWindowView.swift"
check_contains "renderer termination has a recoverable UI" "renderer-crash-reload" "$REPO_ROOT/NativeBrowser/UI/Main/MainWindowView.swift"
if git diff --check; then pass "git diff --check"; else fail "git diff --check"; fi

echo
echo "Evidence:"
echo "  unit tests:       $WORK_DIR/unit-tests.log"
echo "  stress:           $STRESS_LOG"
echo "  lazy seed/verify: $LAZY_SEED_LOG / $LAZY_VERIFY_LOG"
echo "  release:          $WORK_DIR/release-candidate.log"

if [ "$FAILURES" -eq 0 ]; then
  echo "Milestone 8: all automated checks passed"
else
  echo "Milestone 8: $FAILURES check(s) failed"
fi
exit $((FAILURES > 0 ? 1 : 0))
