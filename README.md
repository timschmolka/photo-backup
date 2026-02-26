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
| Albums / collections | LrC catalog | LrC → Immich (one-way, promoted to best format) |
| Picks → favorites | LrC catalog | LrC → Immich (one-way) |
| Star ratings | LrC catalog | LrC → Immich (one-way) |
| File stacking | Immich (derived from filename stems) | Computed at sync time, merged incrementally |
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

The highest-priority format becomes the stack cover in Immich. Album references are automatically promoted to the best format — if LrC has the ARW in a collection but a TIF exists, the album points to the TIF. Lower-quality siblings are removed from the album since the stack groups them.

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

```
┌─────────────────────────────────────────────────────────────────┐
│  Phase 1 — Index    Fetch all Immich assets, build filename map │
│  Phase 2 — Collect  Read LrC regular + smart collections       │
│  Phase 3 — Albums   Match files → create/update Immich albums  │
│  Phase 4 — Meta     Picks → favorites, ratings 1–5             │
│  Phase 5 — Stacks   Group by stem, set format-priority cover   │
└─────────────────────────────────────────────────────────────────┘
```

1. Reads regular and smart collections from the LrC catalog (SQLite)
2. Fetches all Immich assets and builds a filename-based index (own assets only)
3. Matches LrC files to Immich assets by `originalFileName`
4. **Promotes album references** to the best available format — if a collection contains `DSC04027.ARW` but a `DSC04027.tif` also exists in Immich, the album points to the TIF. Lower-quality duplicates are automatically cleaned up.
5. Creates or updates Immich albums for each collection
6. Syncs LrC picks → Immich favorites and LrC star ratings → Immich ratings
7. Stacks related files (TIF/DNG/ARW) by normalized filename stem. Merges into existing partial stacks when new formats are added.
8. Idempotent — safe to run repeatedly without duplicating albums or assets

### Smart Collection Support

`pbak albums` parses Lightroom's smart collection rules (stored as Lua tables in the catalog) and translates them to SQL queries. Supported criteria:

| Criteria | Operations |
|----------|-----------|
| Capture time | before, after, equals, in last N days/months |
| Pick flag | picked, unflagged, rejected |
| Star rating | equals, greater-or-equal |
| File format | RAW, TIFF, JPG, HEIC, VIDEO |
| Keywords | contains, is empty |
| Focal length | less than, greater than |
| Color label | Red, Yellow, Green, Blue, Purple |
| Touch time | modified in last N days/months |

Smart collections with `intersect` or `union` combine modes are both supported.

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
