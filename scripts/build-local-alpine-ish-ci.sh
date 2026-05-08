#!/usr/bin/env bash
set -euo pipefail

ish_dir="${1:-External/ish}"
products_dir="${2:-$PWD/.build/ish-products}"

mkdir -p "$products_dir"

xcodebuild \
  -project "$ish_dir/iSH.xcodeproj" \
  -target libish \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CONFIGURATION_BUILD_DIR="$products_dir" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

bash "$PWD/scripts/local-alpine-ish-compile-probe.sh" "$ish_dir"

meson_dir="$products_dir/meson"
for lib in libish.a libish_emu.a libfakefs.a; do
  if [ ! -s "$products_dir/$lib" ] && [ -s "$meson_dir/$lib" ]; then
    ln -sf "$meson_dir/$lib" "$products_dir/$lib"
  fi
  test -s "$products_dir/$lib"
done

echo "Built iSH static libraries in $products_dir"
