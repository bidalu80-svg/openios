#!/usr/bin/env bash
set -euo pipefail

output_path="${1:-Open UI/Resources/iexa-alpine-rootfs.tar.gz}"
rootfs_url="${IEXA_ALPINE_ROOTFS_URL:-https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/x86/alpine-minirootfs-3.23.4-x86.tar.gz}"
expected_sha256="${IEXA_ALPINE_ROOTFS_SHA256:-dba449a2c286f73cb1cf9b248631f3182c291f22619e1500922bd97b542263fa}"
preinstall_packages="${IEXA_ALPINE_PREINSTALL_PACKAGES:-}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$(dirname "$output_path")"
download_path="$output_path"
if [ -n "$preinstall_packages" ]; then
  download_path="$(dirname "$output_path")/.iexa-alpine-minirootfs.tar.gz"
fi

echo "Downloading Alpine/iSH rootfs..."
echo "Source: $rootfs_url"
echo "Target: $download_path"

curl -L "$rootfs_url" -o "$download_path"

if [ -n "$expected_sha256" ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    actual_sha256="$(sha256sum "$download_path" | awk '{print $1}')"
  else
    actual_sha256="$(shasum -a 256 "$download_path" | awk '{print $1}')"
  fi
  if [ "$actual_sha256" != "$expected_sha256" ]; then
    echo "SHA256 mismatch: expected $expected_sha256, got $actual_sha256" >&2
    exit 1
  fi
  echo "SHA256: $actual_sha256"
fi

if [ -n "$preinstall_packages" ]; then
  # shellcheck disable=SC2086
  python3 "$script_dir/preinstall-alpine-packages.py" \
    "$download_path" \
    "$output_path" \
    --packages $preinstall_packages
  rm -f "$download_path"

  rootfs_contents="$(mktemp)"
  tar -tzf "$output_path" > "$rootfs_contents"
  required_exact_paths=(
    usr/bin/as
    usr/bin/gcc
    usr/bin/g++
    usr/bin/ld
    usr/bin/make
    usr/bin/pip3
    usr/bin/python3
    usr/include/stdio.h
    usr/lib/libstdc++.so.6
    usr/lib/crt1.o
  )
  required_prefix_paths=(
    usr/include/c++/
  )
  for required_path in "${required_exact_paths[@]}"; do
    if ! grep -Fxq "$required_path" "$rootfs_contents"; then
      echo "Preinstalled rootfs is missing $required_path" >&2
      rm -f "$rootfs_contents"
      exit 1
    fi
  done
  for required_prefix in "${required_prefix_paths[@]}"; do
    if ! grep -Fq "$required_prefix" "$rootfs_contents"; then
      echo "Preinstalled rootfs is missing $required_prefix*" >&2
      rm -f "$rootfs_contents"
      exit 1
    fi
  done
  rm -f "$rootfs_contents"
fi

bytes="$(wc -c < "$output_path" | tr -d ' ')"
echo "Done: ${bytes} bytes"
