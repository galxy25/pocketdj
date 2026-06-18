---
name: apple-music-indexer
description: Index (and incrementally re-index) the PocketDJ "Apple Music (Local)" digital data source from the macOS Music/iTunes Library.xml into the index.json the app loads. Triggers on "index Apple Music", "re-index my library", "update the Apple Music index", "incremental Apple Music index", "I added songs, reindex". Fast, local-only (no network, no audio analysis); incremental via a Date-Added state file.
---

# Apple Music (Local) Indexer

Turns the macOS **Music/iTunes `Library.xml`** (a plist export of the user's
library) into the canonical PocketDJ index the app imports as a **digital** data
source (`manifest.sourceType: "digital"`, `sourceName: "Apple Music (Local)"`).

For each library track it creates a **song** item and groups tracks into **album**
items. Metadata it fills straight from the library (no network): artist, album
artist, album, genre, year, track/disc number, length, **explicit** flag, file
type, and the local file location when present. It also imports the user's
**playlists** (their own — skips Apple's master/smart/distinguished ones). It
**DEFERS** bpm/key/lyrics/sentiment and **cover art** — digital art is only added
later via a rip/burn, by design.

Reference run (Levi's library): **12,220 albums / 92,865 songs / 126 playlists**,
parsed from a ~160 MB Library.xml in **~1.6s**.

The tool is a single self-contained Node script — no skill-internal pipeline,
no agents, no API keys:

    scripts/index-apple-music.mjs

## Why a bespoke parser
The real library is ~160 MB / ~93k tracks. The script reads the plist **line by
line** and streams songs straight to disk (an ndjson it re-emits as the final
`songs[]`), so peak memory is bounded by the album count (~tens of thousands),
never the song count. The iTunes plist is extremely regular (every scalar is a
one-line `<key>K</key><type>V</type>`), which makes a line parser robust.

## Prerequisite: get a fresh Library.xml (the user does this once per re-index)
The native `~/Music/Music/Library.xml` only exists if "Share Library XML with
other applications" is enabled. The reliable path the user already uses:

> In **Music**, **File ▸ Library ▸ Export Library…** and save as
> `~/Downloads/Library.xml` (overwrite the previous one).

This file reflects the **entire** current library (incl. Apple Music cloud
tracks), so an export taken after adding songs contains the new songs. The
incremental logic below figures out what's new.

If you're an agent and the file is stale/absent, ask the user to re-export rather
than guessing — there is no clean CLI to produce it.

## Full (re)build — the whole library
Deletes nothing in the app; the importer upserts by stable id. Use when seeding
fresh or when you want to rebuild from scratch.

    # delete the state file first to force a FULL pass
    rm -f index-out/apple-music/state.json
    node --max-old-space-size=4096 scripts/index-apple-music.mjs \
      --xml ~/Downloads/Library.xml \
      --out index-out/apple-music/index.json \
      --state index-out/apple-music/state.json

Writes `index-out/apple-music/index.json` and a fresh
`index-out/apple-music/state.json` (records the max Date-Added seen).

## Incremental re-index — only the songs added since last time
**This is the common case** ("I added songs, update the index"). Keep the
`state.json` from the previous run. Passing `--state` (with no `--since`) makes the
script auto-resume from `state.lastDateAdded` and emit **only tracks added at/after
that timestamp**, plus the albums those songs touch, plus **all** user playlists
(playlists are small, so they're always re-emitted in full).

    # keep the existing state.json — do NOT delete it
    node --max-old-space-size=4096 scripts/index-apple-music.mjs \
      --xml ~/Downloads/Library.xml \
      --out index-out/apple-music/index-delta.json \
      --state index-out/apple-music/state.json

How incremental works:
- `state.json` holds `lastDateAdded` (ISO) = the most recent track Date-Added from
  the last run. On the next run, tracks with `Date Added < lastDateAdded` are
  mapped (so playlists can still resolve them) but **not emitted** as songs.
- The run rewrites `state.json` with the new max Date-Added, so successive runs
  chain forward.
- You can override the cutoff explicitly with `--since 2026-06-01T00:00:00Z`
  (takes precedence over the state file).
- **Deletions are out of scope** — a song removed from the library is not removed
  from the app by an incremental run. To prune, do a full rebuild into a fresh app
  catalog (Settings ▸ remove the source, then load the rebuilt index).

The delta index imports the same way as a full one — the app upserts songs/albums
by id and refreshes the 126 playlist mirrors idempotently. A delta with no new
songs still refreshes playlists.

## Useful flags
- `--source-name "Apple Music (Local)"` — data-source name (default; keep it so
  re-imports upsert the same source).
- `--all-playlists` — also import Apple's auto/smart/distinguished playlists
  (default: user playlists only).
- `--since <ISO>` — explicit incremental cutoff (overrides state.json).
- `--limit N` — parse only the first N tracks (smoke test).
- `--stats` — print counts (tracks/albums/playlists/top genres) and write nothing.

Quick sanity check before a real run:

    node scripts/index-apple-music.mjs --xml ~/Downloads/Library.xml --stats

## Ship it to the app
The app loads the index as the bundled, **opt-in** Apple Music source
(Settings ▸ Sources ▸ "＋ Load Apple Music (Local) library"). To update what that
button serves:

    # copy the freshly built index into the web app's public dir
    cp index-out/apple-music/index.json \
       <app>/public/apple-music-index.json     # e.g. the digital-source worktree

    # build + deploy (see the publish-s3 skill)
    npm run build
    scripts/deploy.sh dev      # then: scripts/deploy.sh prod

Notes:
- `public/apple-music-index.json` is committed like `public/current-index.json`
  and is **excluded from the service-worker precache** (precache globs omit
  `.json`), so it never bloats the SW.
- For an **incremental** ship you can either (a) regenerate the FULL index and
  replace the public file (simplest — the file is the source of truth the button
  fetches), or (b) hand the user the delta and let them import it via
  Settings ▸ Import. (a) is recommended so a fresh device gets everything in one
  tap.
- In the app, a user who already loaded the source just taps **↻ Force refresh**
  or re-runs the load to pick up the new file (import upserts).

## Contract / invariants (don't break these)
- IDs are **namespaced by source**: `alb_ = sha1("digital|<sourceName>|normArtist|normAlbum")[:12]`,
  `sng_ = sha1("digital|<sourceName>|<persistentID>")[:12]`. The app keys `items`
  by id alone, so namespacing keeps the same album owned on vinyl AND in Apple
  Music as **distinct** items. Never switch song ids off the track Persistent ID —
  it's globally unique in the library and stable across exports (that's what makes
  re-runs idempotent and dup track-numbers safe).
- Album `trackList` is sorted by disc then track number (the library lists tracks
  in add-order, which would otherwise scramble albums).
- Output conforms to `.claude/skills/analog-indexer/schema/index.schema.json`
  (`sourceType: "analog" | "digital"`, optional top-level `playlists[]`) and the
  app contract `src/types/index-json.ts`. Keep them in sync.
- No network, no audio analysis, no cover art for digital.
