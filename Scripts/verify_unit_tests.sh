#!/usr/bin/env bash
# Run the standalone XCTest bundle and tests of extracted local packages.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
WORK_DIR="$REPO_ROOT/build/verification/unit-tests"
LOG="${1:-$WORK_DIR/tests.log}"
mkdir -p "$WORK_DIR" "$(dirname "$LOG")"
CONFIGURATION="$CONFIGURATION" "$REPO_ROOT/Scripts/build.sh" build-for-testing > "$WORK_DIR/build.log" 2>&1
xcrun xctest "$REPO_ROOT/build/DerivedData/Build/Products/$CONFIGURATION/NativeBrowserTests.xctest" > "$LOG" 2>&1
for package in "$REPO_ROOT"/Packages/*; do
  [ -d "$package/Tests" ] || continue
  package_name="$(basename "$package")"
  package_log="$WORK_DIR/$package_name.log"
  if ! swift test --package-path "$package" --scratch-path "$REPO_ROOT/build/PackageTests/$package_name" > "$package_log" 2>&1; then
    cat "$package_log" >> "$LOG"
    echo "FAIL: $package_name tests; see $LOG" >&2
    exit 1
  fi
  cat "$package_log" >> "$LOG"
done
echo "PASS: standalone XCTest and local package tests; evidence: $LOG"
