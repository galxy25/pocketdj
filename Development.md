# PocketDJ — Development

Offline-first PWA. **React + Vite + TypeScript**, data in **IndexedDB**, no backend.
The "API" is the client itself; every data op emits a console transcript line for
auditing and tests.

## Quick start

```bash
npm install
npm run dev            # Vite dev server @ http://localhost:5173
npm run typecheck      # tsc -b, fast type-only check
npm run build          # tsc -b && vite build -> dist/ (PWA)
npm run gen:mock       # generate public/mock-index.json (demo data at scale)
npm run test:e2e       # Playwright (Chromium) — see Testing
```

## Tech choices (and why)

| Concern | Choice | Why |
| --- | --- | --- |
| Build / PWA | Vite + `vite-plugin-pwa` (Workbox `generateSW`) | precache the shell only |
| UI | React + react-router-dom | routed views, deep-linkable solar systems |
| Storage | **`idb`** | tiny IndexedDB wrapper; data fits in RAM, queries are in-memory |
| Zip | **`fflate`** | streaming, memory-safe at 100MB+ of cover-art blobs |
| State | **`zustand`** (+`persist` for UI prefs only) | selector subscriptions; data stays in IndexedDB |
| Virtualization | **`@tanstack/react-virtual`** | smooth at ~15k songs / ~1.4k album cards |
| PRNG | hand-rolled `fnv1a` + `mulberry32` | deterministic star/placeholder layout, zero-dep |
| Tests | Playwright (Chromium) | the spec's required browser; console-transcript proof |

## Project layout

```
src/
  types/        model.ts (DataSource/AlbumItem/SongItem union), index-json.ts (import shape), filter.ts, starmap.ts
  storage/      db.ts (idb schema), repo.ts (ONLY db access + transcript logging),
                artCache.ts (cover blobs + placeholders), importIndex.ts, exportZip.ts, importZip.ts
  engine/       fieldRegistry.ts (filterable/sortable fields), filterEngine.ts (eq/neq/in/between), sortEngine.ts
  starmap/      prng.ts, layout.ts (constellations), solarSystem.ts (orbits)
  store/        useAppStore (source/type/view), useBrowserStore (filter/sort, persisted), useDataStore (item cache)
  components/   layout/ (AppShell, TopBar), browser/ (selector, FilterBuilder, ItemGrid, EditItemModal, …), starmap/, common/
  lib/          log.ts (PDJ_API transcript), format.ts, concurrency.ts, prng.ts, dataActions.ts, debug.ts (window.__pdj)
scripts/        generate-mock-index.ts
.claude/skills/analog-indexer/   the indexer (parser, enricher, sentiment workflow, schemas) — see its SKILL.md
tests/e2e/      Playwright specs + fixtures + proof/<feature>/ artifacts
```

## Data model

Discriminated union on `type` (`src/types/model.ts`). `AlbumItem` (artist, name,
cover, genre, year, country, `trackIds[]`, pointer, fileType) and `SongItem`
(albumId, trackNumber, year, lyrics, `sentimentKeywords[]`, explicit, **bpm/key =
null (deferred)**, `lengthMs`, pointer). Numeric fields that support `between`
(`year`, `lengthMs`, `trackNumber`, `bpm`) are stored as plain numbers; format only
at the edge (`lib/format.ts`).

The **index JSON** the indexer/mock emit (`src/types/index-json.ts`, JSON Schema in
`.claude/skills/analog-indexer/schema/index.schema.json`) is the contract; the loader
rules are in `.claude/skills/analog-indexer/docs/LOADER_CONTRACT.md`. Ids are
content-derived (`alb_*/sng_*`) so re-imports upsert idempotently.

## Storage (IndexedDB, `pocketdj` DB v1)

Stores: `sources`, `items` (indexes `by_source`, `by_source_type`, `by_album`,
`by_type`), `art` (cover thumbnail blobs), `meta`. **All access goes through
`repo.ts`** — components never open the DB. Albums + songs share `items`,
discriminated by `type`; the virtual **"All"** source is just "no source predicate".
Bulk writes are chunked (~500/txn). Cover art is downloaded once, thumbnailed to
webp via `OffscreenCanvas`, and stored as a blob; mock/missing art gets a
deterministic gradient placeholder. Rendering uses an objectURL LRU so 1,400 stars
don't pin every bitmap.

**Portability**: `exportZip.ts` streams `manifest.json` + `sources.json` +
`items.json` + `art/*.webp` into one zip; `importZip.ts` rehydrates with **zero
network** (art travels with the data) — that's the offline-on-a-fresh-device story.
Import also sniffs a raw `index.json` and hydrates art from URLs.

## Filter & sort engine

`fieldRegistry.ts` is the single source of truth (field → type, applies-to,
operators, `numeric` ⇒ `between`-capable). `filterEngine.applyFilters` AND-composes
pure per-clause predicates (`eq/neq/in/between`; `string[]` `in` = set-intersection;
`boolean` = `eq`). `sortEngine` is a stable sort, nulls last. The browser pipeline is
`getItems(scope) → applyFilters → sort → virtualize`, memoized on
`(scope, filterHash, sortHash)`.

## Star map

`starmap/layout.ts` (pure, renderer-agnostic) groups albums by genre into
constellations, shelf-packs the boxes, maps **year → Y**, **seeded-random → X**
(seeded by album id via `prng.ts`, so positions are stable), and relaxes collisions
on X only. The layout is cached in `meta` keyed by an album-set hash. `StarMapScene`
renders it as static, pannable/zoomable SVG (`<image>` stars, native click
hit-testing). Clicking a star routes to `/map/:albumId`; `SolarSystemView` +
`solarSystem.ts` place songs as planets (orbit by track #, size by length, static
seeded angle). The geometry is renderer-agnostic so a future 3D/animated renderer
can consume the same data.

## PWA / offline

`vite-plugin-pwa` precaches the **app shell only**. Cover art and library data live
in IndexedDB (user data), never in the SW cache. External fetches happen only at
import time. After one online import — or any `.zip` import — the app is fully
offline.

## The analog indexer

A separate tool under `.claude/skills/analog-indexer/`. Pipeline: **parse** vinyl
filenames (Node) → **enrich** concurrently in Node (iTunes match + tracklist,
optional MusicBrainz country, capped lyrics.ovh) → **Haiku sentiment** (a small
Workflow) → **merge** to `index-out/index.json` + coverage/audit reports. The
deterministic fetching runs in Node (fast); only the fuzzy Wikipedia fallback and
sentiment use a model. Full how-to in that skill's `SKILL.md`.

## Mock data

`scripts/generate-mock-index.ts` emits a schema-valid `index.json` at any scale with
deliberate **edge cases** (missing genre/year/country, unmatched albums with no
songs, Various-Artists, Raw-duplicate pairs, extreme years, empty sentiment). Use it
to exercise the browser/filters/star-map at full scale without the real indexer:
`npm run gen:mock -- --albums 1366 --out public/mock-index.json`.

## Testing & proof-of-verification

Playwright + Chromium (`tests/e2e/`). The project convention: **every feature ships a
proof artifact** — a captured `PDJ_API` console **transcript** + a **screenshot** —
written to `tests/e2e/proof/<feature>/`. Helpers in `tests/e2e/helpers.ts` load the
deterministic fixture (`tests/e2e/fixtures/test-index.json`), capture the transcript,
and write proofs.

```bash
npx playwright install chromium   # first time
npm run test:e2e                  # all specs (dev server auto-started/reused)
npx playwright test browser.spec.ts:18   # a single test
npm run test:e2e:headed
```

### The `PDJ_API` transcript convention

The only backend is the client, so `lib/log.ts` emits one greppable JSON line per
data op — `PDJ_API {"t":…,"op":"db.putItem","id":…}`. Ops include `db.bulkPutItems`,
`db.putItem`, `import.index`, `import.zip`, `export.zip`, `art.cache`,
`filter.apply` (with `in`/`out` counts), `starmap.layout`. Tests assert on these as
the audit log; when debugging, `grep PDJ_API`. A dev-only `window.__pdj` handle
exposes `counts()`, `loadMock()`, `loadIndex(json)`, `exportZip()`, `clear()` for
inspecting/driving state without UI scraping.

## Ops skills

See `.claude/skills/{build,test,debug,publish-s3}/SKILL.md` for the build, test,
debug, and S3-deploy playbooks.

## Roadmap (next iterations)

Playback; digital / S3 / Apple Music sources; the 2-channel mixer fade UI; audio
analysis to fill BPM / key / timestamps; animated & 3D star map.
