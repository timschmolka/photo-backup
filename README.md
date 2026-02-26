# pbak

Photo backup utility for a two-step workflow: **SD card → SSD → Immich**.

Wraps [immich-go](https://github.com/simulot/immich-go) with interactive volume selection, EXIF-based date organization, SHA-256 deduplication, SSD mirroring, upload state tracking, and Lightroom Classic integration.

## Architecture

```
                         ┌─────────────────────────────────────────┐
                         │             Immich Server               │
                         │  ┌─────────┐ ┌────────┐ ┌───────────┐  │
                         │  │ Assets  │ │ Albums │ │  Stacks   │  │
                         │  └────▲────┘ └───▲────┘ └─────▲─────┘  │
                         └───────┼──────────┼────────────┼────────┘
                                 │          │            │
                           upload│    albums│      albums│
                        immich-go│   REST API     REST API
                                 │          │            │
┌──────────┐   dump    ┌────────┴──────────┴────────────┴──┐
│ SD Card  │ ────────▶ │           Primary SSD              │
│ (DCIM/)  │  exiftool │  full_dump/YYYY/MM/DD/DSC0001.ARW  │
└──────────┘  sha-256  │  .pbak/hashes.db                   │
                       │  .pbak/upload-state/                │
                       └──────────┬────────────────────────┘
                           sync   │  rsync
                       ┌──────────▼────────────────────────┐
                       │          Mirror SSD                │
                       │  full_dump/YYYY/MM/DD/DSC0001.ARW  │
                       └───────────────────────────────────┘

┌──────────────────────┐
│   LrC Catalog        │    albums
│   (.lrcat SQLite)    │ ──────────▶  Immich Albums, Favorites,
│   Collections        │   python3    Ratings, Stacks
│   Picks / Ratings    │
└──────────────────────┘
```

### Source of Truth

| Data | Source of Truth | Direction |
|------|----------------|-----------|
| Photo files (RAW, TIF, DNG) | Primary SSD | SSD → Immich (upload) |
| Date folder structure | Primary SSD | SSD → Immich |
| Hash dedup database | Primary SSD (`.pbak/hashes.db`) | Local only |
| Upload state tracking | Primary SSD (`.pbak/upload-state/`) | Local only |
| Albums / collections | LrC catalog | LrC → Immich (one-way) |
| Picks → favorites | LrC catalog | LrC → Immich (one-way) |
| Star ratings | LrC catalog | LrC → Immich (one-way) |
| File stacking | Immich (derived from filename stems) | Computed at sync time |
| Mirror SSD | Primary SSD | Primary → Mirror (one-way, additive) |

All syncs are **one-way**. Immich and the mirror SSD are treated as downstream consumers — they never write back to the SSD or LrC catalog.

### Data Flow

```
1. SHOOT     Camera ──▶ SD Card

2. DUMP      SD Card ──▶ SSD (EXIF date sort, SHA-256 dedup)
                  └────▶ Mirror SSD (auto-sync if mounted)

3. UPLOAD    SSD ──────▶ Immich (via immich-go, per-folder state tracking)

4. ORGANIZE  LrC ──────▶ Immich (collections → albums, picks → favs,
                                  ratings, stacking)
```

### File Lifecycle

A single photo may exist as multiple files at different processing stages:

```
DSC04883.ARW                    ← Camera RAW (original)
DSC04883-DxO_DeepPRIME XD2s.dng ← DxO PureRAW processed
DSC04883.tif                    ← LrC export (final edit)
```

All three are uploaded to Immich independently. `pbak albums` groups them by normalizing the filename stem (stripping DxO suffixes and virtual copy numbers) and creates a stack with format priority:

```
TIF (1) > DNG (2) > RAW (3) > JPG (4) > HEIC (5)
```

The highest-priority format becomes the stack cover in Immich.

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

# 4. Sync LrC collections to Immich albums
pbak albums
```

## Commands

| Command | Description |
|---------|-------------|
| `pbak setup` | Interactive configuration wizard |
| `pbak dump` | Copy SD → SSD with hash-based deduplication |
| `pbak upload` | Upload SSD → Immich via immich-go |
| `pbak status` | Show config, backup stats, upload state |
| `pbak sync` | Sync primary SSD to a mirror SSD |
| `pbak albums` | Sync Lightroom Classic collections to Immich albums |
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
- `--force` — re-upload all folders (immich-go skips server-side duplicates)

### Sync Flags

- `--from <name>` — primary SSD volume (source)
- `--to <name>` — mirror SSD volume (destination)

### Albums Flags

- `--collection <name>` — sync a single collection by name
- `--no-metadata` — skip pick/rating metadata sync
- `--no-stacks` — skip file stacking
- `--prune` — remove assets from Immich albums that are no longer in LrC

## How It Works

### Dump (SD → SSD)

1. Scans `DCIM/` on SD card for matching file extensions
2. Extracts photo date from EXIF metadata (DateTimeOriginal → CreateDate → FileModifyDate → filesystem date)
3. Computes SHA-256 hash and checks against local database
4. Copies new files to `full_dump/YYYY/MM/DD/` on SSD
5. Verifies copy integrity with hash comparison
6. Records hash in database for future deduplication
7. If a mirror SSD is configured and mounted, automatically syncs to it

### Upload (SSD → Immich)

1. Lists date folders on SSD, filters out already-uploaded ones
2. Runs `immich-go upload from-folder` with configured flags
3. immich-go handles server-side deduplication (SHA1 pre-check)
4. Tracks upload status per folder (uploaded/failed/pending)

### Sync (SSD → Mirror SSD)

1. One-way additive sync using rsync (`--ignore-existing`)
2. Copies new files from primary SSD to mirror — nothing is ever deleted from mirror
3. Runs automatically after `pbak dump` if mirror SSD is configured and mounted

### Albums (LrC → Immich)

1. Reads regular and smart collections from the LrC catalog (SQLite)
2. Fetches all Immich assets and builds a filename-based index
3. Matches LrC files to Immich assets by `originalFileName`
4. Creates or updates Immich albums for each collection
5. Syncs LrC picks → Immich favorites and LrC ratings → Immich ratings
6. Stacks related files (TIF/DNG/ARW) by normalized filename stem, with format priority: TIF > DNG > RAW > JPG > HEIC
7. Idempotent — safe to run repeatedly without duplicating albums or assets

## Project Structure

```
photo-backup/
├── bin/pbak              # Entry point — flag parsing, command dispatch
├── lib/pbak/
│   ├── albums.py         # Album sync engine (Python, stdlib only)
│   ├── albums.sh         # Bash wrapper for albums.py
│   ├── config.sh         # Config load/save/setup wizard
│   ├── dump.sh           # SD → SSD copy with EXIF dating + dedup
│   ├── hash.sh           # SHA-256 hashing and database
│   ├── sync.sh           # rsync-based SSD mirroring
│   ├── ui.sh             # Terminal UI (colors, spinners, prompts)
│   ├── upload.sh         # SSD → Immich upload via immich-go
│   └── utils.sh          # Shared helpers (volume detection, logging)
├── completions/pbak.zsh  # Zsh tab completion
├── Makefile              # Install / uninstall / test
└── README.md
```

## Configuration

Stored at `~/.config/pbak/config`. Created by `pbak setup`.

Key settings:
- Immich server URL and API key
- Default SD card, SSD, and mirror SSD volume names
- File extension include/exclude lists (separate for dump and upload)
- Concurrent upload tasks, pause jobs setting
- Lightroom Classic catalog path (`.lrcat` file)

## Dependencies

Automatically checked and offered for install via Homebrew:

- [immich-go](https://github.com/simulot/immich-go) — Immich upload client
- [exiftool](https://exiftool.org/) — EXIF metadata extraction
- `python3` — required for `pbak albums` (uses only stdlib: `sqlite3`, `urllib`, `json`)
- `shasum` — SHA-256 hashing (ships with macOS)

## License

MIT
