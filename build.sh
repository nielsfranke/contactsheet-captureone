#!/usr/bin/env bash
# Build ContactSheet.coplugin with the macOS Command Line Tools (no Xcode required).
set -euo pipefail

SDK="${CO_SDK:-/Users/niels/contactsheet_plugin/Capture One Plugin SDK (Mac) v1.0.1}"
FW="$SDK/Library/Frameworks"
if [ ! -d "$FW/CaptureOnePlugins.framework" ]; then
  echo "Capture One Plugin SDK not found at: $FW" >&2
  echo "Set CO_SDK to the extracted SDK folder." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build"
PLUGIN="$OUT/ContactSheet.coplugin"

rm -rf "$OUT"
mkdir -p "$PLUGIN/Contents/MacOS"

clang -bundle -fobjc-arc -fmodules \
  -isysroot "$(xcrun --show-sdk-path)" \
  -F "$FW" -framework CaptureOnePlugins -framework Foundation -framework AppKit \
  -mmacosx-version-min=11.0 -arch arm64 -arch x86_64 \
  "$ROOT/Sources/CSContactSheetPlugin.m" \
  -o "$PLUGIN/Contents/MacOS/ContactSheet"

cp "$ROOT/Info.plist" "$PLUGIN/Contents/Info.plist"
codesign --force --sign - "$PLUGIN"

echo "Built: $PLUGIN"
codesign -dv "$PLUGIN" 2>&1 | head -3 || true
