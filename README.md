# twosync

Two-way folder sync for macOS. Runs hourly via LaunchAgent. No dependencies — uses Python 3 (built into macOS).

## Install

```bash
chmod +x install.sh
./install.sh ~/Folder_A ~/Folder_B
```

Runs immediately, then every hour. Logs go to `~/.twosync/twosync.log`.

## Uninstall

```bash
./uninstall.sh
```

## Manual run

```bash
python3 twosync.py ~/Folder_A ~/Folder_B --verbose
```

Preview changes without applying them:

```bash
python3 twosync.py ~/Folder_A ~/Folder_B --dry-run --verbose
```

## How it works

On first run it scans both folders and saves a state snapshot in `~/.twosync/`.

On each subsequent run it compares the current state against the snapshot to determine what changed:

| Situation | Action |
|-----------|--------|
| File added to A | Copy to B |
| File added to B | Copy to A |
| File modified in A only | Overwrite B |
| File modified in B only | Overwrite A |
| File deleted from A | Delete from B |
| File deleted from B | Delete from A |
| File modified in both | Newer file wins (logged as conflict) |

## Exclusions

`.DS_Store`, `.Spotlight-V100`, `.Trashes`, `.fseventsd`, `Thumbs.db` are automatically ignored.

## Logs

```bash
tail -f ~/.twosync/twosync.log
```
