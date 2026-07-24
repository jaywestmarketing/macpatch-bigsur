#!/usr/bin/env bash
# enable-startup.sh - launch MacPatch Dashboard automatically at login
# Usage: enable-startup.sh          -> install the LaunchAgent
#        enable-startup.sh disable  -> remove it
set -euo pipefail

LABEL="com.macpatch.bigsur.dashboard"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="/Applications/MacPatch Dashboard.app"

if [[ "${1:-enable}" == "disable" ]]; then
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Startup disabled."
    exit 0
fi

[[ -d "$APP" ]] || { echo "MacPatch Dashboard not installed in /Applications"; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>$APP</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLISTEOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "Startup enabled - MacPatch Dashboard will open at login."
