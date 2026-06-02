#!/bin/bash
# Regenerate the app icon from make_icon.swift:
#   1024 master PNG → all iconset sizes (sips) → AppIcon.icns (iconutil) → assets/icon.png
set -euo pipefail
cd "$(dirname "$0")"

echo "Rendering 1024px master…"
swiftc make_icon.swift -o /tmp/hl_mkicon
/tmp/hl_mkicon icon_1024.png

ICONSET="HermesLaunch.iconset"
mkdir -p "$ICONSET"

gen() { sips -z "$1" "$1" icon_1024.png --out "$ICONSET/$2" >/dev/null; }
echo "Resizing into $ICONSET…"
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
cp icon_1024.png "$ICONSET/icon_512x512@2x.png"

echo "Building AppIcon.icns…"
iconutil -c icns "$ICONSET" -o AppIcon.icns

echo "Updating README asset…"
cp icon_1024.png assets/icon.png

echo "Done. Rebuild the app with ./build.sh to pick up the new icon."
