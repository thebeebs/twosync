#!/bin/bash
# Remove twosync LaunchAgent

PLIST="$HOME/Library/LaunchAgents/com.user.twosync.plist"

if [[ -f "$PLIST" ]]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm "$PLIST"
  echo "✓ twosync uninstalled"
else
  echo "twosync is not installed"
fi
