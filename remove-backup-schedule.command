#!/bin/sh
set -eu

PLIST_DIR="$HOME/Library/LaunchAgents"

for name in \
  com.visitor.monitor.backup.daily \
  com.visitor.monitor.backup.weekly \
  com.visitor.monitor.backup.monthly
do
  launchctl unload "$PLIST_DIR/$name.plist" 2>/dev/null || true
  rm -f "$PLIST_DIR/$name.plist"
done

echo "Backup schedules removed."
