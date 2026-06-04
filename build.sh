#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP="HermesLaunch.app"
BIN="HermesLaunch"

# Compile via SwiftPM (pulls FluidAudio + builds the C++ wrappers). The product
# is a single executable we drop into the .app bundle below.
swift build -c release

# Locate the built binary (handles the arch-specific .build layout).
PRODUCT="$(swift build -c release --show-bin-path)/$BIN"
if [ ! -f "$PRODUCT" ]; then
    echo "error: built product not found at $PRODUCT" >&2
    exit 1
fi

# Assemble the .app bundle.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
cp "$PRODUCT" "$APP/Contents/MacOS/$BIN"

# Ad-hoc sign so Gatekeeper / TCC can identify the bundle stably (mic, screen
# recording, AppleEvents prompts all key off a stable code identity).
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# Register the bundle so LaunchServices picks up the new icon and Services entry,
# then refresh the system Services menu.
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREG" -f "$APP" >/dev/null 2>&1 || true
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true

echo "Built $APP"
echo "Run:  open $APP"
