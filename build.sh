#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP="HermesLaunch.app"
BIN="HermesLaunch"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Info.plist "$APP/Contents/Info.plist"

if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

swiftc -O -target arm64-apple-macosx13.0 -o "$APP/Contents/MacOS/$BIN" \
    main.swift HermesLaunch.swift QuickChat.swift ChatView.swift UsageDashboard.swift MenuBarStyleSettings.swift \
    -framework Cocoa

# Ad-hoc sign so Gatekeeper / TCC can identify the bundle stably for AppleEvents prompt.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# Register the bundle so LaunchServices picks up the new icon and Services entry,
# then refresh the system Services menu.
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREG" -f "$APP" >/dev/null 2>&1 || true
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true

echo "Built $APP"
echo "Run:  open $APP"
