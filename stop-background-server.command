#!/bin/bash

PLIST_PATH="$HOME/Library/LaunchAgents/com.visitorislandmonitor.server.plist"

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true

echo
echo "Visitor Island Monitor background service stopped."
echo
read -r -p "Press Enter to close..."
