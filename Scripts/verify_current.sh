#!/usr/bin/env bash
# Complete validation of the current design. Stop on the first new failure.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
CONFIGURATION="${CONFIGURATION:-Debug}"
export CONFIGURATION
Scripts/build.sh
Scripts/verify_unit_tests.sh
for responsibility in runtime rendering navigation tabs workspace session_restore history_downloads stability; do
  "Scripts/verify_$responsibility.sh"
done
# Release's clean action removes Debug products too. Leave a fresh Debug app.
Scripts/build.sh
Scripts/verify_bundle.sh
Scripts/check_no_secrets.sh
