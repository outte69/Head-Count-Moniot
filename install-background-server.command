#!/bin/bash
set -e

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_PATH="$HOME/Library/LaunchAgents/com.visitorislandmonitor.server.plist"
LOG_DIR="$APP_DIR/log"

mkdir -p "$LOG_DIR"

if ! command -v ruby >/dev/null 2>&1; then
  echo "Ruby is not installed or not available in PATH."
  read -r -p "Press Enter to close..."
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.visitorislandmonitor.server</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/env</string>
    <string>ruby</string>
    <string>server.rb</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$APP_DIR</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/server.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/server.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl kickstart -k "gui/$(id -u)/com.visitorislandmonitor.server"

echo
echo "Visitor Island Monitor background service installed and started."
echo "Open http://localhost:4567 on this Mac."
echo "Other devices can use http://YOUR-MAC-IP:4567"
echo
read -r -p "Press Enter to close..."
