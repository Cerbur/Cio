#!/usr/bin/env bash
# Build an ABI-matched CEF distribution with real H.264/AAC decoding.
# Usage: Scripts/build_cef_codecs.sh [absolute build directory]
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD_DIR="${1:-$REPO_ROOT/build/cef-codecs}"
CEF_COMMIT=708dc140cbc3286826a8abef89dc23a44ff9ea72
AUTOMATE_SHA256=fe0c880fd2a91ac3ab4c82301f596295cecc1901e503507e36300a5b58578dcd

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'error: this recipe targets macOS arm64' >&2
  exit 1
fi
if [[ "$TASK_BUILD_DIR" != /* || "$TASK_BUILD_DIR" == *' '* ]]; then
  echo 'error: CEF automation requires an absolute build path without spaces' >&2
  exit 1
fi
xcrun --find clang >/dev/null
command -v python3 >/dev/null
mkdir -p "$TASK_BUILD_DIR"
# A full Chromium checkout and non-component build need substantial headroom.
# Check before downloading anything; an external SSD can host this directory.
FREE_KIB="$(df -Pk "$TASK_BUILD_DIR" | awk 'NR == 2 { print $4 }')"
if (( FREE_KIB < 200 * 1024 * 1024 )); then
  echo 'error: use a build volume with at least 200 GiB free for Chromium sources and outputs' >&2
  exit 1
fi

AUTOMATE="$TASK_BUILD_DIR/automate-git.py"
curl --fail --location --retry 3 \
  "https://raw.githubusercontent.com/chromiumembedded/cef/$CEF_COMMIT/tools/automate/automate-git.py" \
  -o "$AUTOMATE.partial"
ACTUAL_SHA256="$(shasum -a 256 "$AUTOMATE.partial" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$AUTOMATE_SHA256" ]]; then
  echo 'error: pinned CEF automation checksum mismatch' >&2
  exit 1
fi
mv "$AUTOMATE.partial" "$AUTOMATE"

# These are compile-time flags, not Chromium startup switches. Keep the
# single-framework layout used by our existing runtime packaging script.
export GN_DEFINES='is_official_build=true is_component_build=false is_debug=false symbol_level=0 use_thin_lto=false chrome_pgo_phase=0 proprietary_codecs=true ffmpeg_branding="Chrome"'
export CEF_USE_GN=1
python3 "$AUTOMATE" \
  --download-dir="$TASK_BUILD_DIR" --branch=7977 --checkout="$CEF_COMMIT" \
  --arm64-build --no-debug-build --minimal-distrib-only \
  --no-distrib-docs --no-distrib-symbols --no-distrib-archive \
  --distrib-subdir=nativebrowser-codecs --force-build --force-distrib

CEF_DISTRIBUTION="$TASK_BUILD_DIR/chromium/src/cef/binary_distrib/nativebrowser-codecs"
# Retain the actual compiler configuration alongside the produced runtime.
cp "$TASK_BUILD_DIR/chromium/src/out/Release_GN_arm64/args.gn" \
  "$CEF_DISTRIBUTION/nativebrowser-codecs.args.gn"
"$REPO_ROOT/Scripts/install_cef_runtime.sh" "$CEF_DISTRIBUTION"
cd "$REPO_ROOT"
CONFIGURATION=Debug "$REPO_ROOT/Scripts/build.sh"
