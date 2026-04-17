#!/bin/bash

PLIST_PATH="$HOME/Library/LaunchAgents/com.visitorislandmonitor.server.plist"

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"

echo
echo "Visitor Island Monitor background service removed."
echo
read -r -p "Press Enter to close..."
