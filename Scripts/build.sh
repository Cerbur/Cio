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

xcodebuild \
  -project "$REPO_ROOT/NativeBrowser.xcodeproj" \
  -scheme NativeBrowser \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build \
  "$@"
