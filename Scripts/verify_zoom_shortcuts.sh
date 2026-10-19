#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
mkdir -p build/validation
xcrun clang++ -std=c++20 -fobjc-arc -framework AppKit -I "$REPO_ROOT" \
  Engine/CioChromium/Tests/ZoomShortcutTest.mm -o build/validation/ZoomShortcutTest
build/validation/ZoomShortcutTest
