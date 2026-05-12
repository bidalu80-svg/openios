#!/usr/bin/env bash
set -euo pipefail

output_path="${1:-Open UI/Resources/iexa-alpine-rootfs.tar.gz}"
rootfs_url="${IEXA_ALPINE_ROOTFS_URL:-https://github.com/ish-app/roots/releases/download/g00712ff0a54b2839c5aa1a8ed758003ca65357dc/appstore-apk.tar.gz}"

mkdir -p "$(dirname "$output_path")"

echo "Downloading Alpine/iSH rootfs..."
echo "Source: $rootfs_url"
echo "Target: $output_path"

curl -L "$rootfs_url" -o "$output_path"
bytes="$(wc -c < "$output_path" | tr -d ' ')"
echo "Done: ${bytes} bytes"
