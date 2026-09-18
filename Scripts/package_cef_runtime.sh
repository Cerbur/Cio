#!/usr/bin/env bash
#
# Assembles the CEF runtime inside the built application bundle:
#
#   NativeBrowser.app/Contents/Frameworks/
#   |- Chromium Embedded Framework.framework
#   |- NativeBrowser Helper.app
#   |- NativeBrowser Helper (Alerts).app
#   |- NativeBrowser Helper (GPU).app
#   |- NativeBrowser Helper (Plugin).app
#   - NativeBrowser Helper (Renderer).app
#
# The layout follows CEF's own cmake helpers (cmake/cef_macros.cmake
# COPY_MAC_FRAMEWORK and tests/cefsimple/CMakeLists.txt): the framework is
# stored in the versioned framework layout, and the helper applications are
# thin bundles around the NativeBrowserHelper executable.
#
# Runs as the app target's last build phase, so that the assembled bundle is
# what Xcode signs afterwards.
#
set -euo pipefail

APP_BUNDLE="$BUILT_PRODUCTS_DIR/$WRAPPER_NAME"
CONTENTS="$APP_BUNDLE/Contents"
FRAMEWORKS_DIR="$CONTENTS/Frameworks"
CEF_ROOT="$SRCROOT/ThirdParty/CEF"
CEF_RELEASE="$CEF_ROOT/Release"
FRAMEWORK_NAME="Chromium Embedded Framework.framework"
APP_NAME="$WRAPPER_NAME"
APP_NAME="${APP_NAME%.app}"
HELPER_PRODUCT="$BUILT_PRODUCTS_DIR/NativeBrowserHelper"
BUNDLE_ID="$PRODUCT_BUNDLE_IDENTIFIER"
MINIMUM_SYSTEM_VERSION="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
CEF_VERSION="$(sed -n 's/^#define CEF_VERSION "\(.*\)"/\1/p' "$CEF_ROOT/include/cef_version.h")"

if [ ! -d "$CEF_RELEASE/$FRAMEWORK_NAME" ]; then
  echo "error: $CEF_RELEASE/$FRAMEWORK_NAME is missing; run Scripts/fetch_cef.sh" >&2
  exit 1
fi
if [ ! -x "$HELPER_PRODUCT" ]; then
  echo "error: helper executable not found at $HELPER_PRODUCT" >&2
  exit 1
fi

mkdir -p "$FRAMEWORKS_DIR"

# ---------------------------------------------------------------------------
# 1. Chromium Embedded Framework (versioned layout, as CEF's COPY_MAC_FRAMEWORK)
# ---------------------------------------------------------------------------
FRAMEWORK_DIR="$FRAMEWORKS_DIR/$FRAMEWORK_NAME"
rm -rf "$FRAMEWORK_DIR"
mkdir -p "$FRAMEWORK_DIR/Versions/A"
ditto "$CEF_RELEASE/$FRAMEWORK_NAME" "$FRAMEWORK_DIR/Versions/A"
ln -sfn "Versions/A/Chromium Embedded Framework" "$FRAMEWORK_DIR/Chromium Embedded Framework"
ln -sfn "Versions/A/Libraries" "$FRAMEWORK_DIR/Libraries"
ln -sfn "Versions/A/Resources" "$FRAMEWORK_DIR/Resources"
ln -sfn "A" "$FRAMEWORK_DIR/Versions/Current"

# ---------------------------------------------------------------------------
# 2. Helper applications
#
#    CEF launches a helper as
#    "<app> Helper<suffix>.app/Contents/MacOS/<app> Helper<suffix>"; the helper
#    loads the framework with "../../.." from its executable directory, so it
#    shares the single framework copy above.
# ---------------------------------------------------------------------------
HELPER_SUFFIXES=("" " (Alerts)" " (GPU)" " (Plugin)" " (Renderer)")
HELPER_ID_SUFFIXES=("" ".alerts" ".gpu" ".plugin" ".renderer")

# Remove helper bundles from previous builds so renames never leave strays.
find "$FRAMEWORKS_DIR" -maxdepth 1 -name "$APP_NAME Helper*.app" -exec rm -rf {} +

for INDEX in "${!HELPER_SUFFIXES[@]}"; do
  SUFFIX="${HELPER_SUFFIXES[$INDEX]}"
  ID_SUFFIX="${HELPER_ID_SUFFIXES[$INDEX]}"
  HELPER_NAME="$APP_NAME Helper$SUFFIX"
  HELPER_BUNDLE="$FRAMEWORKS_DIR/$HELPER_NAME.app"

  mkdir -p "$HELPER_BUNDLE/Contents/MacOS"
  cp "$HELPER_PRODUCT" "$HELPER_BUNDLE/Contents/MacOS/$HELPER_NAME"
  printf 'APPL????' > "$HELPER_BUNDLE/Contents/PkgInfo"

  cat > "$HELPER_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>$HELPER_NAME</string>
	<key>CFBundleExecutable</key>
	<string>$HELPER_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID.helper$ID_SUFFIX</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$HELPER_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSEnvironment</key>
	<dict>
		<key>MallocNanoZone</key>
		<string>0</string>
	</dict>
	<key>LSFileQuarantineEnabled</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>$MINIMUM_SYSTEM_VERSION</string>
	<key>LSUIElement</key>
	<string>1</string>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
</dict>
</plist>
PLIST
done

# ---------------------------------------------------------------------------
# 3. Sign nested code (inside out) when signing is enabled. Xcode signs the
#    outer app bundle itself after this phase.
# ---------------------------------------------------------------------------
SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ] && [ -n "$SIGN_IDENTITY" ]; then
  SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --timestamp=none)
  if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = "YES" ]; then
    SIGN_ARGS+=(--options runtime)
  fi
  echo "Signing CEF runtime with identity '$SIGN_IDENTITY' ..."
  codesign "${SIGN_ARGS[@]}" "$FRAMEWORK_DIR/Versions/A/Libraries/"*.dylib 2>/dev/null || true
  codesign "${SIGN_ARGS[@]}" "$FRAMEWORK_DIR"
  for INDEX in "${!HELPER_SUFFIXES[@]}"; do
    codesign "${SIGN_ARGS[@]}" "$FRAMEWORKS_DIR/$APP_NAME Helper${HELPER_SUFFIXES[$INDEX]}.app"
  done

  # Xcode signs the outer bundle after this phase. Its code signing task can be
  # skipped on incremental builds (the nested runtime is not part of the target's
  # file list), so refresh a seal that no longer covers what was just packaged.
  #
  # This is best effort and never fails the build: on a clean build the app is
  # not signed yet and Xcode signs it right after this phase.
  if [ -d "$CONTENTS/_CodeSignature" ] &&
     ! codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null 2>&1; then
    ENTITLEMENTS="$TARGET_TEMP_DIR/$WRAPPER_NAME.xcent"
    if [ -f "$ENTITLEMENTS" ]; then
      SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
    fi
    echo "Refreshing the application signature (nested runtime changed) ..."
    codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE" ||
      echo "note: signature refresh skipped; Xcode signs the bundle after this phase"
  fi
else
  echo "Skipping nested code signing (CODE_SIGNING_ALLOWED=NO)."
fi

echo "Packaged CEF $CEF_VERSION into $FRAMEWORKS_DIR"
ls -1 "$FRAMEWORKS_DIR"
