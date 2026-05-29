#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-}"
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
  echo "Usage: $0 /path/to/Iexa.app" >&2
  exit 64
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Skipping iOS app hardening outside macOS"
  exit 0
fi

strip_macho() {
  local candidate="$1"
  local type

  type="$(file "$candidate" 2>/dev/null || true)"
  case "$type" in
    *Mach-O*executable*|*Mach-O*dynamically\ linked\ shared\ library*|*Mach-O*bundle*)
      local before after
      before="$(stat -f%z "$candidate" 2>/dev/null || echo 0)"
      xcrun strip -S -x "$candidate" 2>/dev/null || xcrun strip -S "$candidate" 2>/dev/null || true
      after="$(stat -f%z "$candidate" 2>/dev/null || echo 0)"
      echo "Hardened Mach-O: ${candidate#$APP_PATH/} ($before -> $after bytes)"
      ;;
  esac
}

while IFS= read -r artifact; do
  rm -rf "$artifact"
done < <(
  find "$APP_PATH" \( \
    -name "*.dSYM" -o \
    -name "*.bcsymbolmap" -o \
    -name "*.swiftmodule" -o \
    -name "*.swiftdoc" -o \
    -name "*.swiftsourceinfo" -o \
    -name "*.abi.json" \
  \) -print
)

while IFS= read -r executable; do
  strip_macho "$executable"
done < <(find "$APP_PATH" -type f -perm -111 -print)

MAIN_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Info.plist" 2>/dev/null || true)"
MAIN_BINARY="$APP_PATH/$MAIN_EXECUTABLE"
if [ -f "$MAIN_BINARY" ]; then
  strip_macho "$MAIN_BINARY"

  if strings "$MAIN_BINARY" | grep -E '(/Users/runner/work|/Users/[^/]+/|\\Users\\|Iexa UI/Features|Iexa UI/Core)' >/dev/null; then
    echo "::warning::Main binary still contains local source-path-like strings"
  fi

  symbol_count="$(xcrun nm -m "$MAIN_BINARY" 2>/dev/null | wc -l | tr -d '[:space:]' || echo 0)"
  echo "Remaining externally visible symbol rows in main binary: $symbol_count"
fi
