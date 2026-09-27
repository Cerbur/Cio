#!/usr/bin/env bash
#
# One-shot build: regenerate the Xcode project from project.yml and build the
# app with xcodebuild into ./build (DerivedData stays inside the repository so
# that sandboxed and CI builds never touch ~/Library).
#
#   Scripts/build.sh [extra xcodebuild arguments]
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA="${DERIVED_DATA:-$REPO_ROOT/build/DerivedData}"

cd "$REPO_ROOT"

if [ ! -f "$REPO_ROOT/ThirdParty/CEF/include/cef_app.h" ]; then
  "$REPO_ROOT/Scripts/fetch_cef.sh"
fi

xcodegen generate
# XcodeGen's generated scheme has no TestAction, so the shared scheme from
# SchemeTemplates/ (which includes the Milestone 2 unit tests) is installed
# before xcodebuild reads it.
"$REPO_ROOT/Scripts/sync_scheme.sh"

xcodebuild \
  -project "$REPO_ROOT/NativeBrowser.xcodeproj" \
  -scheme NativeBrowser \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build \
  "$@"

APP_EXECUTABLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/NativeBrowser.app/Contents/MacOS/NativeBrowser"
if command -v pgrep >/dev/null 2>&1; then
  while IFS= read -r pid; do
    running_command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$running_command" in
      "$APP_EXECUTABLE"|"$APP_EXECUTABLE "*)
        printf '\nBuilt %s, but NativeBrowser is already running (PID %s). Quit and reopen it to use this build.\n' \
          "$APP_EXECUTABLE" "$pid"
        break
        ;;
    esac
  done < <(pgrep -x NativeBrowser 2>/dev/null || true)
fi
