#!/usr/bin/env bash
set -euo pipefail

output_path="${1:-Open UI/Resources/iexa-alpine-rootfs.tar.gz}"
rootfs_url="${IEXA_ALPINE_ROOTFS_URL:-https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/x86/alpine-minirootfs-3.23.4-x86.tar.gz}"
expected_sha256="${IEXA_ALPINE_ROOTFS_SHA256:-dba449a2c286f73cb1cf9b248631f3182c291f22619e1500922bd97b542263fa}"

mkdir -p "$(dirname "$output_path")"

echo "Downloading Alpine/iSH rootfs..."
echo "Source: $rootfs_url"
echo "Target: $output_path"

curl -L "$rootfs_url" -o "$output_path"

if [ -n "$expected_sha256" ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    actual_sha256="$(sha256sum "$output_path" | awk '{print $1}')"
  else
    actual_sha256="$(shasum -a 256 "$output_path" | awk '{print $1}')"
  fi
  if [ "$actual_sha256" != "$expected_sha256" ]; then
    echo "SHA256 mismatch: expected $expected_sha256, got $actual_sha256" >&2
    exit 1
  fi
  echo "SHA256: $actual_sha256"
fi

bytes="$(wc -c < "$output_path" | tr -d ' ')"
echo "Done: ${bytes} bytes"
