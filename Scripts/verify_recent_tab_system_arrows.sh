#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
PRODUCTS="$REPO_ROOT/build/DerivedData/Build/Products/Debug"
mkdir -p build/validation build/ModuleCache
xcrun swiftc -swift-version 6 -parse-as-library -target arm64-apple-macos26.0 \
  -module-cache-path "$REPO_ROOT/build/ModuleCache" -I "$PRODUCTS" -F "$PRODUCTS" \
  Cio/Browser/RecentTabSwitcherArrowKeys.swift Scripts/RecentTabSystemArrowProbe.swift \
  "$PRODUCTS/CioModel.o" -o build/validation/RecentTabSystemArrowProbe
build/validation/RecentTabSystemArrowProbe
