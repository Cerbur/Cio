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

echo
echo "3. deterministic Release launch and termination smoke"
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
NATIVEBROWSER_DATA_DIR="$DATA_DIR" \
NATIVEBROWSER_DOWNLOADS_DIR="$DOWNLOADS_DIR" \
NATIVEBROWSER_DISABLE_SESSION_PERSISTENCE=1 \
run_with_timeout 120 "$EXECUTABLE" \
    --use-mock-keychain \
    --wait-for-window \
    --quit-after=12 \
    --home-url="$BASE_URL/page-a?code=$FAKE_SECRET#$FAKE_FRAGMENT" > "$SMOKE_LOG" 2>&1
SMOKE_CODE=$?
if [ "$SMOKE_CODE" -eq 0 ]; then pass "Release launch and termination smoke"; else fail "Release launch and termination smoke (exit $SMOKE_CODE)"; fi
check_contains "Release SwiftUI window appeared" "swiftui:main-window-appeared" "$SMOKE_LOG"
check_contains "Release Chromium page loaded" "browser:first-load-finished" "$SMOKE_LOG"
check_contains "Release browsers closed before CEF" "termination:browsers-closed" "$SMOKE_LOG"
check_contains "Release CEF shut down cleanly" "cef:shutdown(clean: true)" "$SMOKE_LOG"
check_absent "Release smoke log omits query secret" "$FAKE_SECRET" "$SMOKE_LOG"
check_absent "Release smoke log omits fragment secret" "$FAKE_FRAGMENT" "$SMOKE_LOG"
check_no_native_browser_process "Release smoke left no residual process"

echo
echo "Evidence:"
echo "  build:  $WORK_DIR/build.log"
echo "  smoke:  $SMOKE_LOG"

if [ "$FAILURES" -eq 0 ]; then
  echo "Release candidate: all automated checks passed"
else
  echo "Release candidate: $FAILURES check(s) failed"
fi
exit $((FAILURES > 0 ? 1 : 0))
