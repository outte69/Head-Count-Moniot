#!/bin/bash
cd "$(dirname "$0")"

if ! command -v ruby >/dev/null 2>&1; then
  echo "Ruby is not installed or not available in PATH."
  echo "Install Ruby, then run this launcher again."
  read -r -p "Press Enter to close..."
  exit 1
fi

echo "Starting Visitor Island Monitor server..."
echo
echo "This Mac:"
echo "  http://localhost:4567"
echo
echo "Other devices on the same network:"
echo "  http://YOUR-MAC-IP:4567"
echo
echo "A browser window will open automatically."
echo "Leave this Terminal window open while the app is being used."
echo "Press Ctrl+C to stop the server."
echo

( sleep 2; open "http://localhost:4567" ) >/dev/null 2>&1 &
ruby server.rb

echo
echo "Server stopped."
read -r -p "Press Enter to close..."
