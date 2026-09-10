#!/bin/bash
# Add this to your ~/.zshrc:
#   source ~/hermes-workspace/chrono/alias.sh
#
# Usage:
#   chrono          Start timer (0 → ∞, auto-starts counting)
#   chronokill      Quit timer
#   chronologin     Start at login
#   chrononologin   Disable start at login

chrono() {
    case "${1:-start}" in
        start)
            open ~/hermes-workspace/chrono/dist/Chrono.app 2>/dev/null || (cd ~/hermes-workspace/chrono && /opt/homebrew/bin/python3.14 setup.py py2app && open dist/Chrono.app)
            ;;
        stop|kill)
            killall Chrono 2>/dev/null; echo 'Chrono killed'
            ;;
        login)
            cp ~/hermes-workspace/chrono/com.user.chrono.plist ~/Library/LaunchAgents/ 2>/dev/null
            launchctl load ~/Library/LaunchAgents/com.user.chrono.plist 2>/dev/null; echo 'Chrono will start at login'
            ;;
        nologin)
            launchctl unload ~/Library/LaunchAgents/com.user.chrono.plist 2>/dev/null; echo 'Chrono auto-start disabled'
            ;;
        *)
            echo "Usage: chrono {start|stop|login|nologin}"
            ;;
    esac
}

# Shorter alias
alias chronokill='chrono kill'
