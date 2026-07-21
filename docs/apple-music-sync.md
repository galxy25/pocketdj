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

The nightly job runs from a **dedicated always-on-`main` clone** (`~/.pocketdj/am-sync-clone`),
never from the dev checkout — a feature branch left checked out at 04:00 cannot starve the sync
(which it silently did 2026-07-01..03 under the old in-repo design). launchd invokes a stable
launcher in `~/.pocketdj/bin` that health-checks/re-creates the clone and hands off to the clone's
`am-sync-nightly.sh`, which resets to `origin/main` and re-execs itself, so the running sync code
is always fresh `main`. A single-instance lock (`~/.pocketdj/am-sync/.sync.lock`) keeps a manual
run and the 04:00 run from resetting the clone under each other.

```bash
# Preview WITHOUT installing (no clone/commit/deploy — mutating steps are echoed; the
# ignore-list state is sandboxed so a preview never alters what future real runs index):
scripts/am-sync-nightly.sh --dry-run

# Install/refresh the 04:00 timer (bakes the origin URL into the launcher, fills the
# plist placeholders, and (re)loads the job — idempotent):
scripts/install-am-sync-nightly.sh
# Stop:  launchctl unload ~/Library/LaunchAgents/com.pocketdj.am-sync-nightly.plist
```

Overridable env: `POCKETDJ_NIGHTLY_CLONE_DIR` (sync-clone path; set **empty** to run in-place —
then the legacy SAFE-BY-GUARD applies: only ships when the repo is on clean `main`),
`POCKETDJ_NIGHTLY_ORIGIN` (clone URL), `POCKETDJ_NIGHTLY_REPO`, `POCKETDJ_NODE_CMD`,
`POCKETDJ_GIT_CMD`, `POCKETDJ_DEPLOY_CMD`, `POCKETDJ_NIGHTLY_LOG`.

State under `~/.pocketdj/am-sync/`: `ignored-pids.json` (metadata-less ghost entries and
non-music tracks that must not re-diff as "new" nightly; emptiness-derived entries need 3
strikes on distinct days before they stick, and any pid that later indexes is rescued — delete
the file to re-probe everything) and `last-deployed-index.sha256` (deploy marker: a no-change
night still ships S3 + search if the last committed index was never confirmed deployed).

Data-safety circuit breakers (both abort the night's ship, converging next healthy run):
an empty/implausibly-shrunken library snapshot refuses to ship as a mass removal
(`POCKETDJ_ALLOW_MASS_REMOVAL=1` overrides), and an empty/>50%-shrunken playlist dump is
treated as a read failure (`POCKETDJ_ALLOW_PLAYLIST_SHRINK=1` overrides). Playlists present
in Music always ship — **empty is a state, not a deletion** (the OTG lesson: a mid-edit
playlist momentarily resolving to zero members must not ship as a deletion).

## Album `appleMusicId` (for Discover dedupe)

The Apple-Music indexer now emits an **album-level `appleMusicId`** (the iTunes
`collectionId`) alongside each song's catalog id. This is what closes the loop on the
**Discover ▸ Albums** add flow (see
[`streaming-integration.md` §5](./streaming-integration.md#5-discover--catalog-song-and-album-search--add)):
a Discover-added album is **provisional** (`amrec_album_<collectionId>`), and once you
own the album for real, the indexed album carrying the **same** id **supersedes** the
provisional one — no duplicate.

For albums that are already in the committed index, there's no need to re-run the full
`Library.xml` indexer to backfill the id. **`scripts/fold-album-catalogid.mjs`** stamps
it as a fast fold: it reads the per-track `collectionId`s captured by
`resolve-apple-music-catalog.mjs` (`index-out/apple-music/catalog-cache.ndjson`) and, for
each album, takes the **most-common non-empty** member `collectionId` (the same
mode-per-album rule `index-apple-music.mjs` uses) as the album's `appleMusicId`.

```bash
# dry-run (reports how many albums WOULD be stamped):
node scripts/fold-album-catalogid.mjs
# write it (defaults: public/apple-music-index.json + the catalog-cache ndjson):
node scripts/fold-album-catalogid.mjs --apply
```

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
