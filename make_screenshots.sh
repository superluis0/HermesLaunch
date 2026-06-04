#!/bin/bash
# Capture clean PNGs of each HermesLaunch window for the README.
#
# Requires:
#   • HermesLaunch running (this opens each window via the hermeslaunch:// URL scheme)
#   • Screen Recording permission for your terminal
#       System Settings → Privacy & Security → Screen Recording → enable your terminal,
#       then fully quit & reopen the terminal.
#   • uv (https://docs.astral.sh/uv/) — used to borrow pyobjc's Quartz to resolve window ids.
#
# Usage:  ./make_screenshots.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p assets

open -g HermesLaunch.app 2>/dev/null || true
sleep 1

# Print the front-most on-screen HermesLaunch window id (skips the tiny menubar item).
read -r -d '' FRONT_WIN <<'PY' || true
import Quartz
wins = Quartz.CGWindowListCopyWindowInfo(
    Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
    Quartz.kCGNullWindowID)
for w in wins:  # front-to-back order
    if w.get('kCGWindowOwnerName','') != 'HermesLaunch': continue
    b = w['kCGWindowBounds']
    if b['Width'] * b['Height'] < 20000: continue
    print(w['kCGWindowNumber']); break
PY

capture() {  # capture <url-action> <output-name>
    open "hermeslaunch://$1"
    sleep 2
    local id
    id="$(uv run --quiet --with pyobjc-framework-Quartz python3 -c "$FRONT_WIN")"
    if [ -z "$id" ]; then echo "⚠️  no window found for $1"; return; fi
    screencapture -x -o -l"$id" "assets/$2.png"
    echo "✓ assets/$2.png"
}

capture palette     command-palette
capture kanban      kanban
capture tools       tools-mcp
capture automations automations

echo "Done. If images are blank, grant Screen Recording to your terminal and re-run."
