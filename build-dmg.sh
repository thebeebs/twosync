#!/bin/bash
# build-dmg.sh — wraps twosync.pkg in a polished DMG
# Run this on macOS after build-pkg.sh has produced twosync-1.0.0.pkg
set -e

VERSION="1.0.0"
APP_NAME="twosync"
PKG_NAME="${APP_NAME}-${VERSION}.pkg"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
STAGING_DIR="/tmp/twosync-dmg-staging"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_PATH="$SCRIPT_DIR/$PKG_NAME"
OUTPUT="$SCRIPT_DIR/$DMG_NAME"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${BOLD}Building twosync.dmg...${NC}"

# ── Prerequisites ─────────────────────────────────────────────────────────────
if [[ ! -f "$PKG_PATH" ]]; then
  echo -e "${RED}✗ $PKG_NAME not found — run build-pkg.sh first${NC}"
  exit 1
fi

for tool in hdiutil osascript; do
  if ! command -v $tool &>/dev/null; then
    echo -e "${RED}✗ $tool not found${NC}"
    exit 1
  fi
done

# ── Stage contents ────────────────────────────────────────────────────────────
echo -e "${BLUE}▶${NC} Staging DMG contents..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Copy the package
cp "$PKG_PATH" "$STAGING_DIR/"

# Create a README to sit alongside the pkg in the DMG
cat > "$STAGING_DIR/READ ME.txt" << 'EOF'
twosync — Two-Way Folder Sync for macOS

INSTALL
  Double-click "twosync-1.0.0.pkg" and follow the wizard.

USAGE (after install, open Terminal)
  Sync two folders once:
    twosync ~/FolderA ~/FolderB --verbose

  Set up hourly auto-sync:
    twosync-setup ~/FolderA ~/FolderB

  Preview changes without applying:
    twosync ~/FolderA ~/FolderB --dry-run --verbose

  View logs:
    tail -f ~/.twosync/twosync.log

UNINSTALL
  sudo rm /usr/local/bin/twosync /usr/local/bin/twosync-setup
  rm -rf ~/.twosync
  launchctl unload ~/Library/LaunchAgents/com.user.twosync*.plist
  rm ~/Library/LaunchAgents/com.user.twosync*.plist
EOF

# ── Generate a simple background image with Python ───────────────────────────
echo -e "${BLUE}▶${NC} Generating background image..."

python3 << 'PYEOF'
import struct, zlib, math

W, H = 620, 380

def write_png(path, w, h, pixels):
    def chunk(tag, data):
        c = struct.pack('>I', len(data)) + tag + data
        return c + struct.pack('>I', zlib.crc32(c[4:]) & 0xffffffff)
    rows = b''
    for y in range(h):
        row = b'\x00'
        for x in range(w):
            row += bytes(pixels[y * w + x])
        rows += row
    compressed = zlib.compress(rows, 9)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b'IDAT', compressed))
        f.write(chunk(b'IEND', b''))

pixels = []
for y in range(H):
    for x in range(W):
        # Subtle dark gradient — top: #1a1a2e, bottom: #16213e
        t = y / H
        r = int(26 + t * (22 - 26))
        g = int(26 + t * (33 - 26))
        b = int(46 + t * (62 - 46))
        # Soft vignette
        dx = (x - W/2) / (W/2)
        dy = (y - H/2) / (H/2)
        vignette = 1 - 0.25 * (dx*dx + dy*dy)
        r = max(0, min(255, int(r * vignette)))
        g = max(0, min(255, int(g * vignette)))
        b = max(0, min(255, int(b * vignette)))
        pixels.append((r, g, b))

write_png('/tmp/twosync-dmg-bg.png', W, H, pixels)
print("Background written")
PYEOF

cp /tmp/twosync-dmg-bg.png "$STAGING_DIR/.background.png"

# ── Create writable DMG ───────────────────────────────────────────────────────
echo -e "${BLUE}▶${NC} Creating DMG..."
TEMP_DMG="/tmp/twosync-temp.dmg"

rm -f "$TEMP_DMG"
hdiutil create \
  -srcfolder "$STAGING_DIR" \
  -volname "twosync" \
  -fs HFS+ \
  -fsargs "-c c=16,a=16,b=16" \
  -format UDRW \
  -size 20m \
  "$TEMP_DMG"

# Mount it
MOUNT_OUTPUT=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG" 2>&1)
DEVICE=$(echo "$MOUNT_OUTPUT" | grep '/dev/disk' | awk 'NR==1{print $1}')
MOUNT_POINT=$(echo "$MOUNT_OUTPUT" | grep 'Apple_HFS' | awk '{print $NF}')

sleep 1

echo -e "${BLUE}▶${NC} Setting DMG layout via AppleScript..."

# Use AppleScript to set the window appearance
osascript << APPLESCRIPT
tell application "Finder"
  tell disk "twosync"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 720, 480}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 72
    set background picture of viewOptions to file ".background.png"
    -- Position the pkg
    set position of item "twosync-${VERSION}.pkg" of container window to {200, 180}
    -- Position the readme
    set position of item "READ ME.txt" of container window to {420, 180}
    close
    open
    update without registering applications
    delay 2
  end tell
end tell
APPLESCRIPT

# Set volume icon (optional — skip if no .icns available)
# cp twosync.icns "$MOUNT_POINT/.VolumeIcon.icns"
# SetFile -a C "$MOUNT_POINT"

sync
sleep 1

# ── Convert to compressed read-only DMG ──────────────────────────────────────
echo -e "${BLUE}▶${NC} Compressing..."

hdiutil detach "$DEVICE" -quiet
rm -f "$OUTPUT"

hdiutil convert "$TEMP_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$OUTPUT"

rm -f "$TEMP_DMG"
rm -rf "$STAGING_DIR"

echo ""
echo -e "${GREEN}${BOLD}✓ Built: $OUTPUT${NC}"
echo ""
echo "  To open:"
echo "    open \"$OUTPUT\""
echo ""
echo "  To sign (optional, requires Apple Developer account):"
echo "    codesign --sign 'Developer ID Application: Your Name' \"$OUTPUT\""
echo ""
