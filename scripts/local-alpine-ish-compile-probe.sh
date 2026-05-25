#!/usr/bin/env bash
set -euo pipefail

ish_dir="${1:-External/ish}"
bridge="${2:-Iexa UI/Core/Services/LocalAlpineNativeRuntimeBridge.c}"
object="${3:-$PWD/.build/local-alpine-ish-probe/LocalAlpineNativeRuntimeBridge.o}"
sdk="${SDKROOT:-$(xcrun --sdk iphoneos --show-sdk-path)}"

mkdir -p "$(dirname "$object")"

cc="${CC:-$(xcrun --sdk iphoneos --find clang)}"

"$cc" \
  -isysroot "$sdk" \
  -target arm64-apple-ios18.1 \
  -std=gnu17 \
  -DISH_INTERNAL=1 \
  -DIEXA_LOCAL_ALPINE_ISH=1 \
  -I"$(dirname "$bridge")" \
  -I"$ish_dir" \
  -I"$ish_dir/deps/libarchive/libarchive" \
  -fsyntax-only \
  "$bridge"

echo "Local Alpine iSH bridge syntax probe passed"
