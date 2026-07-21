# PocketDJ — Development

PocketDJ ships **two clients** off the same catalog + backends:

- the **PWA** (repo root — `src/`, `public/`; this is the bulk of this doc):
  offline-first **React 18 + Vite + TypeScript**, data in **IndexedDB**, no backend.
  The "API" is the client itself; every data op emits a console transcript line for
  auditing and tests.
- the **native SwiftUI app** (`apple/`): one universal target on **iPhone / iPad /
  Mac** (iOS 18 / macOS 15), built with **XcodeGen → xcodebuild**, shipped via
  **TestFlight**. See *[Native app](#native-app-iphone--ipad--mac)* below and the
  deep references in `apple/README.md` + `apple/docs/build-and-test.md`.

Both clients share the **analog indexer** (a Claude skill of local Node scripts that
produces the `index.json` they load), the **rip server** (rip-on-demand + live
streaming off the iMac), and the **stem indexer** (Demucs) — see *[Native app](#native-app-iphone--ipad--mac)*
and *[Backend services](#backend-services-rip-server--stems)*.

## Quick start

```bash
npm install
npm run dev            # Vite dev server @ http://localhost:5173
npm run typecheck      # tsc -b --noEmit, fast type-only check
npm run build          # tsc -b && vite build -> dist/ (PWA shell + service worker)
npm run gen:mock       # generate public/mock-index.json (demo data at scale)
npm test               # vitest run — pure-module unit tests
npm run test:e2e       # Playwright (Chromium) e2e — see Testing
```

A screen-by-screen product walkthrough with real screenshots lives in
[`docs/STORYBOOK.md`](docs/STORYBOOK.md); regenerate the shots with the dev server
running via `node scripts/screenshots/capture.mjs`.

## Tech choices

| Concern | Choice | Why |
| --- | --- | --- |
| Build / PWA | Vite 6 + `vite-plugin-pwa` (Workbox `generateSW`) | precache the app shell only |
| UI | React 18 + `react-router-dom` | routed, deep-linkable views (tiers + solar systems live in the URL) |
| Storage | **`idb`** | tiny IndexedDB wrapper; the catalog fits in RAM, so queries run in-memory |
| Zip | **`fflate`** | streaming, memory-safe across 100MB+ of cover-art blobs |
| State | **`zustand`** (+`persist` for UI prefs only) | selector subscriptions; data itself stays in IndexedDB |
| Virtualization | **`@tanstack/react-virtual`** | smooth at ~12.8k songs / ~1.4k album cards |
| PRNG | hand-rolled `fnv1a` + `mulberry32` | deterministic star/placeholder layout, zero-dep |
| Unit tests | **Vitest** (`environment: node`) | the testable modules are pure (no DOM) |
| E2E | **Playwright (Chromium)** | the spec's required browser; console-transcript proof |

## Project layout

```
src/
  types/        model.ts (DataSource/AlbumItem/SongItem union, AudioTrack, ArtSource), index-json.ts (import shape),
                filter.ts, starmap.ts (Star/Constellation/Nebula/Planet/SolarSystem + Tier)
  storage/      db.ts (idb schema), repo.ts (ONLY db access + transcript logging),
                artCache.ts (progressive cover sources / blobs / ref-counted display registry / placeholders),
                importIndex.ts, exportZip.ts, importZip.ts
  engine/       fieldRegistry.ts (filterable/sortable fields, incl. camelot), filterEngine.ts (eq/neq/in/between), sortEngine.ts
  starmap/      constellationMap.ts (genre -> {category, subgenre}), grouping.ts (songs -> BPM/key nebulae + filter),
                layout.ts (genre two-tier geometry + nebula layout), solarSystem.ts (orbits)  — all pure, renderer-agnostic
  store/        useAppStore (source/type/view), useBrowserStore (filter/sort, persisted), useDataStore (item cache)
  components/   layout/ (AppShell, TopBar, SettingsModal), browser/ (selector, FilterBuilder, ItemGrid, ItemCard,
                AlbumTrackTable, EditItemModal, PlugInIndicator, ImportExportBar…),
                starmap/ (StarMapScene, ConstellationField, ConstellationGrid, NebulaField, SolarSystemView,
                SongDetailModal, AudioTracksModal/Table, AudioEditModal),
                common/ (Modal, Thumbnail, useArtUrl)
  lib/          log.ts (PDJ_API transcript), dataActions.ts (seed/import/export/forceRefresh), debug.ts (window.__pdj),
                format.ts, prng.ts, concurrency.ts, camelot.ts (Camelot wheel: rank/color/key<->camelot), useIsMobile.ts
scripts/        generate-mock-index.ts, deploy.sh (S3+CloudFront), run-pipeline.sh / run-backfill.sh (indexer),
                screenshots/capture.mjs (storybook screenshots)
docs/           STORYBOOK.md + storybook/*.png (product walkthrough)
.claude/skills/analog-indexer/   the indexer (lib/, workflow/, schema/, docs/, SKILL.md)
tests/e2e/      Playwright specs + fixtures + proof/<feature>/ artifacts
```

## Data model

Discriminated union on `type` (`src/types/model.ts`). `AlbumItem` (artist, name,
`coverArtKey`/`coverArtUrl`/**`coverArtSources[]`**, genre, year, country,
`trackIds[]`, `pointer`, `fileType`, `enrichment`, plus the audio rollup below) and
`SongItem` (albumId, trackNumber, year, lyrics, `lyricsStatus`,
`sentimentKeywords[]`, `sentimentSource`, explicit, `lengthMs`, `pointer`, and the
audio fields **`bpm`/`key`/`camelot`** = `null` until analyzed). Numeric fields
that support `between` (`year`, `lengthMs`, `trackNumber`, `bpm`, `trackCount`) are
stored as plain numbers; formatting happens at the edge (`lib/format.ts`).

**Audio model.** The audio stage produces per-album **`audioTracks[]`** (each an
`AudioTrack`: `trackNumber`, `startMs`/`endMs`/`durationMs`, `bpm`, `key`,
`camelot`, optional `keyStrength`). This segmentation is detected from the recording
and **independent of the metadata tracklist**, so `audioTracks.length` may differ
from `trackIds.length` by design. `importIndex.ts` derives an **album-level rollup**
at import time so the star map can group/sort without re-scanning every track:
`audioBpm` = median BPM (rounded), `audioCamelot` / `audioKey` = the most-common
value. Like song `bpm`/`key`, these are `null` (never `undefined`) when an album has
no audio, so "no audio yet" stays explicit. **`ArtSource`** (`{ type: 'cdn' |
'remote', url, cors? }`) backs the progressive cover-art sources — see *Cover art*.

The **index JSON** the indexer emits (contract in `src/types/index-json.ts`, JSON
Schema in `.claude/skills/analog-indexer/schema/index.schema.json`, loader rules in
`.claude/skills/analog-indexer/docs/LOADER_CONTRACT.md`) is imported by
`storage/importIndex.ts`. Ids are content-derived (`alb_*/sng_*`) so re-imports
upsert idempotently, and the **source id** is derived from `(type, sourceName)` so
re-importing the same source replaces it rather than duplicating.

## Storage (IndexedDB, `pocketdj` DB v1)

Stores: `sources`, `items` (indexes `by_source`, `by_source_type`, `by_album`,
`by_type`), `art`, `meta`. **All access goes through `repo.ts`** — components never
open the DB. Albums and songs share `items`, discriminated by `type`; the virtual
**"All"** source (`ALL_SOURCE_ID`) is simply "no source predicate". Bulk writes are
chunked (~500/txn) so a full import never does one txn per record.

**Cover art — progressive, offline-durable** (`artCache.ts`). An album's art is an
ordered, most-preferred-first list of **`coverArtSources`** (a **`cdn`** default —
our own CORS-friendly/S3-mirrored origin — plus a **`remote`** third-party backup),
falling back to the legacy single `coverArtUrl`. Resolution (`cacheArtSources`):
- Try every **cacheable** source first (same-origin / root-relative `/art/…` /
  known CORS-friendly host / `cors:true`): fetch → thumbnail to a 256px **webp blob**
  via `OffscreenCanvas` → store in `art` (status `ok`). Fully offline + survives
  restart. This is why art can migrate to the CDN incrementally without breaking
  albums that still only have a remote URL.
- If *no* source is cacheable (e.g. a Discogs CDN URL with no
  `Access-Control-Allow-Origin`, or offline at first load), keep the first source's
  URL (status `url`) and display it via `<img src>` directly — no doomed fetch.
- **Missing art** gets a deterministic gradient **placeholder** thumbnail (seeded by
  album id, with scattered "stars" to match the night-sky theme).

**`artKeyFor({ coverArtSources?, coverArtUrl?, id })`** derives the SAME cache key
the async paths produce, *without any network* — sources keyed by their ordered
`type:url` join, else `coverArtUrl`, else a placeholder keyed by `id`. The importer
assigns this at import time so the UI renders immediately and each thumbnail fetches
lazily, instead of blocking first paint on hydrating every cover. (Re-mirroring —
a new ordered source list — yields a fresh key, so the durable blob is re-cached.)

**Ref-counted display registry + progressive subscribe.** Rendering no longer uses
the old fixed-size LRU (which revoked in-use URLs and left most star-map covers
broken). Instead `acquireArtUrl`/`releaseArtUrl` keep **one shared blob URL per art
key, reference-counted** across every surface (browser grid, star-map stars, solar
sun); the URL is revoked only when the **last** consumer releases it, so rendering
~1,361 covers at once never breaks. Components go through the **`useArtUrl(key)`**
hook (`components/common/useArtUrl.ts`): it acquires the shared URL (taking exactly
one ref, released on unmount) and, if the thumbnail isn't cached yet, **subscribes**
(`subscribeArt`) — when a background warm pass stores that thumbnail (`notifyArt`),
the hook re-acquires and the cover **pops in**. Net effect: the UI is interactive at
once and fills in progressively. **`requestPersistentStorage()`** (called on boot)
asks the browser to keep these blobs from being evicted, so covers are durable
across app/phone restart (important on iOS).

**Portability**: `exportZip.ts` streams `manifest.json` + `sources.json` +
`items.json` + `art/*.webp` into one `.zip`; `importZip.ts` rehydrates with **zero
network** (art travels with the data) — the offline-on-a-fresh-device story. The
same file input also sniffs a raw `index.json` (zip magic-byte / extension check)
and hydrates art from URLs for it.

## Filter & sort engine

`fieldRegistry.ts` is the single source of truth (field → kind, applies-to,
operators, `numeric ⇒ between`-capable, sortable). `filterEngine.applyFilters`
AND-composes pure per-clause predicates (`eq`/`neq`/`in`/`between`; `string[]`
fields like `sentimentKeywords` use set-intersection for `in`; `boolean` uses
`eq`). `sortEngine` is a stable sort with nulls last. The Browser pipeline is
`getItems(scope) → applyFilters → sort → virtualize`, memoized on
`(items, filterHash, sortHash)`. Each `applyFilters` emits a `filter.apply`
transcript line carrying `in`/`out` counts (tests assert on it).

## Single-album view & edit modals

**`AlbumTrackTable.tsx`** (`/album/:albumId`) is the per-album work surface, reached
by tapping an album card (`ItemCard` → `navigate('/album/'+id)`). It shows the album
header (cover via `useArtUrl`, title/artist/`year · genre · N tracks`) over a track
table (one row per song — the same `bpm`/`key`/`camelot` row as song-browser mode,
tap → `SongDetailModal`), plus an **album audio-analysis** footer (`AudioTracksTable`,
read-only). Buttons: **◎ Solar** (→ `/map/:id`), **✎ Edit album info**
(`EditItemModal`), **✎ Edit audio analysis** (`AudioEditModal`), and **← Back**
(`navigate(-1)`). Back is **filter-preserving**: it pops history rather than routing
to a fresh `/browse`, and the filter/sort live in the **persisted** `useBrowserStore`,
so you return to exactly the list you came from.

**`EditItemModal.tsx`** edits an album or song in place (persists to IndexedDB):
- **Album**: Artist, Title, Year, **Genre** (a combo input suggesting the canonical
  category names yet accepting free text), **Cover URL** (paste a new cover to
  re-fetch), Country, File type.
- **Song**: Artist, Title, Track #, Year, Length (m:ss), Explicit, sentiment
  keywords, and the audio fields with **Key** and **Camelot** as **valid-value
  dropdowns** (`MUSICAL_KEYS` / `CAMELOT_KEYS`) that **stay in sync** — picking one
  fills the other via `keyToCamelot`/`camelotToKey`.
- **Delete track** (songs only) swaps the form for a mobile-friendly confirm —
  *"Delete '<name>' …"* with a safe **Nope** and a red **Delete** — so a destructive
  edit needs a deliberate second tap.

**`AudioEditModal.tsx`** edits an album's `audioTracks` — one row per detected
segment with Start/End (m:ss), BPM, and linked Key/Camelot dropdowns — staged
locally until **Save**. (`AudioTracksModal` is the same table read-only, opened by
clicking the solar-system sun.)

## Settings popout & force refresh

**`TopBar`**'s **⚙** gear opens **`SettingsModal.tsx`** (catalog counts + source
name + one action). **↻ Force refresh & re-pull catalog** runs
`dataActions.forceRefreshCatalog()`: it **unregisters the service worker**, **deletes
all `caches`**, **`clearAllStores()`** (wipes the IndexedDB catalog), then
`location.reload()`. With the SW gone the browser fetches the freshest app shell, and
`seedIfEmpty` re-pulls `current-index.json` into the now-empty DB. This is the fix
for "my phone still shows old data/UI after a deploy": the SW caches the shell and
auto-seed only runs on an empty DB, so a previously-loaded catalog otherwise sticks.
The seed fetch itself uses **`cache: 'reload'`** so even the seed JSON bypasses the
HTTP cache and is always the latest.

## Star map (two-tier)

The default view. Geometry lives in three **pure, renderer-agnostic** modules so a
future 3D/animated renderer can consume the same `{x, y, r}` data.

- **`constellationMap.ts` — `categorize(genre)`**. Real-world genre strings are
  messy and ~55% empty (Discogs compound CSV like `"Funk / Soul, Disco"`, sloppy
  casing, glued run-ons, occasional Wikipedia CSS leaks). So this is a **pure,
  ordered, substring/keyword matcher** (not a fixed lookup): it strips CSS-blob
  leaks, then picks **one** tier-1 **category** (≈14 + an `Other` catch-all) and
  **one** tier-2 **sub-genre**. Ordering matters: specific leaf genres (hip-hop,
  classical, blues, country, world, jazz, disco) are tried *before* low-signal
  parent tags (funk/soul/r&b/rock/pop) so the descriptor wins over the parent tag.
  Empty/unmappable → `{ Other, Unknown }`, so no album ever disappears.
- **`layout.ts` — `computeLayout(albums, { tier, focusCategory })`**.
  - **Tier 1** (default): one constellation per **category**. Album stars are
    laid out but **dimmed and non-clickable** — the constellation is the click
    target (drill-in).
  - **Tier 2** (focused on one category): one constellation per its **sub-genres**;
    album stars are **clickable** (→ solar system). Tier 2 is always focused — it's
    reached only by drilling into a category (click-discoverable; there's no global
    tier-2 view, no slider).
  - In both tiers: **vertical = year** (newer higher), **horizontal = seeded
    pseudo-random** (stable per album id → unique constellation shape),
    shelf/box-packed, with deterministic **X-only collision relaxation** (`relaxX`,
    preserving each star's year-encoding Y). The layout is cached in `meta` keyed
    by `albumSetHash + tier + focusCategory`.
- **`StarMapScene.tsx`** loads albums, derives **tier/focus from the URL query**
  (`?cat=<category>` → tier 2; deep-linkable, back/forward works), caches the
  layout, lazily resolves cover thumbnails, and renders a static SVG with
  lightweight **pan + wheel-zoom + pinch-zoom** (wheel is a native non-passive
  listener so `preventDefault` doesn't throw). `ConstellationField.tsx` draws the
  tier-1 hazy glowing hull/blob that is the drill-in click target.
- **`solarSystem.ts` / `SolarSystemView.tsx`** (`/map/:albumId`): cover = sun,
  songs = planets (orbit radius by track number, planet radius by length, seeded
  static angle). `SongDetailModal` shows a clicked song; **clicking the sun** opens
  `AudioTracksModal` (the album's audio segmentation); a **☰ Browser** button jumps
  to the album's single-album track table (`/album/:albumId`).

### Grouping modes: BPM / Key nebulae

The star map's **Genre / BPM / Key** toggle (`?group=` in the URL) changes what's
grouped. Genre stays the album-based two-tier map above. **BPM and Key are
song-based "nebula" modes**, owned by the pure `grouping.ts`:

- **`groupSongs(songs, groupBy, keyNotation)`** buckets *all songs* (not albums)
  into ordered **constellations**, each carrying the exact browser **filter** that
  selects its songs — so "tap a nebula" pre-filters the Browser table:
  - **BPM**: decade buckets `floor(bpm/10)*10` → labels like `120–130`, ascending;
    filter `{ field:'bpm', op:'between', min, max }`. Null/non-finite BPM → one
    **Unknown** constellation, last.
  - **Key + camelot**: group by `camelot` (e.g. `8A`), ordered by the Camelot wheel
    (`camelotRank`); filter `{ field:'camelot', op:'eq', value }`.
  - **Key + musical**: group by `key` (e.g. `A minor`), ordered by pitch then minor
    before major; filter `{ field:'key', op:'eq', value }`. Unparseable/missing key
    → an **Unknown** constellation, last, that carries **no** filter (there's no
    clean "missing" predicate, so it's read-only).
- **`layout.ts → computeNebulaLayout`** turns each constellation into a hazy
  **nebula** (`NebulaField.tsx` — soft glow + a small decorative star scatter that
  is *not* 1:1 with the song count). In **Key** mode each nebula is tinted by
  **`camelotColor`** (`lib/camelot.ts`); the Unknown nebula stays neutral.
- **`lib/camelot.ts`** is the pure Camelot-wheel helper shared by grouping, the
  nebula tint, and the editor dropdowns: `camelotRank` (wheel order; A=even/B=odd so
  a numeric compare sorts the wheel), `camelotColor` (12 hues × A-deeper/B-brighter
  lightness), `keyToCamelot`/`camelotToKey` (accepts sharp+flat input, emits
  canonical sharp), and the published valid-value lists `CAMELOT_KEYS` (24) /
  `MUSICAL_KEYS` (24) that back the dropdowns.

### Mobile constellation grid

On phones (`lib/useIsMobile.ts`, ≤680px) the pan/zoom SVG scatter is illegible, so
the **tier-1 genre map** and both **nebula modes** render `ConstellationGrid.tsx`
instead: a vertical-scrolling 2-column grid of **cards**, each a big title + count
with a mode-specific visual — **genre** cards show a mosaic of up to **16
randomly-sampled covers** (via `useArtUrl`/`Thumbnail`), **BPM** cards a metronome
glyph, **key** cards the Camelot color fill (neutral for Unknown). Tapping a card
runs its action (drill into the genre's sub-genres, or open the Browser pre-filtered
to the nebula's songs). Drilling into a genre still uses the SVG scatter (album
stars are sparse enough to tap).

## PWA / offline + auto-seed

`vite-plugin-pwa` (`generateSW`, `registerType: 'autoUpdate'`) precaches the **app
shell only** (`globPatterns` for js/css/html/svg/png/woff2, SPA `navigateFallback`).
Cover art and library data are **user data in IndexedDB** — never in the SW cache,
never runtime-cached. External fetches happen only at import/hydrate time.

On boot (`App.tsx` → `dataActions.seedIfEmpty`), if the DB has **no sources**, the
app fetches the bundled `public/current-index.json` and imports it as **"My Vinyl"**
(showing a "Loading your vinyl… N/total" progress hint). This is why the deployed
site shows the full catalog with **no console and no manual import** — important on
mobile. If the seed file is absent it renders empty rather than blocking. After one
import (seed, raw `index.json`, or any `.zip`) the app is fully offline-capable.

## The analog indexer (streaming, manifest-driven)

A separate tool under `.claude/skills/analog-indexer/` — **all local Node** (no
cloud key required, except the optional Claude workflows). It turns a text list of
`ArtistNameAlbumNameRaw.<ext>` filenames into the canonical `index.json`. Per vinyl
line it emits one **album** plus its **song** items, filling everything web-findable
and deferring `bpm`/`key`/timestamps (those need the audio file).

It's a chain of **decoupled sub-indexers**, and **the index doubles as the
manifest**: each album record carries a per-stage status, so any stage can be re-run
**selectively** (process only items where its stage isn't done) — resumability and
selective re-index are the same mechanism. Stages, in order:

1. **metadata** — `enrich-playwright.mjs`. Queried from *inside a real Chromium page
   context* (genuine browser fingerprint, assets route-blocked): **Discogs public
   API** (no token; structured tracklist with vinyl side positions → disc numbers,
   year, genres+styles, country, hi-res cover) as PRIMARY, **Wikipedia** (REST
   search → article infobox + `table.tracklist`) as fallback. Polite single-lane
   throttle (~2.6 s/call) + 429/403 backoff, per-album timeout, resumable album-by-
   album to `enriched.jsonl`. (Apple's iTunes Search API is the legacy path but
   rate-limits hard at ~20 req/min/IP, so Playwright/Discogs is the scale path.)
2. **backfill** for still-`unmatched` albums — two routes:
   - **PREFERRED:** parallel **Claude WebSearch** agents (a Workflow) that identify
     the real release + tracklist → `web.jsonl`. Captcha-free.
   - **fallback:** `enrich-google.mjs` — a *headed* Chrome/Safari that types queries
     into the search box like a person (Google → DuckDuckGo → Bing, optional Safari
     sweep), local model extracts the tracklist → `google.jsonl`. Captcha-prone;
     relentless and resumable; if the local model is unavailable an album is
     *deferred, not burned*.
   - Then **`synth-singles.mjs`** folds the leftover 12" **singles** (no album to
     match) into one-track `"<name> Single"` albums in `enriched.jsonl` so they
     still appear, and re-queues them through lyrics + sentiment.
3. **lyrics** — `enrich-lyrics.mjs` (Playwright). Per track: **Genius** (in-page
   `genius.com/api` search — the worker page must already be *on* genius.com, since
   the API is CORS-locked) → **AZLyrics** fallback. Validates the scrape (length +
   line breaks, not an error/interstitial page), trims to ~3000 chars, and
   **rejects oversized full-page-dump scrapes (>20k chars) as `notfound`**. In
   practice nearly all lyrics resolve via Genius (AZLyrics currently serves headless
   Chromium a bot interstitial, which the stage detects and backs off).
4. **sentiment** — **two interchangeable paths** (the skill supports both):
   - **local model** — `enrich-sentiment.mjs` against **LM Studio's**
     OpenAI-compatible API (default a small Gemma), with a per-call timeout and
     sane max-tokens. Good for **incremental** adds.
   - **Claude WORKFLOW** — `sentiment-claude` + `sentiment-todo.mjs` (snapshot the
     todo) + `sentiment-claude-merge.mjs` (fold compact per-track keyword results
     back into album records). ~100% coverage and far faster; used for the **full
     index**. `scripts/run-pipeline.sh` runs lyrics continuously and switches the
     sentiment stage between `local` and `claude` (`SENT_MODE`).

**Merge rules (`lib/manifest.mjs` `buildFromStages`).** The manifest is derived by
overlaying the stage files **in order** — `enriched` → `google` → `web` → `lyrics`
→ `sentiment` — keyed by `candidateIndex`. The key invariant: **metadata + recovery
stages (`enriched`/`google`/`web`) OWN the album-level fields** (status, artist,
name, year, genre, tracks), so a recovered (matched-with-tracks) record supersedes
the trackless "unmatched" pass-through. **lyrics + sentiment contribute ONLY track
data + their own stamp** — their carried-forward copy of the album fields may be
stale (written while the album was still unmatched), so they must never override a
recovery's metadata or wipe its tracks (they swap in `tracks` only when non-empty).
`pipeline.mjs merge` then assembles the index, stamping each album's per-stage
status onto it as `indexing`, and writes `index.json` + `coverage-report.json`
(+ `run-log.json`, the provenance/proof artifact).

**Final catalog:** **1,361 albums / ~12,867 songs**, **100% matched**, **100%
sentiment-tagged** (`public/current-index.json`, the bundled seed).

### Running it

```bash
# metadata scraper (background) -> enriched.jsonl
node .claude/skills/analog-indexer/lib/enrich-playwright.mjs index-out/parsed-full.json \
  --out-dir index-out/shards-pw --concurrency 3 --progress-file index-out/pw-progress.log

# fold metadata in, then chain lyrics + (local) sentiment over pending items
node .claude/skills/analog-indexer/lib/pipeline.mjs import-metadata index-out/shards-pw/enriched.jsonl
node .claude/skills/analog-indexer/lib/pipeline.mjs status                  # per-stage coverage
node .claude/skills/analog-indexer/lib/pipeline.mjs run --stages lyrics,sentiment

# backfill the still-unmatched (preferred: the Claude WebSearch workflow; fallback below),
# then synthesize singles, then merge from the streaming stage files:
SHARDS=3 scripts/run-backfill.sh                                            # headed-browser fallback
node .claude/skills/analog-indexer/lib/synth-singles.mjs --dir index-out/shards-pw
node .claude/skills/analog-indexer/lib/pipeline.mjs merge --dir index-out/shards-pw --out-dir index-out/full
```

Full how-to (every flag, the captcha notes, the legacy iTunes path) is in the
skill's `SKILL.md`. Pure helpers (`lib/{parser,normalize,itunes,merge,assemble,
batching,ids}.js`) are Node and unit-testable; `parser.test.mjs` runs via
`npm run indexer:parser-test` or under Vitest.

## Mock data

`scripts/generate-mock-index.ts` emits a schema-valid `index.json` at any scale with
deliberate **edge cases** (missing genre/year/country, unmatched albums with no
songs, Various-Artists, Raw-duplicate pairs, extreme years, empty sentiment). The
in-app **"Load demo data"** button loads `public/mock-index.json`. Regenerate:
`npm run gen:mock -- --albums 1366 --out public/mock-index.json`.

## Deploy (S3 + CloudFront)

`scripts/deploy.sh dev|prod` builds (`npm run build`, ensuring `mock-index.json`
exists), then syncs `dist/` to `s3://pocketdj-<env>-web-<acct>` in two cache tiers:
**hashed `assets/*` immutable** (1-year) and **`index.html` / `sw.js` /
`registerSW.js` / `manifest.webmanifest` no-cache** so the auto-updating service
worker always picks up a new deploy. CloudFront fronts each env for **HTTPS** (the
service worker requires it) and is **auto-invalidated** (`/*`) at the end so the new
shell + asset hashes propagate together. URLs:

- **dev:** https://djictbz9w796r.cloudfront.net (distribution `E123GKAO9JVETP`)
- **prod:** https://d2p4cubg6se03u.cloudfront.net (distribution `E1SP8M1SIF7Q8D`)

`SKIP_BUILD=1 scripts/deploy.sh dev` reuses an existing `dist/`. (Also wired as the
`publish-s3` skill.)

## Native app (iPhone · iPad · Mac)

`apple/` is a **fully native SwiftUI** client — **one universal target** (`PocketDJ`)
that runs on iPhone, iPad, and Mac (iOS 18 / macOS 15) and talks to the same
CloudFront / S3 / rip-server backends as the PWA. The Xcode project is **generated by
[XcodeGen](https://github.com/yonaskolb/XcodeGen)** from `apple/project.yml` — edit
Swift files on disk and regenerate (don't add files via the Xcode UI; they're dropped
on the next generate). The generated `PocketDJ.xcodeproj` is committed so it opens
without a generate step. Endpoints live in `PocketDJ/Support/Config.swift`.

Deep references: **`apple/README.md`** (layout + endpoints) and
**`apple/docs/build-and-test.md`** (the signing saga, test seams, the matrix). The
**apple-build / apple-test / apple-publish** skills are the quick how-tos.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # full Xcode, not CLT
which xcodegen || brew install xcodegen
cd apple && xcodegen generate                                     # (re)create PocketDJ.xcodeproj

# iOS Simulator — no signing (CI-style)
xcodebuild -project PocketDJ.xcodeproj -scheme PocketDJ \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
# macOS — build unsigned, then ad-hoc sign so Gatekeeper allows launch
xcodebuild -project PocketDJ.xcodeproj -scheme PocketDJ -destination 'platform=macOS' \
  -derivedDataPath build-mac CODE_SIGNING_ALLOWED=NO build
codesign --force --deep --sign - build-mac/Build/Products/Debug/PocketDJ.app
```

**Testing.** Unit (`Tests/Unit`, pure logic) + XCUITests (`Tests/UI`), both offline
against a bundled fixture (`PDJ_USE_FIXTURE=1`). The `PocketDJ` scheme runs both test
bundles; give each device its **own** `-derivedDataPath` (a shared one clobbers
`TEST_HOST`). The macOS UI suite must go through `apple/scripts/test-macos.sh`
(ad-hoc signs the runner — a plain `xcodebuild test` hangs/Gatekeeper-blocks it).

```bash
xcodebuild test -project PocketDJ.xcodeproj -scheme PocketDJ \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO
bash apple/scripts/test-macos.sh                                  # macOS unit + UI
```

**Signing.** `project.yml`: automatic signing, team **EC27UF79GL** (Levi Schoen) —
correct for Xcode-GUI builds, on-device runs, and App Store archives. From the CLI,
`codesign` can't reach the key headlessly, so scripted builds use
`CODE_SIGNING_ALLOWED=NO` (simulators) or ad-hoc signing (macOS). On-device install
for manual testing: `apple/scripts/deploy-iphone.sh`.

**TestFlight (apple-publish skill → `apple/scripts/testflight.sh`).** The
local-archive path: `xcodegen generate` → `xcodebuild archive` (Release, iOS,
cloud-signed via an App Store Connect API key whose role **must be Admin**) →
`-exportArchive destination=upload`. The build number defaults to a unix timestamp.
`ITSAppUsesNonExemptEncryption: false` (set in the base Info.plist) lands builds
**"Ready to Submit"** with no per-upload export-compliance prompt; the **Alphas**
internal group auto-receives every build.

```bash
cd apple
ASC_KEY_ID=… ASC_ISSUER_ID=… ./scripts/testflight.sh
```

**Mix + Stems (dev-relevant).** The **Mix** tab is a first-party **AVAudioEngine**
two-deck DJ engine (`PocketDJ/Mix/MixEngine.swift` — tempo / pitch / seek / effects /
crossfader / beat-match / auto-mix; no third-party audio SDK). **Stems** (Demucs
separation) surface as a SongDetail audition panel + Mix stem decks + collection
burn-stems. Both the Mix decks and stem playback read **local audio files**, so to
exercise them a Setlist must be **burned** to the on-device Burns folder first — the
simulator/fixture path can't stream-mix. Stem files themselves come from the rip
server's `/stemify` endpoints (next section). Background audio + background-URLSession
rips/burns also only fully verify on real hardware.

The **Now Playing** card carries a **Mix mini-panel** (`Playback/NowPlayingDSP.swift` +
`Views/NowPlayingMixPanel.swift`): for a mixable **local** track (and only when no full
Mix session is active) it **swaps the plain `AVPlayer` for the `AVAudioEngine` DSP graph
on first touch**, exposing stem/effects/tempo/pitch/gain for that one track and resetting
per track — so, like the Mix decks, it needs a **burned** local file to exercise.

## Backend services (rip server · stems)

Two host-local services (the user's M-series **iMac**) feed both clients. Neither is
part of the deployed site; they run on the iMac and are reached over the LAN /
**Tailscale** (`levis-imac.tail2e2bdf.ts.net`).

### Running the rip server

`scripts/rip-server.mjs` is a **dependency-free** `node:http` API (shells out to
`ffmpeg` + `aws`, profile `levi`) for **rip-on-demand + live streaming**: a client
asks it to rip a song/album that isn't yet in the public S3 rips cache. The **analog
fast path** transcodes the album's raw vinyl recording (under `POCKETDJ_ANALOG_BASE`)
to mp3 256k, uploads it to the **public rips bucket** `pocketdj-rips-011183829623`
(`/rips/<albumId>.mp3`), and registers every song in `rips/manifest.json` (each with
its `startMs` for later auto-seek). Apple Music capture is a real-time path
(`RIP_AGENT=1`, the **rip** skill via a headless agent).

```bash
POCKETDJ_ANALOG_BASE=~/Downloads RIP_TOKEN=secret node scripts/rip-server.mjs
curl localhost:8787/health        # RIP_PORT=8787; RIP_TOKEN is the bearer (empty = local dev)
```

It also hosts the **`/stemify`** endpoints (per-song / collection stem separation),
which need the stem runtime provisioned once (below), and the **Discover** search
proxy: **`GET /search?q=&entity=song|album`** (an iTunes Search proxy, so beta clients
need one base URL + token; `entity=album` returns album hits keyed by `appleMusicId` =
iTunes `collectionId`) plus **`GET /album-tracks?id=<collectionId>`** (expands an album
into its ordered, disc-major tracklist via the iTunes lookup API). Together these let
the app's **Browse ▸ Discover** album mode **＋ Add** an album — fanning out a per-track
`amrec_` rip through the same durable `/rip` queue — with **no Apple Music
subscription** (the MusicKit `albumTracks` path needs auth; the proxy is the fallback).

### Digital ("My Digital") ingest — analysis is cloud-only

`scripts/index-digital-files.mjs` ingests loose raw-audio files, but the iMac is now a
**staging node only**: it transcodes + uploads the mp3 and `POST /ingest-digital`s the
entry **without** BPM/key/beat-grid/waveform. `/ingest-digital` self-heals by
**offloading the analysis to the cloud workers** (SQS), which fold the result into
`rips/manifest.json` — so digital ingest **never touches Docker/librosa locally**. The
Mix decks read bpm/beat-grid straight from the manifest; to backfill the Browse **card**
bpm/key into the catalog index run **`scripts/fold-cloud-analysis.mjs`** (the digital
equivalent of the analog in-process cloud fold; digital-only + side-output by default,
`--apply`/`--upload` to ship).

### Stem runtime

`scripts/stems-index.sh` provisions **Demucs** (htdemucs v4 by default) idempotently —
run it once before `/stemify` can separate anything. One knob,
`POCKETDJ_DEMUCS_RUNTIME`:

- **`native`** (default) — a host **venv using Apple MPS** (`~/.pocketdj/.venv-stems`).
  The fast path on the M-series iMac.
- **`docker`** — the `pocketdj-stems` CPU image. Portable / CI fallback (minutes/song).

Either way the default weights are **pre-warmed** so the first real separation runs
offline (an uncached torch-hub download mid-run would break the durable-queue
guarantee). `POCKETDJ_DEMUCS_MODEL` overrides the model (`htdemucs` default;
`hdemucs_mmi` / `mdx_extra` are v3 fallbacks) — it must match `STEMS_MODEL` in
`scripts/lib/audio-stem.mjs`, the same value the rip server reads.

```bash
scripts/stems-index.sh                                       # native venv + MPS (default)
POCKETDJ_DEMUCS_RUNTIME=docker scripts/stems-index.sh        # CPU image fallback
POCKETDJ_DEMUCS_MODEL=hdemucs_mmi scripts/stems-index.sh     # v3 model
```

## Testing

**Unit (Vitest).** `npm test` runs `environment: node` tests over the pure modules
(`src/engine/*`, `src/lib/{format,prng,concurrency,camelot,camelotColor}`,
`src/starmap/*` incl. `grouping`, `src/storage/{importIndex,artKeyFor}`, and the
indexer's `lib/*.js` + `manifest.mjs`/`synth-singles.mjs` logic). Coverage includes
both `src/**` and the indexer lib. The Camelot wheel (`camelotColor`,
`keyToCamelot`/`camelotToKey` round-trips, `CAMELOT_KEYS`/`MUSICAL_KEYS`) and the
network-free `artKeyFor` key derivation are covered in
`src/lib/camelotColor.test.ts` and `src/storage/artKeyFor.test.ts`.

**E2E (Playwright + Chromium).** `tests/e2e/` (`browser.spec.ts`,
`importexport.spec.ts`, `starmap.spec.ts`). The project convention: **every feature
ships a proof artifact** — a captured `PDJ_API` **transcript** plus a **screenshot**
— written to `tests/e2e/proof/<feature>/`. `helpers.ts` boots the app on a clean DB,
loads the deterministic fixture (`tests/e2e/fixtures/test-index.json`) via the
`window.__pdj` debug handle, captures the transcript, and writes proofs.

```bash
npx playwright install chromium     # first time
npm run test:e2e                    # all specs (dev server auto-started/reused)
npx playwright test starmap.spec.ts # a single spec
npm run test:e2e:headed
```

### The `PDJ_API` transcript convention

The only backend is the client, so `lib/log.ts` emits one greppable single-line
JSON op per data operation —
`PDJ_API {"t":…,"op":"db.putItem","id":…,"type":"album"}`. Ops include
`db.open`, `db.bulkPutItems`, `db.putItem`, `db.putSource`, `db.getAllItems`,
`db.getItemsBySource`, `db.deleteSource`, `art.cache`, `art.generate`,
`import.index`, `import.zip`, `export.zip`, `filter.apply` (with `in`/`out` counts),
`starmap.layout`, `starmap.tier`. Tests assert on these as the audit log; when
debugging, `grep PDJ_API`. A dev-only **`window.__pdj`** handle exposes
`counts()`, `loadMock()`, `loadIndex(json)`, `exportZip()`, and `clear()` for
inspecting/driving state without UI scraping.

## Ops skills

- **PWA:** `.claude/skills/{build,test,debug,publish-s3,create-pr}/SKILL.md` and
  `.claude/skills/analog-indexer/SKILL.md` — build, test, debug, deploy, PR, indexing.
- **Native:** `.claude/skills/{apple-build,apple-test,apple-publish}/SKILL.md` —
  generate/build/sign, the per-device test matrix, and TestFlight distribution.
- **Audio:** the **rip** skill (`.claude/skills/rip/SKILL.md`, Apple-Music capture)
  plus the rip server (`scripts/rip-server.mjs`) and stem runtime
  (`scripts/stems-index.sh`) above.

## Roadmap

**Shipped since the first cut of this doc:** audio analysis (BPM/key/Camelot/
timestamps); playback; digital / Apple Music / S3 / streaming source types; the
two-deck **Mix** engine (tempo/pitch/seek/effects/crossfader/beat-match/auto-mix, in
the native app); **Stems** (Demucs separation); rip-on-demand + live streaming;
offline Burns; and the Pockets / Playlists / Setlists performance engine.

**Still open:** an animated & 3D star-map renderer (the geometry modules already emit
renderer-agnostic data for it); bringing the Mix engine to the PWA; and the native
Star Map / streaming-provider polish tracked in `apple/` and the memory notes.
