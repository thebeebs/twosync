#!/bin/bash
# build-pkg.sh — builds twosync.pkg (run this on macOS)
set -e

VERSION="1.0.0"
IDENTIFIER="com.user.twosync"
PKG_NAME="twosync-${VERSION}.pkg"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)/pkg-build"
PAYLOAD_DIR="$BUILD_DIR/payload"
SCRIPTS_DIR="$BUILD_DIR/scripts"
RESOURCES_DIR="$BUILD_DIR/resources"
SHARE_DIR="$PAYLOAD_DIR/usr/local/share/twosync"
OUTPUT="$(cd "$(dirname "$0")" && pwd)/$PKG_NAME"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${BOLD}Building twosync.pkg...${NC}"

# ── Check pkgbuild / productbuild are available ──────────────────────────────
for tool in pkgbuild productbuild; do
  if ! command -v $tool &>/dev/null; then
    echo -e "${RED}✗ $tool not found — install Xcode Command Line Tools:${NC}"
    echo "  xcode-select --install"
    exit 1
  fi
done

# ── Set up payload structure ─────────────────────────────────────────────────
mkdir -p "$SHARE_DIR"
mkdir -p "$PAYLOAD_DIR/usr/local/bin"

# Copy the main Python script into the payload
cp "$(dirname "$0")/twosync.py" "$SHARE_DIR/twosync.py"
chmod +x "$SHARE_DIR/twosync.py"

# The twosync wrapper command
cat > "$PAYLOAD_DIR/usr/local/bin/twosync" << 'EOF'
#!/bin/bash
exec python3 "$HOME/.twosync/twosync.py" "$@"
EOF
chmod +x "$PAYLOAD_DIR/usr/local/bin/twosync"

# The twosync-setup helper
cat > "$PAYLOAD_DIR/usr/local/bin/twosync-setup" << 'SETUP_EOF'
#!/bin/bash
# twosync-setup — register an hourly LaunchAgent sync pair
set -e

if [[ $# -lt 2 ]]; then
  echo "Usage: twosync-setup <folder_a> <folder_b>"
  exit 1
fi

FOLDER_A="$(cd "$1" && pwd)"
FOLDER_B="$(cd "$2" && pwd)"
INSTALL_DIR="$HOME/.twosync"
HASH=$(python3 -c "import hashlib; print(hashlib.md5(f'{\"$FOLDER_A\"}|{\"$FOLDER_B\"}'.encode()).hexdigest()[:8])")
LABEL="com.user.twosync-$HASH"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$HOME/Library/LaunchAgents" "$INSTALL_DIR"

cat > "$PLIST" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$INSTALL_DIR/twosync.py</string>
        <string>$FOLDER_A</string>
        <string>$FOLDER_B</string>
    </array>
    <key>StartInterval</key><integer>3600</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$INSTALL_DIR/stdout.log</string>
    <key>StandardErrorPath</key><string>$INSTALL_DIR/stderr.log</string>
</dict>
</plist>
PLIST_EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "✓ Hourly sync active:"
echo "    $FOLDER_A"
echo "  ↔ $FOLDER_B"
echo ""
echo "  Log: $INSTALL_DIR/twosync.log"
SETUP_EOF
chmod +x "$PAYLOAD_DIR/usr/local/bin/twosync-setup"

# Make scripts executable
chmod +x "$SCRIPTS_DIR/postinstall"

# ── Build component package ──────────────────────────────────────────────────
echo -e "${BLUE}▶${NC} Building component package..."
COMPONENT_PKG="/tmp/twosync-component.pkg"

pkgbuild \
  --root "$PAYLOAD_DIR" \
  --scripts "$SCRIPTS_DIR" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --install-location "/" \
  "$COMPONENT_PKG"

# ── Build distribution package with wizard UI ────────────────────────────────
echo -e "${BLUE}▶${NC} Building distribution package..."

# Generate distribution XML
DIST_XML="/tmp/twosync-distribution.xml"
cat > "$DIST_XML" << DIST_EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>twosync</title>
    <background file="background.png" alignment="bottomleft" scaling="proportional" mime-type="image/png"/>
    <welcome file="welcome.html" mime-type="text/html"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <options customize="never" require-scripts="false" rootVolumeOnly="true"/>
    <domains enable_localSystem="true" enable_currentUserHome="true"/>
    <pkg-ref id="${IDENTIFIER}"/>
    <choices-outline>
        <line choice="default">
            <line choice="${IDENTIFIER}"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="${IDENTIFIER}" visible="false">
        <pkg-ref id="${IDENTIFIER}"/>
    </choice>
    <pkg-ref id="${IDENTIFIER}" version="${VERSION}" onConclusion="none">twosync-component.pkg</pkg-ref>
</installer-gui-script>
DIST_EOF

productbuild \
  --distribution "$DIST_XML" \
  --resources "$RESOURCES_DIR" \
  --package-path "/tmp" \
  "$OUTPUT"

# ── Clean up ─────────────────────────────────────────────────────────────────
rm -f "$COMPONENT_PKG" "$DIST_XML"

echo ""
echo -e "${GREEN}${BOLD}✓ Built: $OUTPUT${NC}"
echo ""
echo "  To sign (optional, requires Apple Developer account):"
echo "    productsign --sign 'Developer ID Installer: Your Name' $PKG_NAME twosync-signed.pkg"
echo ""
echo "  To install:"
echo "    open $PKG_NAME"
echo ""
