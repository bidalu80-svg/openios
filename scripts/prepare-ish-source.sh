#!/usr/bin/env bash
set -euo pipefail

destination="${1:-External/ish}"
repository="${IEXA_ISH_REPOSITORY:-https://github.com/ish-app/ish.git}"
revision="${IEXA_ISH_REVISION:-af9315a523342674a520b29473554a9b39e77c7f}"

if [ -d "$destination/.git" ]; then
  git -C "$destination" fetch --depth 1 origin "$revision"
elif [ -e "$destination" ]; then
  echo "Destination exists but is not a git checkout: $destination" >&2
  exit 1
else
  git clone --depth 1 "$repository" "$destination"
fi

git -C "$destination" fetch --depth 1 origin "$revision"
git -C "$destination" reset --hard "$revision"
git -C "$destination" submodule update --init --depth 1 deps/libapps deps/libarchive

echo "Prepared iSH source at $destination"
echo "Note: deps/linux is intentionally not fetched for the default iOS iSH kernel path."
