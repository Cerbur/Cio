#!/usr/bin/env bash
#
# Downloads and extracts the CEF binary distribution used by NativeBrowser.
#
# The distribution is not committed to the repository; run this script once
# after cloning. The result lands in ThirdParty/CEF and is picked up by
# Scripts/build_cef_wrapper.sh and Scripts/package_cef_runtime.sh.
#
# Usage:
#   Scripts/fetch_cef.sh            # download + extract if needed
#   CEF_VERSION=152.0.6+g... Scripts/fetch_cef.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CEF_ROOT="$REPO_ROOT/ThirdParty/CEF"

# Pinned CEF build (stable channel, macOS arm64).
CEF_VERSION="${CEF_VERSION:-152.0.6+g708dc14+chromium-152.0.7977.83}"
CEF_PLATFORM="${CEF_PLATFORM:-macosarm64}"
CEF_SHA1="${CEF_SHA1:-a614e0f6eab52bd43f3c2823c06d631bb64b2aa9}"
CEF_BASE_URL="${CEF_BASE_URL:-https://cef-builds.spotifycdn.com}"
ARCHIVE="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}.tar.bz2"

if [[ -d "$CEF_ROOT" && -f "$CEF_ROOT/include/cef_app.h" ]]; then
  echo "CEF already present at $CEF_ROOT"
  exit 0
fi

mkdir -p "$REPO_ROOT/ThirdParty"
CACHE="$REPO_ROOT/ThirdParty/.cache"
mkdir -p "$CACHE"

if [[ ! -f "$CACHE/$ARCHIVE" ]]; then
  echo "Downloading $ARCHIVE ..."
  curl --fail --location --retry 3 --progress-bar \
    -o "$CACHE/$ARCHIVE.partial" \
    "$CEF_BASE_URL/$ARCHIVE"
  mv "$CACHE/$ARCHIVE.partial" "$CACHE/$ARCHIVE"
fi

echo "Verifying checksum ..."
ACTUAL_SHA1="$(shasum -a 1 "$CACHE/$ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL_SHA1" != "$CEF_SHA1" ]]; then
  echo "error: checksum mismatch for $ARCHIVE" >&2
  echo "  expected: $CEF_SHA1" >&2
  echo "  actual:   $ACTUAL_SHA1" >&2
  exit 1
fi

echo "Extracting to $CEF_ROOT ..."
mkdir -p "$CEF_ROOT"
tar -xjf "$CACHE/$ARCHIVE" -C "$CEF_ROOT" --strip-components=1

if [[ ! -f "$CEF_ROOT/include/cef_app.h" ]]; then
  echo "error: extraction did not produce a CEF distribution" >&2
  exit 1
fi

echo "CEF ${CEF_VERSION} ready at $CEF_ROOT"
