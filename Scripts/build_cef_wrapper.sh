#!/usr/bin/env bash
#
# Builds libcef_dll_wrapper.a, the CEF C++ wrapper library that every CEF
# client links. The binary CEF distribution ships the wrapper sources but no
# prebuilt library, so they are compiled here.
#
# The source list is discovered by globbing libcef_dll; that set is identical to
# the one in libcef_dll/CMakeLists.txt (verified for CEF 152) and survives CEF
# upgrades without hard-coding file names.
#
# Runs as an Xcode pre-build phase and is safe to run by hand:
#   Scripts/build_cef_wrapper.sh
#
set -euo pipefail

# Xcode runs build phases from a generated script inside DerivedData, so the
# repository root comes from SRCROOT there and from the script location when run
# by hand.
if [ -n "${SRCROOT:-}" ]; then
  REPO_ROOT="$SRCROOT"
else
  REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi
CEF_ROOT="$REPO_ROOT/ThirdParty/CEF"
BUILD_DIR="$REPO_ROOT/ThirdParty/wrapper-build"
OBJECT_DIR="$BUILD_DIR/obj"
LIBRARY="$REPO_ROOT/ThirdParty/libcef_dll_wrapper.a"

if [ ! -f "$CEF_ROOT/include/cef_app.h" ]; then
  echo "note: CEF distribution not found; fetching it first"
  "$REPO_ROOT/Scripts/fetch_cef.sh"
fi

# ---------------------------------------------------------------------------
# Up-to-date check: rebuild only when a wrapper source or CEF header is newer
# than the library itself.
# ---------------------------------------------------------------------------
if [ -f "$LIBRARY" ]; then
  NEWER="$(find "$CEF_ROOT/libcef_dll" "$CEF_ROOT/include" -type f \( -name '*.cc' -o -name '*.mm' -o -name '*.h' \) -newer "$LIBRARY" -print -quit)"
  if [ -z "$NEWER" ]; then
    echo "libcef_dll_wrapper.a is up to date"
    exit 0
  fi
fi

mkdir -p "$OBJECT_DIR"
JOBS="$(sysctl -n hw.ncpu)"
SOURCE_COUNT="$(find "$CEF_ROOT/libcef_dll" -type f \( -name '*.cc' -o -name '*.mm' \) | wc -l | tr -d ' ')"

echo "Compiling $SOURCE_COUNT CEF wrapper sources (jobs: $JOBS) ..."
find "$CEF_ROOT/libcef_dll" -type f \( -name '*.cc' -o -name '*.mm' \) -print0 \
  | xargs -0 -P "$JOBS" -I '{}' "$REPO_ROOT/Scripts/compile_cef_wrapper_source.sh" "$CEF_ROOT" '{}' "$OBJECT_DIR"

echo "Archiving $LIBRARY ..."
rm -f "$LIBRARY"
if xcrun --find libtool >/dev/null 2>&1; then
  xcrun libtool -static -no_warning_for_no_symbols -o "$LIBRARY" "$OBJECT_DIR"/*.o
else
  ar rcs "$LIBRARY" "$OBJECT_DIR"/*.o
fi

echo "Built libcef_dll_wrapper.a ($(du -h "$LIBRARY" | cut -f1))"
