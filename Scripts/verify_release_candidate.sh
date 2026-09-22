#!/usr/bin/env bash
#
# Build and exercise the locally signed Release candidate. This deliberately
# does not require a Developer ID identity, notarization, stapling or an
# archive/DMG; those are Milestone 9 work.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO_ROOT/build/DerivedData/Build/Products/Release/NativeBrowser.app"
EXECUTABLE="$APP/Contents/MacOS/NativeBrowser"
DATA_DIR="${DATA_DIR:-$REPO_ROOT/build/verification-data/release-candidate}"
DOWNLOADS_DIR="${DOWNLOADS_DIR:-$REPO_ROOT/build/verification-downloads/release-candidate}"
WORK_DIR="$REPO_ROOT/build/verification/release-candidate"
PORT="${M8_RELEASE_FIXTURE_PORT:-43127}"
BASE_URL="http://127.0.0.1:$PORT"
FAKE_SECRET="release-fake-secret"
FAKE_FRAGMENT="release-fragment-secret"
HOME_URL="$BASE_URL/page-a?code=$FAKE_SECRET#$FAKE_FRAGMENT"
FAILED_URL="http://127.0.0.1:9/release-failed"
SMOKE_DATA_DIR="$DATA_DIR/smoke"
HISTORY_DATA_DIR="$DATA_DIR/history"
RESTORE_DATA_DIR="$DATA_DIR/session-restore"
SMOKE_DOWNLOADS_DIR="$DOWNLOADS_DIR/smoke"
HISTORY_DOWNLOADS_DIR="$DOWNLOADS_DIR/history"
RESTORE_DOWNLOADS_DIR="$DOWNLOADS_DIR/session-restore"
RESTORE_HOME_URL="https://example.com/?code=$FAKE_SECRET#$FAKE_FRAGMENT"

FAILURES=0
FIXTURE_PID=""
pass() { printf '  [pass] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

check_contains() {
  if grep -qF -e "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1 (missing: $2)"; fi
}

check_absent() {
  if grep -qF -e "$2" "$3" 2>/dev/null; then fail "$1 (sensitive value found)"; else pass "$1"; fi
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
  "$@" &
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

cleanup() {
  if [ -n "$FIXTURE_PID" ]; then
    kill "$FIXTURE_PID" 2>/dev/null || true
    wait "$FIXTURE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

rm -rf "$DATA_DIR" "$DOWNLOADS_DIR" "$WORK_DIR"
mkdir -p "$DATA_DIR" "$DOWNLOADS_DIR" "$WORK_DIR"

echo "Release candidate verification"
echo "app: $APP"
echo

echo "1. clean Release build"
if xcodegen generate > "$WORK_DIR/xcodegen.log" 2>&1 \
  && "$REPO_ROOT/Scripts/sync_scheme.sh" > "$WORK_DIR/scheme.log" 2>&1 \
  && xcodebuild \
       -project "$REPO_ROOT/NativeBrowser.xcodeproj" \
       -scheme NativeBrowser \
       -configuration Release \
       -derivedDataPath "$REPO_ROOT/build/DerivedData" \
       clean build > "$WORK_DIR/build.log" 2>&1; then
  pass "Release build succeeded"
else
  fail "Release build failed"
fi

echo
echo "2. bundle structure and identity"
if [ -d "$APP" ]; then pass "Release app exists"; else fail "Release app exists"; fi
if [ -x "$EXECUTABLE" ]; then pass "Release executable exists"; else fail "Release executable exists"; fi
FRAMEWORK="$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
if [ -d "$FRAMEWORK" ]; then pass "CEF framework is packaged"; else fail "CEF framework is packaged"; fi

EXPECTED_HELPERS=(
  "NativeBrowser Helper.app"
  "NativeBrowser Helper (Alerts).app"
  "NativeBrowser Helper (GPU).app"
  "NativeBrowser Helper (Plugin).app"
  "NativeBrowser Helper (Renderer).app"
)
for helper in "${EXPECTED_HELPERS[@]}"; do
  helper_path="$APP/Contents/Frameworks/$helper"
  helper_exec="$helper_path/Contents/MacOS/${helper%.app}"
  if [ -d "$helper_path" ] && [ -x "$helper_exec" ]; then
    pass "helper packaged: $helper"
  else
    fail "helper packaged: $helper"
  fi
done

APP_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
APP_BUILD="$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [ "$APP_VERSION" = "0.1.0" ]; then pass "marketing version is 0.1.0"; else fail "marketing version is 0.1.0 (got $APP_VERSION)"; fi
if [ "$APP_BUILD" = "1" ]; then pass "build number is 1"; else fail "build number is 1 (got $APP_BUILD)"; fi
if file "$EXECUTABLE" 2>/dev/null | grep -q 'arm64'; then pass "Release executable is arm64"; else fail "Release executable architecture"; fi
if codesign --verify --deep --strict "$APP" > "$WORK_DIR/codesign-verify.log" 2>&1; then
  pass "local code signature verifies"
else
  fail "local code signature verifies"
fi
CODE_SIGNATURE_DETAILS="$(codesign -d --verbose=4 "$APP" 2>&1 || true)"
if printf '%s\n' "$CODE_SIGNATURE_DETAILS" | grep -q 'flags=.*runtime'; then
  pass "hardened runtime option is present"
else
  fail "hardened runtime option is present"
fi
if codesign -d --entitlements :- "$APP" 2>"$WORK_DIR/entitlements.log" | grep -q 'get-task-allow'; then
  fail "Release does not carry get-task-allow"
else
  pass "Release does not carry get-task-allow"
fi
codesign -d --entitlements :- "$APP" > "$WORK_DIR/entitlements.plist" 2>/dev/null || true
for entitlement in \
  com.apple.security.cs.allow-jit \
  com.apple.security.cs.disable-library-validation; do
  if grep -qF "$entitlement" "$WORK_DIR/entitlements.plist" 2>/dev/null; then
    pass "Release entitlement present: $entitlement"
  else
    fail "Release entitlement present: $entitlement"
  fi
done

echo
echo "Entitlement evidence (local ad-hoc CEF candidate)"
echo "  com.apple.security.cs.allow-jit: required by CEF/V8 executable JIT; retest after M9 Developer ID signing"
echo "  com.apple.security.cs.allow-unsigned-executable-memory: not required by this installed CEF build; isolated removal still passed CEF/V8 page execution and beforeunload integration"
echo "  com.apple.security.cs.disable-library-validation: required by the ad-hoc nested CEF framework; retest after M9 Developer ID signing"

echo
echo "3. Release fixture and deterministic launch"
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

SMOKE_LOG="$WORK_DIR/smoke.log"
NATIVEBROWSER_DATA_DIR="$SMOKE_DATA_DIR" \
NATIVEBROWSER_DOWNLOADS_DIR="$SMOKE_DOWNLOADS_DIR" \
NATIVEBROWSER_DISABLE_SESSION_PERSISTENCE=0 \
run_with_timeout 120 "$EXECUTABLE" \
    --use-mock-keychain \
    --wait-for-window \
    --quit-after=12 \
    --home-url="$HOME_URL" > "$SMOKE_LOG" 2>&1
SMOKE_CODE=$?
if [ "$SMOKE_CODE" -eq 0 ]; then pass "Release launch and termination smoke"; else fail "Release launch and termination smoke (exit $SMOKE_CODE)"; fi
check_contains "Release SwiftUI window appeared" "swiftui:main-window-appeared" "$SMOKE_LOG"
check_contains "Release Chromium page loaded" "browser:first-load-finished" "$SMOKE_LOG"
check_contains "Release browsers closed before CEF" "termination:browsers-closed" "$SMOKE_LOG"
check_contains "Release CEF shut down cleanly" "cef:shutdown(clean: true)" "$SMOKE_LOG"
check_contains "Release has no implicit mock keychain" "mock-keychain: implicit=no explicit=yes" "$SMOKE_LOG"
check_absent "Release smoke log omits query secret" "$FAKE_SECRET" "$SMOKE_LOG"
check_absent "Release smoke log omits fragment secret" "$FAKE_FRAGMENT" "$SMOKE_LOG"
check_no_native_browser_process "Release smoke left no residual process"

echo
echo "4. Release History and Downloads"
HISTORY_SEED_LOG="$WORK_DIR/history-seed.log"
NATIVEBROWSER_DATA_DIR="$HISTORY_DATA_DIR" \
NATIVEBROWSER_DOWNLOADS_DIR="$HISTORY_DOWNLOADS_DIR" \
NATIVEBROWSER_DISABLE_SESSION_PERSISTENCE=0 \
run_with_timeout 240 "$EXECUTABLE" \
  --use-mock-keychain \
  --milestone7-self-test=seed \
  --home-url="$HOME_URL" \
  --m7-fixture-base-url="$BASE_URL" \
  --m7-failed-url="$FAILED_URL" > "$HISTORY_SEED_LOG" 2>&1
HISTORY_SEED_CODE=$?
if [ "$HISTORY_SEED_CODE" -eq 0 ]; then pass "Release History/Downloads seed exited 0"; else fail "Release History/Downloads seed exited $HISTORY_SEED_CODE"; fi
for check in \
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
  check_contains "Release self-test: $check" "m7-self-test: pass $check" "$HISTORY_SEED_LOG"
done
check_contains "Release History/Downloads seed had zero failures" \
  "m7-self-test: checks=seed failures=0" "$HISTORY_SEED_LOG"
check_absent "Release History log omits query secret" "$FAKE_SECRET" "$HISTORY_SEED_LOG"
check_absent "Release History log omits fragment secret" "$FAKE_FRAGMENT" "$HISTORY_SEED_LOG"
check_no_native_browser_process "Release History/Downloads seed left no residual process"

HISTORY_DB="$HISTORY_DATA_DIR/history.sqlite3"
if [ -f "$HISTORY_DB" ]; then pass "Release History database exists"; else fail "Release History database exists"; fi
if [ -f "$HISTORY_DB" ] && stat -f '%Lp' "$HISTORY_DB" | grep -q '^600$'; then
  pass "Release History database permissions are 600"
else
  fail "Release History database permissions are not 600"
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
if [ "$?" -eq 0 ]; then pass "Release SQLite rows, title, counts, redirect and exact URL verified"; else fail "Release SQLite History verification"; fi

PAYLOAD_HASH="$(python3 - <<'PY'
import hashlib
payload = b"NativeBrowser Milestone 7 fixture payload\n" * 1024
print(hashlib.sha256(payload).hexdigest())
PY
)"
python3 - "$HISTORY_DOWNLOADS_DIR" "$PAYLOAD_HASH" <<'PY'
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
if [ "$?" -eq 0 ]; then pass "Release download bytes/hash, names and containment verified"; else fail "Release download file verification"; fi

HISTORY_VERIFY_LOG="$WORK_DIR/history-verify.log"
NATIVEBROWSER_DATA_DIR="$HISTORY_DATA_DIR" \
NATIVEBROWSER_DOWNLOADS_DIR="$HISTORY_DOWNLOADS_DIR" \
NATIVEBROWSER_DISABLE_SESSION_PERSISTENCE=0 \
run_with_timeout 180 "$EXECUTABLE" \
  --use-mock-keychain \
  --milestone7-self-test=verify \
  --home-url="$HOME_URL" \
  --m7-fixture-base-url="$BASE_URL" \
  --m7-failed-url="$FAILED_URL" > "$HISTORY_VERIFY_LOG" 2>&1
HISTORY_VERIFY_CODE=$?
if [ "$HISTORY_VERIFY_CODE" -eq 0 ]; then pass "Release History/Downloads verify exited 0"; else fail "Release History/Downloads verify exited $HISTORY_VERIFY_CODE"; fi
for check in \
  history-db-persisted-visit-count \
  history-db-persisted-title \
  history-db-persisted-redirect-result \
  history-db-persisted-failed-load-exclusion \
  real-cef-relaunch-load \
  download-list-is-process-memory-only \
  clean-browser-shutdown \
  cef-shutdown-once; do
  check_contains "Release relaunch self-test: $check" "m7-self-test: pass $check" "$HISTORY_VERIFY_LOG"
done
check_contains "Release History/Downloads verify had zero failures" \
  "m7-self-test: checks=verify failures=0" "$HISTORY_VERIFY_LOG"
check_absent "Release History verify log omits query secret" "$FAKE_SECRET" "$HISTORY_VERIFY_LOG"
check_absent "Release History verify log omits fragment secret" "$FAKE_FRAGMENT" "$HISTORY_VERIFY_LOG"
check_no_native_browser_process "Release History/Downloads verify left no residual process"

echo
echo "5. Release session restore and lazy activation"
RESTORE_SEED_LOG="$WORK_DIR/session-restore-seed.log"
NATIVEBROWSER_DATA_DIR="$RESTORE_DATA_DIR" \
NATIVEBROWSER_DOWNLOADS_DIR="$RESTORE_DOWNLOADS_DIR" \
NATIVEBROWSER_DISABLE_SESSION_PERSISTENCE=0 \
run_with_timeout 300 "$EXECUTABLE" \
  --use-mock-keychain \
  --session-restore-self-test=seed \
  --home-url="$RESTORE_HOME_URL" > "$RESTORE_SEED_LOG" 2>&1
RESTORE_SEED_CODE=$?
if [ "$RESTORE_SEED_CODE" -eq 0 ]; then pass "Release session-restore seed exited 0"; else fail "Release session-restore seed exited $RESTORE_SEED_CODE"; fi
for check in seeded-three-spaces-and-two-tabs seed-runtimes-created seed-clean-shutdown; do
  check_contains "Release restore seed: $check" "session-restore-self-test: pass $check" "$RESTORE_SEED_LOG"
done
check_contains "Release restore seed persisted six domain tabs" "domain-tabs=6" "$RESTORE_SEED_LOG"
check_no_native_browser_process "Release session-restore seed left no residual process"

RESTORE_VERIFY_LOG="$WORK_DIR/session-restore-verify.log"
NATIVEBROWSER_DATA_DIR="$RESTORE_DATA_DIR" \
NATIVEBROWSER_DOWNLOADS_DIR="$RESTORE_DOWNLOADS_DIR" \
NATIVEBROWSER_DISABLE_SESSION_PERSISTENCE=0 \
run_with_timeout 300 "$EXECUTABLE" \
  --use-mock-keychain \
  --session-restore-self-test=verify \
  --home-url="$RESTORE_HOME_URL" > "$RESTORE_VERIFY_LOG" 2>&1
RESTORE_VERIFY_CODE=$?
if [ "$RESTORE_VERIFY_CODE" -eq 0 ]; then pass "Release session-restore verify exited 0"; else fail "Release session-restore verify exited $RESTORE_VERIFY_CODE"; fi
for check in \
  startup-restored-domain-before-lazy-activation \
  startup-selected-tab-only-runtime \
  startup-selected-browser-ready \
  startup-space-order-and-selections-restored \
  startup-urls-and-titles-restored \
  lazy-tab-had-no-session-before-selection \
  lazy-tab-created-on-first-activation \
  switching-back-reuses-both-sessions \
  lazy-space-selected-tab-had-no-session \
  lazy-space-instantiates-only-remembered-tab \
  closing-lazy-tab-does-not-create-runtime \
  verify-clean-shutdown; do
  check_contains "Release restore verify: $check" "session-restore-self-test: pass $check" "$RESTORE_VERIFY_LOG"
done
check_contains "Release restore starts with one live session" \
  "spaces=3 domain-tabs=6 live-sessions=1" "$RESTORE_VERIFY_LOG"
check_contains "Release restore closes instantiated sessions before CEF" \
  "lifecycle: session:close-all(count=3)" "$RESTORE_VERIFY_LOG"
check_contains "Release restore shuts CEF down cleanly" \
  "lifecycle: cef:shutdown(clean: true)" "$RESTORE_VERIFY_LOG"
check_no_native_browser_process "Release session-restore verify left no residual process"

echo
echo "Evidence:"
echo "  build:          $WORK_DIR/build.log"
echo "  smoke:          $SMOKE_LOG"
echo "  History seed:   $HISTORY_SEED_LOG"
echo "  History verify: $HISTORY_VERIFY_LOG"
echo "  restore seed:   $RESTORE_SEED_LOG"
echo "  restore verify: $RESTORE_VERIFY_LOG"

if [ "$FAILURES" -eq 0 ]; then
  echo "Release candidate: all automated checks passed"
else
  echo "Release candidate: $FAILURES check(s) failed"
fi
exit $((FAILURES > 0 ? 1 : 0))
