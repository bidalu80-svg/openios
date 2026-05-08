#!/usr/bin/env bash
set -euo pipefail

ish_dir="${1:-External/ish}"
rootfs_archive="${2:-Open UI/Resources/iexa-alpine-rootfs.tar.gz}"
fakefs_output="${3:-Open UI/Resources/iexa-alpine-rootfs.fakefs}"
build_dir="${4:-$PWD/.build/local-alpine-fakefs}"

if [ ! -d "$ish_dir" ]; then
  echo "iSH source not found: $ish_dir" >&2
  exit 1
fi
if [ ! -s "$rootfs_archive" ]; then
  echo "Rootfs archive not found: $rootfs_archive" >&2
  exit 1
fi

mkdir -p "$build_dir" "$(dirname "$fakefs_output")"
rm -rf "$build_dir/rootfs.fakefs" "$fakefs_output"

cc="${CC:-cc}"
pkg_config_flags=()
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libarchive; then
  read -r -a pkg_config_flags <<< "$(pkg-config --cflags --libs libarchive)"
else
  pkg_config_flags=(-larchive)
fi

"$cc" \
  -std=gnu11 \
  -DISH_INTERNAL \
  -I"$ish_dir" \
  "$ish_dir/tools/fakefsify.c" \
  "$ish_dir/tools/fakefs.c" \
  "$ish_dir/util/fchdir.c" \
  "$ish_dir/fs/fake-db.c" \
  "$ish_dir/fs/fake-migrate.c" \
  "$ish_dir/fs/fake-rebuild.c" \
  -lsqlite3 \
  "${pkg_config_flags[@]}" \
  -o "$build_dir/fakefsify"

"$build_dir/fakefsify" "$rootfs_archive" "$build_dir/rootfs.fakefs"

mv "$build_dir/rootfs.fakefs" "$fakefs_output"

kilobytes="$(du -sk "$fakefs_output" | awk '{print $1}')"
echo "Prepared Local Alpine fakefs directory: $fakefs_output (${kilobytes} KiB)"
