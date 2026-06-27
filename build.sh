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

# Resources: the plugin icon. Build a multi-size .icns from Resources/ContactSheet.png (for the
# Plugin Manager via CFBundleIconFile) and copy the PNG (loaded as the publish action's image).
mkdir -p "$PLUGIN/Contents/Resources"
if [ -f "$ROOT/Resources/ContactSheet.png" ]; then
  cp "$ROOT/Resources/ContactSheet.png" "$PLUGIN/Contents/Resources/ContactSheet.png"
  ICONSET="$OUT/ContactSheet.iconset"; mkdir -p "$ICONSET"
  for pair in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512"; do
    set -- $pair
    sips -z "$1" "$1" "$ROOT/Resources/ContactSheet.png" --out "$ICONSET/icon_$2.png" >/dev/null 2>&1 || true
  done
  iconutil -c icns "$ICONSET" -o "$PLUGIN/Contents/Resources/ContactSheet.icns" 2>/dev/null || true
fi

codesign --force --sign - "$PLUGIN"

echo "Built: $PLUGIN"
codesign -dv "$PLUGIN" 2>&1 | head -3 || true
