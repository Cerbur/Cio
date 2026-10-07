#!/usr/bin/env bash
# Compatibility entry point. Current verification is named by responsibility.
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/verify_tabs.sh" "$@"
