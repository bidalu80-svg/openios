#!/usr/bin/env bash
set -euo pipefail

destination="${1:-External/ish}"
repository="${IEXA_ISH_REPOSITORY:-https://github.com/OpenMinis/ish-arm64.git}"
revision="${IEXA_ISH_REVISION:-master}"
source_path="${IEXA_ISH_SOURCE_PATH:-}"

if [ -n "$source_path" ]; then
  if [ ! -d "$source_path" ]; then
    echo "Source path does not exist: $source_path" >&2
    exit 1
  fi
  if [ ! -d "$source_path/iSH.xcodeproj" ]; then
    echo "Source path does not look like an iSH checkout: $source_path" >&2
    exit 1
  fi
  if [ -e "$destination" ]; then
    if [ "${IEXA_ISH_SOURCE_FORCE:-0}" != "1" ]; then
      echo "Destination already exists: $destination. Set IEXA_ISH_SOURCE_FORCE=1 to replace it from IEXA_ISH_SOURCE_PATH." >&2
      exit 1
    fi
    rm -rf "$destination"
  fi
  mkdir -p "$(dirname "$destination")"
  cp -R "$source_path" "$destination"
  echo "Prepared iSH ARM64 source at $destination from $source_path"
  echo "Guest architecture: arm64/aarch64"
  exit 0
fi

if [ -d "$destination/.git" ]; then
  git -C "$destination" fetch --depth 1 origin "$revision"
elif [ -e "$destination" ]; then
  echo "Destination exists but is not a git checkout: $destination" >&2
  exit 1
else
  git clone --depth 1 "$repository" "$destination"
fi

git -C "$destination" fetch --depth 1 origin "$revision"
git -C "$destination" reset --hard FETCH_HEAD
git -C "$destination" submodule update --init --depth 1 deps/libapps deps/libarchive

echo "Prepared iSH ARM64 source at $destination"
echo "Guest architecture: arm64/aarch64"
