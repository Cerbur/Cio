#!/usr/bin/env bash
# Milestone 7 acceptance checks: real CEF history and downloads plus pure model
# tests. All browser state and downloaded files are isolated under build/.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
APP="$REPO_ROOT/build/DerivedData/Build/Products/$CONFIGURATION/NativeBrowser.app"
EXECUTABLE="$APP/Contents/MacOS/NativeBrowser"
TEST_BUNDLE="$REPO_ROOT/build/DerivedData/Build/Products/$CONFIGURATION/NativeBrowserTests.xctest"
DATA_DIR="${DATA_DIR:-$REPO_ROOT/build/verification-data/milestone7}"
DOWNLOADS_DIR="${DOWNLOADS_DIR:-$REPO_ROOT/build/verification-downloads/milestone7}"
WORK_DIR="$REPO_ROOT/build/verification/milestone7"
PORT="${M7_FIXTURE_PORT:-43123}"
BASE_URL="http://127.0.0.1:$PORT"
FAKE_SECRET="fake-secret-value"
FAKE_FRAGMENT="fragment-secret"
HOME_URL="$BASE_URL/page-a?code=$FAKE_SECRET#$FAKE_FRAGMENT"
FAILED_URL="http://127.0.0.1:9/m7-failed"

FAILURES=0
pass() { printf '  [pass] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

check_contains() {
  if grep -qF -e "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1 (missing: $2)"; fi
}

check_absent() {
  if grep -qF -e "$2" "$3" 2>/dev/null; then fail "$1 (found sensitive value)"; else pass "$1"; fi
}

check_no_native_browser_process() {
  if pgrep -f -e "$EXECUTABLE" >/dev/null 2>&1; then
    fail "$1 (NativeBrowser process remains)"
  else
    pass "$1"
  fi
}

run_with_timeout() {
  local seconds="$1"
  shift
  local caffeinate=""
  if command -v caffeinate >/dev/null 2>&1; then caffeinate="caffeinate -i"; fi
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

FIXTURE_PID=""
cleanup() {
  if [ -n "$FIXTURE_PID" ]; then
    kill "$FIXTURE_PID" 2>/dev/null || true
    wait "$FIXTURE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

rm -rf "$DATA_DIR" "$DOWNLOADS_DIR" "$WORK_DIR"
mkdir -p "$DATA_DIR" "$DOWNLOADS_DIR" "$WORK_DIR"

echo "Milestone 7 verification"
echo "app: $APP"
echo "data: $DATA_DIR"
echo "downloads: $DOWNLOADS_DIR"
echo

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

echo
echo "1. build and unit tests"
if xcodegen generate > "$WORK_DIR/xcodegen.log" 2>&1 \
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
fi

if [ "$BUILD_CODE" -eq 0 ] && [ -d "$TEST_BUNDLE" ]; then
  xcrun xctest "$TEST_BUNDLE" > "$WORK_DIR/tests.log" 2>&1
  TEST_CODE=$?
  if [ "$TEST_CODE" -eq 0 ]; then
    TEST_COUNT="$(grep -c '^Test Case .* passed' "$WORK_DIR/tests.log" 2>/dev/null || true)"
    pass "unit tests passed ($TEST_COUNT test cases)"
  else
    fail "unit tests failed"
  fi
else
  TEST_CODE=1
fi

echo
echo "2. real CEF seed process"
SEED_LOG="$WORK_DIR/seed.log"
NATIVEBROWSER_DATA_DIR="$DATA_DIR" \
NATIVEBROWSER_DOWNLOADS_DIR="$DOWNLOADS_DIR" \
NATIVEBROWSER_DISABLE_SESSION_PERSISTENCE=1 \
run_with_timeout 180 "$EXECUTABLE" \
  --milestone7-self-test=seed \
  --home-url="$HOME_URL" \
  --m7-fixture-base-url="$BASE_URL" \
  --m7-failed-url="$FAILED_URL" > "$SEED_LOG" 2>&1
SEED_CODE=$?
if [ "$SEED_CODE" -eq 0 ]; then pass "seed process exited 0"; else fail "seed process exited with $SEED_CODE"; fi
if [ "$SEED_CODE" -gt 128 ]; then fail "seed process died from signal $((SEED_CODE - 128))"; fi
check_no_native_browser_process "seed left no residual NativeBrowser process"

for CHECK in \
  real-cef-initial-page-load \
  real-cef-page-a-revisit \
  history-visit-increment \
  history-title \
  history-final-redirect-destination \
  history-does-not-store-provisional-redirect \
  failed-network-load-observed \
  failed-load-excluded-from-history \
  real-cef-download-completed \
  real-cef-second-download-completed \
  download-item-identity \
  download-completed-state \
  download-destination-containment \
  download-collision-safe-second-file \
  download-file-exists \
  download-content-disposition-filenames \
  clean-browser-shutdown \
  cef-shutdown-once; do
  check_contains "self-test: $CHECK" "m7-self-test: pass $CHECK" "$SEED_LOG"
done
check_contains "seed reported zero failures" "m7-self-test: checks=seed failures=0" "$SEED_LOG"
check_absent "fake query secret is absent from seed logs" "$FAKE_SECRET" "$SEED_LOG"
check_absent "fake fragment secret is absent from seed logs" "$FAKE_FRAGMENT" "$SEED_LOG"

HISTORY_DB="$DATA_DIR/history.sqlite3"
if [ -f "$HISTORY_DB" ]; then pass "history database exists"; else fail "history database exists"; fi
if [ -f "$HISTORY_DB" ] && stat -f '%Lp' "$HISTORY_DB" | grep -q '^600$'; then
  pass "history database permissions are 600"
else
  fail "history database permissions are not 600"
fi

python3 - "$HISTORY_DB" "$HOME_URL" "$BASE_URL/page-b" "$FAILED_URL" "$FAKE_SECRET" "$FAKE_FRAGMENT" <<'PY'
import sqlite3
import sys

db, page_a, page_b, failed, secret, fragment = sys.argv[1:]
rows = sqlite3.connect(db).execute(
    "select url, title, visit_count from history_entries"
).fetchall()
by_url = {url: (title, count) for url, title, count in rows}
assert by_url[page_a] == ("Page A", 2), "page A semantics"
assert by_url[page_b] == ("Page B", 2), "page B redirect semantics"
assert failed not in by_url, "failed navigation excluded"
assert not any("/redirect" in url for url in by_url), "redirect URL absent"
assert any(secret in url and fragment in url for url in by_url), "full URL persisted"
PY
if [ "$?" -eq 0 ]; then pass "SQLite rows, title, counts, redirect and exact URL verified"; else fail "SQLite history verification"; fi

PAYLOAD_HASH="$(python3 - <<'PY'
import hashlib
payload = b"NativeBrowser Milestone 7 fixture payload\n" * 1024
print(hashlib.sha256(payload).hexdigest())
PY
)"
python3 - "$DOWNLOADS_DIR" "$PAYLOAD_HASH" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
expected = sys.argv[2]
expected_names = ["fixture.bin", "fixture (1).bin"]
files = [root / name for name in expected_names]
assert {file.name for file in root.iterdir() if file.is_file()} == set(expected_names), "exact fixture filenames"
assert all(file.is_file() for file in files), "two collision-safe files"
for file in files:
    assert file.resolve().parent == root.resolve(), "contained file"
    assert hashlib.sha256(file.read_bytes()).hexdigest() == expected, "payload hash"
PY
if [ "$?" -eq 0 ]; then pass "download bytes/hash, names and containment verified"; else fail "download file verification"; fi

echo
echo "3. real CEF persistence/relaunch process"
VERIFY_LOG="$WORK_DIR/verify.log"
NATIVEBROWSER_DATA_DIR="$DATA_DIR" \
NATIVEBROWSER_DOWNLOADS_DIR="$DOWNLOADS_DIR" \
NATIVEBROWSER_DISABLE_SESSION_PERSISTENCE=1 \
run_with_timeout 180 "$EXECUTABLE" \
  --milestone7-self-test=verify \
  --home-url="$HOME_URL" \
  --m7-fixture-base-url="$BASE_URL" \
  --m7-failed-url="$FAILED_URL" > "$VERIFY_LOG" 2>&1
VERIFY_CODE=$?
if [ "$VERIFY_CODE" -eq 0 ]; then pass "verify process exited 0"; else fail "verify process exited with $VERIFY_CODE"; fi
if [ "$VERIFY_CODE" -gt 128 ]; then fail "verify process died from signal $((VERIFY_CODE - 128))"; fi
check_no_native_browser_process "verify left no residual NativeBrowser process"
for CHECK in history-db-persisted-visit-count history-db-persisted-title history-db-persisted-redirect-result history-db-persisted-failed-load-exclusion real-cef-relaunch-load download-list-is-process-memory-only clean-browser-shutdown cef-shutdown-once; do
  check_contains "relaunch self-test: $CHECK" "m7-self-test: pass $CHECK" "$VERIFY_LOG"
done
check_contains "verify reported zero failures" "m7-self-test: checks=verify failures=0" "$VERIFY_LOG"
check_absent "fake query secret is absent from verify logs" "$FAKE_SECRET" "$VERIFY_LOG"
check_absent "fake fragment secret is absent from verify logs" "$FAKE_FRAGMENT" "$VERIFY_LOG"

echo
echo "Evidence:"
echo "  unit tests: $WORK_DIR/tests.log"
echo "  seed log:   $SEED_LOG"
echo "  verify log: $VERIFY_LOG"
echo "  history DB: $HISTORY_DB"
echo "  downloads:  $DOWNLOADS_DIR"

if [ "$FAILURES" -eq 0 ]; then
  echo "Milestone 7: all automated checks passed"
else
  echo "Milestone 7: $FAILURES check(s) failed"
fi
exit $((FAILURES > 0 ? 1 : 0))
