#!/usr/bin/env bash
# Build a distributable release: a zipped ContactSheet.coplugin that users unzip and drop into
# ~/Library/Application Support/Capture One/Plug-ins/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
"$ROOT/build.sh"

VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
DIST="$ROOT/dist"
ZIP="$DIST/ContactSheet-$VER.coplugin.zip"

mkdir -p "$DIST"
rm -f "$ZIP"
# ditto preserves the bundle structure + code signature; --keepParent keeps the .coplugin folder.
ditto -c -k --keepParent "$ROOT/build/ContactSheet.coplugin" "$ZIP"

echo
echo "Release artifact: $ZIP"
echo "Version: $VER"
shasum -a 256 "$ZIP"
