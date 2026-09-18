#!/usr/bin/env bash
#
# Compiles a single CEF wrapper source file into an object file.
#
#   compile_cef_wrapper_source.sh <cef-root> <source-file> <object-directory>
#
# Invoked in parallel by Scripts/build_cef_wrapper.sh.
set -euo pipefail

CEF_ROOT="$1"
SOURCE="$2"
OBJECT_DIR="$3"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
CXX="$(xcrun --find clang++)"

RELATIVE="$(printf '%s' "$SOURCE" | sed "s|^$CEF_ROOT/||")"
OBJECT="$OBJECT_DIR/$(printf '%s' "$RELATIVE" | tr '/' '_').o"

exec "$CXX" \
  -std=c++20 \
  -mmacosx-version-min=12.0 \
  -isysroot "$SDK_PATH" \
  -O2 \
  -g \
  -DWRAPPING_CEF_SHARED \
  -I"$CEF_ROOT" \
  -fno-exceptions \
  -fno-rtti \
  -fno-threadsafe-statics \
  -fno-strict-aliasing \
  -fstack-protector \
  -funwind-tables \
  -fvisibility=hidden \
  -fvisibility-inlines-hidden \
  -Wall \
  -Wextra \
  -Wno-missing-field-initializers \
  -Wno-unused-parameter \
  -Wno-narrowing \
  -Wno-undefined-var-template \
  -Wno-deprecated-declarations \
  -Wno-unused-command-line-argument \
  -c "$SOURCE" \
  -o "$OBJECT"
