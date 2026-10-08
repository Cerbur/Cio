#!/usr/bin/env bash
# Fetch only the pinned native-bridge reference, not Chromium dependencies.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REFERENCE_DIR="$REPO_ROOT/build/EngineResearch/mori-browser"
REFERENCE_REPOSITORY=https://github.com/FujiwaraChoki/mori-browser.git
REFERENCE_REVISION=b5b29c2e29061f9b2009e8cc0b2756c6ad62bb20

if [ -e "$REFERENCE_DIR" ]; then
  if [ ! -d "$REFERENCE_DIR/.git" ]; then
    echo "error: reference path already exists and is not a Git checkout" >&2
    exit 1
  fi
  if [ "$(git -C "$REFERENCE_DIR" rev-parse HEAD)" != "$REFERENCE_REVISION" ] ||
     [ -n "$(git -C "$REFERENCE_DIR" status --porcelain)" ]; then
    echo "error: preserving an existing reference checkout with another revision or local changes" >&2
    exit 1
  fi
else
  mkdir -p "$(dirname "$REFERENCE_DIR")"
  git init "$REFERENCE_DIR"
  git -C "$REFERENCE_DIR" remote add origin "$REFERENCE_REPOSITORY"
  git -C "$REFERENCE_DIR" fetch --depth 1 origin "$REFERENCE_REVISION"
  git -C "$REFERENCE_DIR" checkout --detach FETCH_HEAD
fi

test -f "$REFERENCE_DIR/LICENSE"
test -f "$REFERENCE_DIR/ungoogled-chromium-macos/build/src/chrome/browser/ui/mori/mori_chrome_bridge.mm"
echo "Pinned reference: $REFERENCE_DIR ($REFERENCE_REVISION)"
echo "Pinned upstream reference: two BrowserWindow files are adapted in Engine/CioChromium/Native; this checkout does not include a complete Chromium build tree."
