#!/usr/bin/env bash
# Install the built plugin into Capture One's user Plug-ins folder. Restart Capture One after.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/build/ContactSheet.coplugin"
DEST="$HOME/Library/Application Support/Capture One/Plug-ins"

[ -d "$SRC" ] || { echo "Not built yet — run ./build.sh first." >&2; exit 1; }
mkdir -p "$DEST"
rm -rf "$DEST/ContactSheet.coplugin"
cp -R "$SRC" "$DEST/"
echo "Installed: $DEST/ContactSheet.coplugin"
echo "Restart Capture One, then check Preferences → Plugins."
