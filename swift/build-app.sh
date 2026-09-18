#!/bin/bash
# Build the Swift Chrono.app bundle (no Dock, menu-bar only).
# Output: dist/Chrono.app (same path the alias.sh + plist already use).
set -euo pipefail
cd "$(dirname "$0")"

echo "→ swift build -c release"
swift build -c release

BIN=".build/release/Chrono"
if [ ! -f "$BIN" ]; then
    echo "ERROR: expected binary at $BIN" >&2
    exit 1
fi

APP="../dist/Chrono.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Chrono"
cp Info.plist "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/Chrono"

echo "✓ Built $APP"
echo "  Run: open $APP"
echo "  Note: first launch asks for notification permission; icon appears paused (⏸)."
