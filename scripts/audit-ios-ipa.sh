#!/usr/bin/env bash
set -euo pipefail

IPA_PATH="${1:-}"
if [ -z "$IPA_PATH" ] || [ ! -f "$IPA_PATH" ]; then
  echo "Usage: $0 /path/to/app.ipa" >&2
  exit 64
fi

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

/usr/bin/unzip -q "$IPA_PATH" -d "$WORK_DIR"

APP_PATH="$(find "$WORK_DIR/Payload" -maxdepth 1 -name '*.app' -type d | head -n 1)"
if [ -z "$APP_PATH" ]; then
  echo "::error::IPA does not contain a Payload/*.app bundle"
  exit 1
fi

echo "Auditing IPA hardening: $(basename "$IPA_PATH")"
echo "App bundle: $(basename "$APP_PATH")"

debug_artifacts="$(find "$APP_PATH" \( \
  -name '*.dSYM' -o \
  -name '*.bcsymbolmap' -o \
  -name '*.swiftmodule' -o \
  -name '*.swiftdoc' -o \
  -name '*.swiftsourceinfo' -o \
  -name '*.abi.json' \
\) -print)"
if [ -n "$debug_artifacts" ]; then
  echo "::error::Debug or Swift compiler artifacts remain in the IPA:"
  echo "$debug_artifacts"
  exit 1
fi

EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Info.plist" 2>/dev/null || true)"
MAIN_BINARY="$APP_PATH/$EXECUTABLE_NAME"
if [ -z "$EXECUTABLE_NAME" ] || [ ! -f "$MAIN_BINARY" ]; then
  echo "::warning::Unable to locate main executable for symbol/string audit"
  exit 0
fi

if xcrun nm -m "$MAIN_BINARY" >/dev/null 2>&1; then
  symbol_rows="$(xcrun nm -m "$MAIN_BINARY" 2>/dev/null | wc -l | tr -d '[:space:]' || echo 0)"
  echo "Externally visible symbol rows: $symbol_rows"
fi

source_like_strings="$(strings "$MAIN_BINARY" | grep -E '(/Users/runner/work|/Users/[^/]+/|\\Users\\|Iexa UI/(Core|Features|Shared|Resources)|Iexa UI\.xcodeproj)' | head -n 30 || true)"
if [ -n "$source_like_strings" ]; then
  echo "::warning::Main binary still contains source-path-like strings:"
  echo "$source_like_strings"
fi

secret_like_strings="$(strings "$MAIN_BINARY" | grep -E '(sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|AIza[0-9A-Za-z_-]{20,})' | head -n 20 || true)"
if [ -n "$secret_like_strings" ]; then
  echo "::warning::Main binary contains strings that look like API keys or tokens:"
  echo "$secret_like_strings"
fi

echo "IPA hardening audit completed"
