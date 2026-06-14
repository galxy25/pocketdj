# PocketDJ — Development

Offline-first PWA. **React 18 + Vite + TypeScript**, data in **IndexedDB**, no
backend. The "API" is the client itself; every data op emits a console transcript
line for auditing and tests. The companion **analog indexer** (a Claude skill of
local Node scripts) produces the `index.json` the app loads.

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
  types/        model.ts (DataSource/AlbumItem/SongItem union), index-json.ts (import shape),
                filter.ts, starmap.ts (Star/Constellation/Planet/SolarSystem + Tier)
  storage/      db.ts (idb schema), repo.ts (ONLY db access + transcript logging),
                artCache.ts (cover blobs / URL display / placeholders + objectURL LRU),
                importIndex.ts, exportZip.ts, importZip.ts
  engine/       fieldRegistry.ts (filterable/sortable fields), filterEngine.ts (eq/neq/in/between), sortEngine.ts
  starmap/      constellationMap.ts (genre -> {category, subgenre}), layout.ts (two-tier geometry),
                solarSystem.ts (orbits)   — all pure, renderer-agnostic
  store/        useAppStore (source/type/view), useBrowserStore (filter/sort, persisted), useDataStore (item cache)
  components/   layout/ (AppShell, TopBar), browser/ (selector, FilterBuilder, ItemGrid, EditItemModal,
                PlugInIndicator, ImportExportBar…), starmap/ (StarMapScene, ConstellationField,
                SolarSystemView, SongDetailModal), common/
  lib/          log.ts (PDJ_API transcript), dataActions.ts (seed/import/export), debug.ts (window.__pdj),
                format.ts, prng.ts, concurrency.ts
scripts/        generate-mock-index.ts, deploy.sh (S3+CloudFront), run-pipeline.sh / run-backfill.sh (indexer)
.claude/skills/analog-indexer/   the indexer (lib/, workflow/, schema/, docs/, SKILL.md)
tests/e2e/      Playwright specs + fixtures + proof/<feature>/ artifacts
```

## Data model

Discriminated union on `type` (`src/types/model.ts`). `AlbumItem` (artist, name,
`coverArtKey`/`coverArtUrl`, genre, year, country, `trackIds[]`, `pointer`,
`fileType`, `enrichment`) and `SongItem` (albumId, trackNumber, year, lyrics,
`lyricsStatus`, `sentimentKeywords[]`, `sentimentSource`, explicit, `lengthMs`,
`pointer`, and **`bpm`/`key` = `null`** — deferred until audio analysis). Numeric
fields that support `between` (`year`, `lengthMs`, `trackNumber`, `bpm`,
`trackCount`) are stored as plain numbers; formatting happens at the edge
(`lib/format.ts`).

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

**Cover art** (`artCache.ts`) is handled two ways, decided per host:
- **CORS-friendly hosts** (Apple's `mzstatic.com`) are fetched, thumbnailed to a
  256px **webp blob** via `OffscreenCanvas`, and stored in `art` (status `ok`) —
  fully offline.
- **CORS-blocked CDNs** (Discogs' `i.discogs.com` sends no
  `Access-Control-Allow-Origin`) can't be fetched into a blob, but the browser can
  still *display* them. We store the URL with status `url` and render via
  `<image src=url>` directly (no doomed fetch, no console errors).
- **Missing art** gets a deterministic gradient **placeholder** thumbnail (seeded
  by album id, with scattered "stars" to match the night-sky theme).

Rendering resolves art through an **objectURL LRU** (cap ~400 live) so ~1,400 stars
don't each pin a bitmap; blob URLs are revoked on eviction, `url`-status records
return the remote URL as-is.

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
  static angle). `SongDetailModal` shows a clicked song.

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

## Testing

**Unit (Vitest).** `npm test` runs `environment: node` tests over the pure modules
(`src/engine/*`, `src/lib/{format,prng,concurrency}`, `src/starmap/*`, and the
indexer's `lib/*.js` + `manifest.mjs`/`synth-singles.mjs` logic). Coverage includes
both `src/**` and the indexer lib.

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

See `.claude/skills/{build,test,debug,publish-s3,create-pr}/SKILL.md` and
`.claude/skills/analog-indexer/SKILL.md` for the build, test, debug, deploy, PR, and
indexing playbooks.

## Roadmap

Playback; digital / S3 / streaming source types; the 2-channel mixer fade UI; audio
analysis to fill `bpm`/`key`/timestamps; an animated & 3D star-map renderer (the
geometry modules already emit renderer-agnostic data for it).
