#!/bin/bash
# ─────────────────────────────────────────────────────────────
#  twosync installer
#  Installs the sync tool and optionally sets up a sync pair
# ─────────────────────────────────────────────────────────────

set -e

INSTALL_DIR="$HOME/.twosync"
BIN_DIR="/usr/local/bin"
SCRIPT_NAME="twosync"
PLIST_NAME="com.user.twosync"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

print_header() {
  echo ""
  echo -e "${BOLD}╔════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║         twosync installer          ║${NC}"
  echo -e "${BOLD}╚════════════════════════════════════╝${NC}"
  echo ""
}

print_step() {
  echo -e "${BLUE}▶${NC} $1"
}

print_ok() {
  echo -e "  ${GREEN}✓${NC} $1"
}

print_warn() {
  echo -e "  ${YELLOW}⚠${NC}  $1"
}

print_error() {
  echo -e "  ${RED}✗${NC} $1"
}

check_macos() {
  if [[ "$(uname)" != "Darwin" ]]; then
    print_error "twosync requires macOS"
    exit 1
  fi
}

check_python() {
  print_step "Checking Python 3..."
  if command -v python3 &>/dev/null; then
    VER=$(python3 --version 2>&1)
    print_ok "Found $VER"
  else
    print_error "Python 3 not found. Install it from https://python.org or via Homebrew: brew install python3"
    exit 1
  fi
}

install_script() {
  print_step "Installing twosync script..."

  mkdir -p "$INSTALL_DIR"

  # Write the Python script directly into the install dir
  cat > "$INSTALL_DIR/twosync.py" << 'PYEOF'
#!/usr/bin/env python3
"""
twosync — two-way folder sync with deletion support for macOS
"""

import os
import sys
import json
import shutil
import hashlib
import argparse
import logging
from pathlib import Path
from datetime import datetime

STATE_DIR = Path.home() / ".twosync"
LOG_FILE = STATE_DIR / "twosync.log"

EXCLUDES = {".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd", "Thumbs.db"}


def setup_logging(verbose: bool):
    STATE_DIR.mkdir(exist_ok=True)
    handlers = [logging.FileHandler(LOG_FILE)]
    if verbose:
        handlers.append(logging.StreamHandler())
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s  %(levelname)-7s  %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        handlers=handlers,
    )


def state_file(a: Path, b: Path) -> Path:
    key = hashlib.md5(f"{a}|{b}".encode()).hexdigest()[:12]
    return STATE_DIR / f"state-{key}.json"


def load_state(path: Path) -> dict:
    if path.exists():
        try:
            return json.loads(path.read_text())
        except Exception:
            pass
    return {}


def save_state(path: Path, state: dict):
    STATE_DIR.mkdir(exist_ok=True)
    path.write_text(json.dumps(state, indent=2))


def scan(folder: Path) -> dict:
    result = {}
    for root, dirs, files in os.walk(folder):
        dirs[:] = [d for d in dirs if d not in EXCLUDES]
        for fname in files:
            if fname in EXCLUDES:
                continue
            full = Path(root) / fname
            rel = str(full.relative_to(folder))
            try:
                result[rel] = full.stat().st_mtime
            except OSError:
                pass
    return result


def copy_file(src: Path, dst: Path, dry_run: bool):
    dst.parent.mkdir(parents=True, exist_ok=True)
    if not dry_run:
        shutil.copy2(src, dst)


def delete_file(path: Path, dry_run: bool):
    if not dry_run and path.exists():
        path.unlink()
        parent = path.parent
        try:
            while parent != path.root and not any(parent.iterdir()):
                parent.rmdir()
                parent = parent.parent
        except Exception:
            pass


def sync(folder_a: Path, folder_b: Path, dry_run: bool = False, verbose: bool = False):
    setup_logging(verbose)
    log = logging.getLogger()

    log.info(f"{'[DRY RUN] ' if dry_run else ''}Starting sync: {folder_a.name} ↔ {folder_b.name}")

    sf = state_file(folder_a, folder_b)
    prev = load_state(sf)
    prev_a = prev.get("a", {})
    prev_b = prev.get("b", {})

    now_a = scan(folder_a)
    now_b = scan(folder_b)

    all_files = set(now_a) | set(now_b) | set(prev_a) | set(prev_b)
    stats = {"copied": 0, "deleted": 0, "conflicts": 0, "skipped": 0}

    for rel in sorted(all_files):
        a_path = folder_a / rel
        b_path = folder_b / rel

        in_a_now  = rel in now_a
        in_b_now  = rel in now_b
        in_a_prev = rel in prev_a
        in_b_prev = rel in prev_b

        a_mtime = now_a.get(rel, 0)
        b_mtime = now_b.get(rel, 0)
        a_prev  = prev_a.get(rel, 0)
        b_prev  = prev_b.get(rel, 0)

        a_changed = in_a_now and (a_mtime != a_prev)
        b_changed = in_b_now and (b_mtime != b_prev)
        a_deleted = in_a_prev and not in_a_now
        b_deleted = in_b_prev and not in_b_now
        a_new     = in_a_now and not in_a_prev
        b_new     = in_b_now and not in_b_prev

        if a_changed and b_changed:
            if a_mtime >= b_mtime:
                log.warning(f"CONFLICT (A wins): {rel}")
                copy_file(a_path, b_path, dry_run)
            else:
                log.warning(f"CONFLICT (B wins): {rel}")
                copy_file(b_path, a_path, dry_run)
            stats["conflicts"] += 1
        elif a_new and not in_b_now:
            log.info(f"A→B  NEW   {rel}")
            copy_file(a_path, b_path, dry_run)
            stats["copied"] += 1
        elif b_new and not in_a_now:
            log.info(f"B→A  NEW   {rel}")
            copy_file(b_path, a_path, dry_run)
            stats["copied"] += 1
        elif a_changed and not b_changed:
            log.info(f"A→B  MOD   {rel}")
            copy_file(a_path, b_path, dry_run)
            stats["copied"] += 1
        elif b_changed and not a_changed:
            log.info(f"B→A  MOD   {rel}")
            copy_file(b_path, a_path, dry_run)
            stats["copied"] += 1
        elif a_deleted and not b_changed:
            log.info(f"DEL  A→B   {rel}")
            delete_file(b_path, dry_run)
            stats["deleted"] += 1
        elif b_deleted and not a_changed:
            log.info(f"DEL  B→A   {rel}")
            delete_file(a_path, dry_run)
            stats["deleted"] += 1
        else:
            stats["skipped"] += 1

    if not dry_run:
        new_a = scan(folder_a)
        new_b = scan(folder_b)
        save_state(sf, {"a": new_a, "b": new_b, "last_run": datetime.now().isoformat()})

    log.info(f"Done. copied={stats['copied']}  deleted={stats['deleted']}  conflicts={stats['conflicts']}  unchanged={stats['skipped']}")
    return stats


def main():
    parser = argparse.ArgumentParser(description="twosync — two-way folder sync")
    parser.add_argument("folder_a", help="First folder")
    parser.add_argument("folder_b", help="Second folder")
    parser.add_argument("--dry-run", action="store_true", help="Preview only, no changes")
    parser.add_argument("--verbose", "-v", action="store_true", help="Print to terminal")
    args = parser.parse_args()

    a = Path(args.folder_a).expanduser().resolve()
    b = Path(args.folder_b).expanduser().resolve()

    for folder in (a, b):
        if not folder.exists():
            print(f"Error: folder does not exist: {folder}", file=sys.stderr)
            sys.exit(1)

    sync(a, b, dry_run=args.dry_run, verbose=args.verbose)


if __name__ == "__main__":
    main()
PYEOF

  chmod +x "$INSTALL_DIR/twosync.py"
  print_ok "Script installed to $INSTALL_DIR/twosync.py"
}

install_bin() {
  print_step "Installing 'twosync' command..."

  # Try /usr/local/bin, fall back to ~/bin
  if [[ -w "$BIN_DIR" ]] || sudo -n true 2>/dev/null; then
    WRAPPER="$BIN_DIR/$SCRIPT_NAME"
    sudo tee "$WRAPPER" > /dev/null << EOF
#!/bin/bash
exec python3 "$INSTALL_DIR/twosync.py" "\$@"
EOF
    sudo chmod +x "$WRAPPER"
    print_ok "Command available: twosync"
  else
    # Fallback: ~/bin
    mkdir -p "$HOME/bin"
    WRAPPER="$HOME/bin/$SCRIPT_NAME"
    cat > "$WRAPPER" << EOF
#!/bin/bash
exec python3 "$INSTALL_DIR/twosync.py" "\$@"
EOF
    chmod +x "$WRAPPER"
    print_ok "Command installed to ~/bin/twosync"
    # Check if ~/bin is in PATH
    if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
      print_warn "Add ~/bin to your PATH — add this to ~/.zshrc or ~/.bash_profile:"
      echo ""
      echo "    export PATH=\"\$HOME/bin:\$PATH\""
      echo ""
    fi
  fi
}

setup_pair() {
  echo ""
  echo -e "${BOLD}Set up an hourly sync pair?${NC}"
  echo -e "  You can skip this and run ${BLUE}twosync-setup${NC} later to add pairs."
  echo ""
  read -r -p "  Set up a sync pair now? [y/N] " REPLY
  echo ""

  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    read -r -p "  Folder A path: " FOLDER_A_RAW
    read -r -p "  Folder B path: " FOLDER_B_RAW

    FOLDER_A="$(eval echo "$FOLDER_A_RAW")"
    FOLDER_B="$(eval echo "$FOLDER_B_RAW")"

    if [[ ! -d "$FOLDER_A" ]]; then
      print_error "Folder A does not exist: $FOLDER_A"
      return
    fi
    if [[ ! -d "$FOLDER_B" ]]; then
      print_error "Folder B does not exist: $FOLDER_B"
      return
    fi

    mkdir -p "$HOME/Library/LaunchAgents"

    cat > "$PLIST_PATH" << PLIST_EOF
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
        <string>${INSTALL_DIR}/twosync.py</string>
        <string>${FOLDER_A}</string>
        <string>${FOLDER_B}</string>
    </array>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${INSTALL_DIR}/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${INSTALL_DIR}/stderr.log</string>
</dict>
</plist>
PLIST_EOF

    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    launchctl load "$PLIST_PATH"

    print_ok "Hourly sync active:"
    echo ""
    echo -e "    ${BLUE}$FOLDER_A${NC}"
    echo -e "    ↔  ${BLUE}$FOLDER_B${NC}"
    echo ""
    echo -e "  First sync running now. Log: ${INSTALL_DIR}/twosync.log"
  else
    echo "  Skipped. To add a pair later:"
    echo ""
    echo "    twosync /path/to/A /path/to/B          # run once"
    echo "    twosync-setup /path/to/A /path/to/B    # set up hourly"
    echo ""
  fi
}

install_setup_helper() {
  # Install a helper command for setting up new pairs
  SETUP_BIN="${BIN_DIR}/twosync-setup"
  SETUP_TMP=$(mktemp)

  cat > "$SETUP_TMP" << SETUP_EOF
#!/bin/bash
# twosync-setup — register a new sync pair as an hourly LaunchAgent
set -e
if [[ \$# -lt 2 ]]; then
  echo "Usage: twosync-setup <folder_a> <folder_b>"
  exit 1
fi
FOLDER_A="\$(cd "\$1" && pwd)"
FOLDER_B="\$(cd "\$2" && pwd)"
HASH=\$(python3 -c "import hashlib; print(hashlib.md5(f'{\$FOLDER_A}|{\$FOLDER_B}'.encode()).hexdigest()[:8])")
PLIST="\$HOME/Library/LaunchAgents/com.user.twosync-\$HASH.plist"
cat > "\$PLIST" << P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.user.twosync-\$HASH</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>${INSTALL_DIR}/twosync.py</string>
        <string>\$FOLDER_A</string>
        <string>\$FOLDER_B</string>
    </array>
    <key>StartInterval</key><integer>3600</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>${INSTALL_DIR}/stdout.log</string>
    <key>StandardErrorPath</key><string>${INSTALL_DIR}/stderr.log</string>
</dict>
</plist>
P
launchctl unload "\$PLIST" 2>/dev/null || true
launchctl load "\$PLIST"
echo "✓ Hourly sync registered: \$FOLDER_A ↔ \$FOLDER_B"
SETUP_EOF

  if [[ -w "$BIN_DIR" ]] || sudo -n true 2>/dev/null; then
    sudo cp "$SETUP_TMP" "$SETUP_BIN"
    sudo chmod +x "$SETUP_BIN"
  else
    cp "$SETUP_TMP" "$HOME/bin/twosync-setup"
    chmod +x "$HOME/bin/twosync-setup"
  fi
  rm "$SETUP_TMP"
}

print_summary() {
  echo ""
  echo -e "${GREEN}${BOLD}Installation complete!${NC}"
  echo ""
  echo -e "  ${BOLD}Run a one-off sync:${NC}"
  echo "    twosync ~/FolderA ~/FolderB --verbose"
  echo ""
  echo -e "  ${BOLD}Preview without changes:${NC}"
  echo "    twosync ~/FolderA ~/FolderB --dry-run --verbose"
  echo ""
  echo -e "  ${BOLD}Set up a new hourly pair:${NC}"
  echo "    twosync-setup ~/FolderA ~/FolderB"
  echo ""
  echo -e "  ${BOLD}View logs:${NC}"
  echo "    tail -f ~/.twosync/twosync.log"
  echo ""
  echo -e "  ${BOLD}Uninstall:${NC}"
  echo "    launchctl unload ~/Library/LaunchAgents/com.user.twosync*.plist"
  echo "    rm -rf ~/.twosync /usr/local/bin/twosync /usr/local/bin/twosync-setup"
  echo ""
}

# ── Main ─────────────────────────────────────────────────────

print_header
check_macos
check_python
install_script
install_bin
install_setup_helper
setup_pair
print_summary
