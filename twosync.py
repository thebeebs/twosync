#!/usr/bin/env python3
"""
twosync — two-way folder sync with deletion support for macOS
Usage: twosync.py <folder_a> <folder_b> [--dry-run] [--verbose]
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
    """Return {relative_path: mtime} for all files, skipping exclusions."""
    result = {}
    for root, dirs, files in os.walk(folder):
        # Prune excluded dirs in-place
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
        # Remove empty parent dirs up to the root
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

    label = f"{folder_a.name} ↔ {folder_b.name}"
    log.info(f"{'[DRY RUN] ' if dry_run else ''}Starting sync: {label}")
    log.info(f"  A: {folder_a}")
    log.info(f"  B: {folder_b}")

    sf = state_file(folder_a, folder_b)
    prev = load_state(sf)          # {rel: {a_mtime, b_mtime}} from last run
    prev_a = prev.get("a", {})     # rel → mtime at last run
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

        # ── CONFLICT: both modified since last run ──────────────────────────
        if a_changed and b_changed:
            if a_mtime >= b_mtime:
                log.warning(f"CONFLICT (A wins, newer): {rel}")
                copy_file(a_path, b_path, dry_run)
            else:
                log.warning(f"CONFLICT (B wins, newer): {rel}")
                copy_file(b_path, a_path, dry_run)
            stats["conflicts"] += 1

        # ── NEW in A → copy to B ────────────────────────────────────────────
        elif a_new and not in_b_now:
            log.info(f"A→B  NEW   {rel}")
            copy_file(a_path, b_path, dry_run)
            stats["copied"] += 1

        # ── NEW in B → copy to A ────────────────────────────────────────────
        elif b_new and not in_a_now:
            log.info(f"B→A  NEW   {rel}")
            copy_file(b_path, a_path, dry_run)
            stats["copied"] += 1

        # ── MODIFIED in A only → push to B ─────────────────────────────────
        elif a_changed and not b_changed:
            log.info(f"A→B  MOD   {rel}")
            copy_file(a_path, b_path, dry_run)
            stats["copied"] += 1

        # ── MODIFIED in B only → push to A ─────────────────────────────────
        elif b_changed and not a_changed:
            log.info(f"B→A  MOD   {rel}")
            copy_file(b_path, a_path, dry_run)
            stats["copied"] += 1

        # ── DELETED from A → delete from B ─────────────────────────────────
        elif a_deleted and not b_changed:
            log.info(f"DEL  A→B   {rel}")
            delete_file(b_path, dry_run)
            stats["deleted"] += 1

        # ── DELETED from B → delete from A ─────────────────────────────────
        elif b_deleted and not a_changed:
            log.info(f"DEL  B→A   {rel}")
            delete_file(a_path, dry_run)
            stats["deleted"] += 1

        # ── Both deleted — nothing to do ────────────────────────────────────
        elif a_deleted and b_deleted:
            pass

        else:
            stats["skipped"] += 1

    # Save new state
    if not dry_run:
        # Re-scan after changes
        new_a = scan(folder_a)
        new_b = scan(folder_b)
        save_state(sf, {"a": new_a, "b": new_b, "last_run": datetime.now().isoformat()})

    log.info(
        f"Done. copied={stats['copied']}  deleted={stats['deleted']}  "
        f"conflicts={stats['conflicts']}  unchanged={stats['skipped']}"
    )
    return stats


def main():
    parser = argparse.ArgumentParser(
        description="twosync — two-way folder sync for macOS"
    )
    parser.add_argument("folder_a", help="First folder")
    parser.add_argument("folder_b", help="Second folder")
    parser.add_argument("--dry-run", action="store_true", help="Preview only, no changes")
    parser.add_argument("--verbose", "-v", action="store_true", help="Print to terminal too")
    args = parser.parse_args()

    a = Path(args.folder_a).expanduser().resolve()
    b = Path(args.folder_b).expanduser().resolve()

    for folder in (a, b):
        if not folder.exists():
            print(f"Error: folder does not exist: {folder}", file=sys.stderr)
            sys.exit(1)
        if not folder.is_dir():
            print(f"Error: not a directory: {folder}", file=sys.stderr)
            sys.exit(1)

    sync(a, b, dry_run=args.dry_run, verbose=args.verbose)


if __name__ == "__main__":
    main()
