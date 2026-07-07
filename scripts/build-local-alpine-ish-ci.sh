#!/usr/bin/env bash
set -euo pipefail

ish_dir="${1:-External/ish}"
products_dir="${2:-$PWD/.build/ish-products}"

mkdir -p "$products_dir"

patch_file="$PWD/scripts/ish-signal-waiting-lock.patch"
if [ -f "$patch_file" ]; then
  if git -C "$ish_dir" apply --check "$patch_file"; then
    git -C "$ish_dir" apply "$patch_file"
    echo "Applied iSH signal waiter crash guard"
  elif grep -Fq "waiting_lock != NULL" "$ish_dir/kernel/signal.c"; then
    echo "iSH signal waiter crash guard already present"
  else
    echo "Could not apply iSH signal waiter crash guard" >&2
    git -C "$ish_dir" apply --check "$patch_file" || true
    exit 1
  fi
fi

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
