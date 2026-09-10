#!/bin/bash
# Chrono launcher — run from terminal or set as Login Item
cd "$(dirname "$0")"
/opt/homebrew/bin/python3.14 chrono.py &
echo "🍅 Chrono running in menu bar. Press Ctrl+C here to detach (it keeps running)."
echo "To quit: right-click menu bar icon → Quit"
wait
