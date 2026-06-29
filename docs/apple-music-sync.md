# Apple Music (Local) sync — nightly incremental

Keeps the app's **Apple Music (Local)** data source in step with the Mac's real Apple Music
library. As of the incremental pivot it is **one fast step**, not a change-set pipeline.

`scripts/am-sync-nightly.sh` (a launchd timer at 04:00) runs `scripts/am-incremental-sync.mjs`
against the **live** Music library and, when anything changed, commits → pushes to GitHub →
deploys to S3. No `Library.xml`, no 6-hour export, no change-sets, no second agent.

```
Music.app (live, via AppleScript)
      │  bulk persistent-IDs (~0.6s) ─► diff vs committed index by song id
      ▼
am-incremental-sync.mjs ── enriched-fetch ONLY the new tracks (~seconds, position-indexed)
      │                    ── index those → new songs + albums
      │                    ── re-dump playlists → remap membership by song-id hash
      │                    ── merge into public/apple-music-index.json (existing songs verbatim)
      ▼
am-sync-nightly.sh (04:00 launchd) ── if changed: git commit → push → deploy.sh dev+prod
                                                   └─► es-index.mjs (refresh OpenSearch)
```

**Online search stays in step.** After a changed index ships, the nightly job also refreshes the
**OpenSearch** collection (`scripts/es-index.mjs`, full reset ~40s) so a newly-added track is
findable in the app's online-search mode the same night — not just after a manual reindex. It's
**non-fatal** (the catalog is already committed + on S3; a search hiccup just retries next run) and
runs only when the catalog actually changed. Skip with `POCKETDJ_SKIP_ES=1`; endpoint/sources
override via `POCKETDJ_ES_ENDPOINT` / `POCKETDJ_ES_SOURCES`; optional lyrics via
`POCKETDJ_ES_LYRICS_BASE`. (Verified: after a sync adding Ibeyi's "Offering", `/pocketdj/_search`
for "Olokun" returns the new song.)

## Why incremental (the pivot)

The committed `public/apple-music-index.json` **already holds every existing track at full
fidelity**, so the only new information each night is the handful of tracks you added or removed.
The old design did a *full* rebuild from a fresh full `Library.xml` — cheap when Music's native
"Share Library XML" provides that file instantly, but on Macs where that setting is gone the only
headless source is a per-track AppleScript export that takes **~6 hours** for ~93k tracks. Re-deriving
92k unchanged tracks nightly to catch ~700 new ones is pure waste.

Incremental sync instead:
1. **Bulk-fetches every current persistent ID** — one AppleScript event, ~0.6s for 92k tracks.
2. **Diffs against the committed index by song id** (`sng_ = sha1(ns|persistentID)`, shared via
   `scripts/lib/am-ids.mjs`) → the set of *new* pids and *removed* song ids.
3. **Enriched-fetches only the new tracks** by their library position (`item N of every track`),
   ~seconds for hundreds of tracks, via the shared AppleScript in `scripts/lib/am-music.mjs`.
4. **Indexes just those** (`index-apple-music.mjs` on a small Library.xml) → new songs + albums.
5. **Re-dumps playlists** (fast) and remaps membership straight to song ids by hash — no need to
   re-read all 92k tracks for playlist resolution.
6. **Merges** into the committed index: drop removed, add new, rebuild only the *touched* albums'
   track order, replace playlists. **Existing songs are preserved verbatim**, so their
   `appleMusicId` / `explicit` / `length` survive with no rebuild and no re-merge.

A no-change night is a true no-op: `am-incremental-sync` only bumps `manifest.generatedAt` when
something actually changed, so the file is byte-identical and `am-sync-nightly.sh`'s `cmp`
short-circuits before any git/deploy.

### The one field AppleScript can't read

Music does **not** expose the `explicit` flag over AppleScript ("descriptor type mismatch"). The
enriched dump captures everything else the indexer reads (album-artist, genre, year, track/disc#,
duration, Date Added, Location for local files, kind). For `explicit`, existing tracks keep their
flag automatically (they're preserved verbatim); genuinely-new tracks land `explicit=false` until
backfilled out-of-band. (The full-reconcile path — `scripts/dump-apple-music-library.mjs` — and
`scripts/am-merge-catalog-ids.mjs` carry it forward when a native `Library.xml` rebuild is used.)

## Trade-off (and the reconcile escape hatch)

Incremental catches **additions and removals** — the common case. It does **not** catch in-place
metadata *edits* to existing tracks (rare). For those, do an occasional **full reconcile**:
`scripts/dump-apple-music-library.mjs` exports the whole library (fast from Music's native
"Share Library XML" if available; the slow per-track AppleScript otherwise) → rebuild with
`index-apple-music.mjs` → `am-merge-catalog-ids.mjs` to carry `appleMusicId` + `explicit` forward.

## Activate

The nightly job runs from the working repo by default and is **SAFE-BY-GUARD**: it pulls, commits,
and ships only when the repo is on `main` and clean, so it never disrupts in-progress dev (it skips
that night and recovers the next).

```bash
# Preview WITHOUT installing (no pull/commit/deploy — every mutating step is echoed):
scripts/am-sync-nightly.sh --dry-run

# Install the 04:00 timer (edit the REPLACE_ME placeholders first):
cp scripts/launchd/com.pocketdj.am-sync-nightly.plist.template \
   ~/Library/LaunchAgents/com.pocketdj.am-sync-nightly.plist
launchctl load ~/Library/LaunchAgents/com.pocketdj.am-sync-nightly.plist
# Stop:  launchctl unload ~/Library/LaunchAgents/com.pocketdj.am-sync-nightly.plist
```

Overridable env: `POCKETDJ_NIGHTLY_REPO` (repo to sync from), `POCKETDJ_NODE_CMD`,
`POCKETDJ_GIT_CMD`, `POCKETDJ_DEPLOY_CMD`, `POCKETDJ_NIGHTLY_LOG`.

## Retired (legacy)

The previous **change-set → full-rebuild** pipeline is retired:

- The rip server's in-process **04:00 scheduler is disabled** — the launchd job owns 04:00 now
  (running both would double-run). Re-enable the legacy flow only with
  `POCKETDJ_ENABLE_LEGACY_AMCHECK=1`.
- `runAmCheck` (the rip server's `POST /am-sync` handler) still does the old `Library.xml` diff for
  the native app's **Settings ▸ "Sync Apple Music library"** button, but is **superseded** — the
  nightly incremental job is authoritative. It reads Music's shared `Library.xml` when present, else
  the static `~/Downloads/Library.xml` (which may be stale).
- `scripts/am-sync-agent.sh` + `com.pocketdj.am-sync-agent.plist.template` (the change-set-consuming
  cron agent) and the per-change-set library snapshots are no longer part of the live path.
- Music's **"Share Library XML"** setting is **no longer required** — incremental reads the live
  library directly. It's still the fastest source for a full reconcile when present.
