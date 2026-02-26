# pbak

Photo backup utility for a two-step workflow: **SD card → SSD → Immich**.

Wraps [immich-go](https://github.com/simulot/immich-go) with interactive volume selection, EXIF-based date organization, SHA-256 deduplication, and upload state tracking.

## Install

```bash
brew install timschmolka/photo-backup/pbak
```

Or manually:

```bash
git clone https://github.com/timschmolka/photo-backup.git
cd photo-backup
make install
```

## Quick Start

```bash
# 1. Configure Immich server, volumes, extensions
pbak setup

# 2. Copy photos from SD card to SSD (YYYY/MM/DD structure)
pbak dump

# 3. Upload from SSD to Immich
pbak upload --all
```

## Commands

| Command | Description |
|---------|-------------|
| `pbak setup` | Interactive configuration wizard |
| `pbak dump` | Copy SD → SSD with hash-based deduplication |
| `pbak upload` | Upload SSD → Immich via immich-go |
| `pbak status` | Show config, backup stats, upload state |
| `pbak rehash` | Rebuild hash database from existing SSD files |

### Global Flags

- `--dry-run` — preview without making changes
- `--verbose` — detailed logging
- `--version` — print version

### Dump Flags

- `--sd <name>` — override SD card volume
- `--ssd <name>` — override SSD volume

### Upload Flags

- `--ssd <name>` — override SSD volume
- `--date <YYYY/MM/DD>` — upload specific date folder
- `--all` — upload all pending folders
- `--retry-failed` — retry previously failed uploads

## How It Works

### Dump (SD → SSD)

1. Scans `DCIM/` on SD card for matching file extensions
2. Extracts photo date from EXIF metadata (DateTimeOriginal → CreateDate → FileModifyDate → filesystem date)
3. Computes SHA-256 hash and checks against local database
4. Copies new files to `full_dump/YYYY/MM/DD/` on SSD
5. Verifies copy integrity with hash comparison
6. Records hash in database for future deduplication

### Upload (SSD → Immich)

1. Lists date folders on SSD, filters out already-uploaded ones
2. Runs `immich-go upload from-folder` with configured flags
3. immich-go handles server-side deduplication (SHA1 pre-check)
4. Tracks upload status per folder (uploaded/failed/pending)

## Configuration

Stored at `~/.config/pbak/config`. Created by `pbak setup`.

Key settings:
- Immich server URL and API key
- Default SD card and SSD volume names
- File extension include/exclude lists (separate for dump and upload)
- Concurrent upload tasks, pause jobs setting

## Dependencies

Automatically checked and offered for install via Homebrew:

- [immich-go](https://github.com/simulot/immich-go) — Immich upload client
- [exiftool](https://exiftool.org/) — EXIF metadata extraction
- `shasum` — SHA-256 hashing (ships with macOS)

## License

MIT
