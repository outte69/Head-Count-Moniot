#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
PLIST_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$PLIST_DIR"

create_plist() {
  plist_path="$1"
  label="$2"
  scope="$3"
  minute="$4"
  hour="$5"
  weekday="$6"
  monthday="$7"

  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0">'
    printf '%s\n' '<dict>'
    printf '%s\n' "  <key>Label</key><string>$label</string>"
    printf '%s\n' '  <key>ProgramArguments</key>'
    printf '%s\n' '  <array>'
    printf '%s\n' '    <string>/bin/sh</string>'
    printf '%s\n' "    <string>$SCRIPT_DIR/run-scheduled-backup.sh</string>"
    printf '%s\n' "    <string>$scope</string>"
    printf '%s\n' '  </array>'
    printf '%s\n' '  <key>RunAtLoad</key><true/>'
    printf '%s\n' '  <key>StartCalendarInterval</key>'
    printf '%s\n' '  <dict>'
    printf '%s\n' "    <key>Hour</key><integer>$hour</integer>"
    printf '%s\n' "    <key>Minute</key><integer>$minute</integer>"
    if [ -n "$weekday" ]; then
      printf '%s\n' "    <key>Weekday</key><integer>$weekday</integer>"
    fi
    if [ -n "$monthday" ]; then
      printf '%s\n' "    <key>Day</key><integer>$monthday</integer>"
    fi
    printf '%s\n' '  </dict>'
    printf '%s\n' '  <key>StandardOutPath</key>'
    printf '%s\n' "  <string>$SCRIPT_DIR/backup-$scope.log</string>"
    printf '%s\n' '  <key>StandardErrorPath</key>'
    printf '%s\n' "  <string>$SCRIPT_DIR/backup-$scope-error.log</string>"
    printf '%s\n' '</dict>'
    printf '%s\n' '</plist>'
  } > "$plist_path"
}

create_plist "$PLIST_DIR/com.visitor.monitor.backup.daily.plist" "com.visitor.monitor.backup.daily" "daily" "35" "0" "" ""
create_plist "$PLIST_DIR/com.visitor.monitor.backup.weekly.plist" "com.visitor.monitor.backup.weekly" "weekly" "58" "23" "7" ""
create_plist "$PLIST_DIR/com.visitor.monitor.backup.monthly.plist" "com.visitor.monitor.backup.monthly" "monthly" "10" "0" "" "1"

launchctl unload "$PLIST_DIR/com.visitor.monitor.backup.daily.plist" 2>/dev/null || true
launchctl unload "$PLIST_DIR/com.visitor.monitor.backup.weekly.plist" 2>/dev/null || true
launchctl unload "$PLIST_DIR/com.visitor.monitor.backup.monthly.plist" 2>/dev/null || true

launchctl load "$PLIST_DIR/com.visitor.monitor.backup.daily.plist"
launchctl load "$PLIST_DIR/com.visitor.monitor.backup.weekly.plist"
launchctl load "$PLIST_DIR/com.visitor.monitor.backup.monthly.plist"

echo "Backup schedules installed."
echo "Daily: 00:35"
echo "Weekly: Sunday 23:58"
echo "Monthly: day 1 at 00:10"
