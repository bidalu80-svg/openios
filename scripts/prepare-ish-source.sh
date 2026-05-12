#!/usr/bin/env bash
set -euo pipefail

destination="${1:-External/ish}"
repository="${IEXA_ISH_REPOSITORY:-https://github.com/ish-app/ish.git}"

if [ -d "$destination/.git" ]; then
  git -C "$destination" fetch --depth 1 origin
  git -C "$destination" reset --hard FETCH_HEAD
elif [ -e "$destination" ]; then
  echo "Destination exists but is not a git checkout: $destination" >&2
  exit 1
else
  git clone --depth 1 "$repository" "$destination"
fi

git -C "$destination" submodule update --init --depth 1 deps/libapps deps/libarchive

echo "Prepared iSH source at $destination"
echo "Note: deps/linux is intentionally not fetched for the default iOS iSH kernel path."
