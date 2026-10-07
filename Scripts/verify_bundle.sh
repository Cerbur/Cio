#!/usr/bin/env bash
# Check every signed bundle and runtime linkage without launching Chromium.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
APP="$REPO_ROOT/build/DerivedData/Build/Products/$CONFIGURATION/Cio.app"
FRAMEWORKS="$APP/Contents/Frameworks"
WORK_DIR="$REPO_ROOT/build/verification/bundle"
mkdir -p "$WORK_DIR"
PROBE="$(mktemp "$WORK_DIR/helper-probe.XXXXXX")"
trap 'rm -f "$PROBE"' EXIT
check_linkage() {
  cp "$1" "$PROBE"
  linkage="$(otool -L "$PROBE")"
  if printf '%s' "$linkage" | grep -q 'Chromium Embedded Framework'; then
    echo "FAIL: direct CEF linkage: $1" >&2
    exit 1
  fi
  echo "PASS: runtime CEF loading: $1"
}
actual_app_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[ "$actual_app_id" = "com.cerbur.Cio" ]
codesign --verify --deep --strict "$APP"
codesign --verify --deep --strict "$FRAMEWORKS/Chromium Embedded Framework.framework"
check_linkage "$APP/Contents/MacOS/Cio"
count="$(find "$FRAMEWORKS" -maxdepth 1 -name '*.app' -type d | wc -l | tr -d ' ')"
[ "$count" -eq 5 ] || { echo "FAIL: expected five Helpers, found $count" >&2; exit 1; }
suffixes=("" " (Alerts)" " (GPU)" " (Plugin)" " (Renderer)")
ids=("" ".alerts" ".gpu" ".plugin" ".renderer")
for index in "${!suffixes[@]}"; do
  name="Cio Helper${suffixes[$index]}"
  helper="$FRAMEWORKS/$name.app"
  codesign --verify --deep --strict "$helper"
  actual_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$helper/Contents/Info.plist")"
  [ "$actual_id" = "com.cerbur.Cio.helper${ids[$index]}" ]
  actual_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$helper/Contents/Info.plist")"
  [ "$actual_executable" = "$name" ]
  check_linkage "$helper/Contents/MacOS/$name"
done
echo "PASS: App, framework and all five Helpers; signatures, identities and linkage"
