#!/bin/bash
# twosync installer — sets up hourly sync as a macOS LaunchAgent
# Usage: ./install.sh /path/to/folder_a /path/to/folder_b

set -e

if [[ $# -lt 2 ]]; then
  echo "Usage: ./install.sh <folder_a> <folder_b>"
  exit 1
fi

FOLDER_A="$(cd "$1" && pwd)"
FOLDER_B="$(cd "$2" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/twosync.py"
PLIST_NAME="com.user.twosync"
PLIST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
LOG_DIR="$HOME/.twosync"

mkdir -p "$LOG_DIR"
mkdir -p "$HOME/Library/LaunchAgents"

# Make script executable
chmod +x "$SCRIPT"

# Write the plist
cat > "$PLIST" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>${SCRIPT}</string>
        <string>${FOLDER_A}</string>
        <string>${FOLDER_B}</string>
    </array>

    <key>StartInterval</key>
    <integer>3600</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>${LOG_DIR}/stdout.log</string>

    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/stderr.log</string>
</dict>
</plist>
PLIST_EOF

# Unload if already running
launchctl unload "$PLIST" 2>/dev/null || true

# Load it
launchctl load "$PLIST"

echo ""
echo "✓ twosync installed and running"
echo ""
echo "  Syncing:  $FOLDER_A"
echo "       ↔    $FOLDER_B"
echo "  Schedule: every hour (runs immediately on load)"
echo "  Logs:     $LOG_DIR/twosync.log"
echo ""
echo "  To check status:   launchctl list | grep twosync"
echo "  To run manually:   python3 $SCRIPT \"$FOLDER_A\" \"$FOLDER_B\" --verbose"
echo "  To uninstall:      ./uninstall.sh"
