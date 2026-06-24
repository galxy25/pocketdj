# PocketDJ — Architecture Book

This is the **inside-out, systems-engineering** view of PocketDJ — the complement to
[`STORYBOOK.md`](./STORYBOOK.md), which tells the **outside-in, customer/product**
story screen-by-screen. Where the storybook asks *"what does the DJ see and do?"*,
this book asks *"what are the moving parts, who owns what, and how does a byte get from
a vinyl rip on the iMac to a planet orbiting an album on a phone?"*

This top-level document is the **map**: it frames the product goal, shows how the
architectural pillars fit together to achieve it, and links to a **chapter document
per pillar** that holds the full context (entities, data flows, schemas, diagrams,
worked examples). Read this page, then dive into whichever chapter you need.

---

## The goal — what the whole system is for

> **PocketDJ — Portable, Personal, Musical Performance Playlists Producer:** let
> anyone, anywhere, **instantly create, play, and mix playlists from diverse musical
> sources.**

Unpack that and you get the design pressures the architecture answers:

- **Portable / anywhere** → offline-first, no server the user runs; everything the
  client touches is a static, public, cacheable artifact. → **Ch. 7**
- **Personal** → *your* crate — digitized vinyl, your Apple Music library — enriched
  and owned on-device, editable in place. → **Ch. 2, 3, 7**
- **Diverse musical sources** → multiple ingest pipelines normalize into **one
  catalog shape** with stable, collision-free ids — and, on the native app,
  **streaming-account sources** (Apple Music · Spotify · YouTube) and a **ShazamKit**
  recognizer beside the file catalogs. → **Ch. 2, 3, 7**
- **Performance Playlists Producer** → compose the shape of a night (pockets →
  playlists → setlists) and **realize** it into a concrete, ordered set. → **Ch. 4**
- **Play & mix** → make the metadata catalog actually audible from a phone
  (rip-on-demand, live streaming) and find the right record fast (search). → **Ch. 5, 6**

And the one sentence that captures the whole shape:

> **One iMac is the entire backend toolchain (ingest, enrichment, rip server,
> deployer); AWS S3 + CloudFront is a dumb, public-read content host; every client —
> the web PWA and the native SwiftUI apps — is a thin, offline-first consumer of the
> same static documents and the same rip API. There is no application server. The
> "API" is mostly files.**

---

## How the pillars fit together

```
   "diverse sources"        "one catalog"        "produce a performance"
  ┌──────────────────┐   ┌────────────────┐   ┌────────────────────────┐
  │ Ch.2 INGEST &    │──▶│ Ch.3 CATALOG & │──▶│ Ch.4 PERFORMANCE       │
  │ ENRICHMENT       │   │ DATA MODEL     │   │ ENGINE  (+AI seam ↗)   │
  │ vinyl·AppleMusic │   │ index JSON ·   │   │ pockets→playlists→     │
  │ ·audio·art       │   │ model·collections   │ setlists · realize()   │
  └──────────────────┘   └───────┬────────┘   └───────────┬────────────┘
                                 │                         │ setlist (Song IDs)
        ┌────────────────────────┼─────────────────────────┘
        ▼                        ▼                          ▼
  ┌────────────────┐   ┌──────────────────┐      ┌────────────────────────┐
  │ Ch.6 SEARCH &  │   │ Ch.5 PLAYBACK &  │      │ Ch.7 DISTRIBUTION &    │
  │ DISCOVERY      │   │ RIP-ON-DEMAND    │      │ CLIENTS                │
  │ aoss · starmap │   │ rip server·S3 cache│    │ S3/CloudFront·PWA+     │
  │ online/offline │   │ ·live HLS        │      │ native·edits round-trip│
  └────────────────┘   └──────────────────┘      └────────────────────────┘

         everything stands on ── Ch.1 FOUNDATIONS (entities · files-as-API · ids)
```

**Reading the map.** Across the top is the **production-to-performance spine**:
**Ch. 2** ingests diverse sources (vinyl, Apple Music, audio analysis, art) into the
**one catalog shape** of **Ch. 3**, which the **Ch. 4** performance engine turns into
realized setlists (and is where **AI auto-mixing/auto-building lands next** — the ↗
seam). The bottom row is how that catalog and those setlists reach the user:
**Ch. 6** makes it findable (search + the spatial star map), **Ch. 5** makes it
audible anywhere (rip-on-demand into a public S3 cache, with live HLS), and **Ch. 7**
distributes the artifacts to thin clients and closes the **edits round-trip** back to
the catalog. Everything rests on **Ch. 1 Foundations** — the entities, the
"files-as-API" principle, and the content-derived ids that make the whole
server-less coordination work.

---

## Table of contents

| # | Chapter | Pillar of the goal | What's inside |
|---|---|---|---|
| 1 | [**Foundations**](./architecture/01-foundations.md) | the whole | System entities, ownership table, the files-as-API spine, content-derived ids. **Start here.** |
| 2 | [**Ingest & Enrichment**](./architecture/02-ingest-and-enrichment.md) | *diverse sources* | Filesystem (vinyl `*Raw`), `Library.xml`, AppleScript/Shortcuts capture, the 5-stage analog indexer, Apple Music indexer, audio analysis + art mirroring. |
| 3 | [**Catalog & Data Model**](./architecture/03-catalog-and-data-model.md) | *personal catalog* | Index JSON schema (incl. the `appleMusicId` **catalog-id stage** and the **cloud re-index** that folds Apple Music length/bpm/key in with cloud precedence via **tight `am-match`**), internal model, collections — the one shape everything speaks. Reference chapter. |
| 4 | [**Performance Engine**](./architecture/04-performance-engine.md) | *Playlists Producer* | Pockets → playlists → setlists, the `realize()` engine, iTunes mirroring, **and the deferred AI auto-mixing seam**. |
| 5 | [**Playback & Rip-on-Demand**](./architecture/05-playback-and-rip-on-demand.md) | *play & mix* | The rip server API (incl. batch `POST /rip-collection`, the `POST /rip-cancel` **stop + worker-kill**, the `rippedAt` manifest stamp), job state machine, live HLS, the public rips cache, mini-player + setlist playback, the native inline player (`PlayerEngine`/`PlayerClock`/TimelineView), the stream-first → rip-last provider chain (`PlaybackCoordinator`) **with stream-through-rip**, the offline Collection Rip/Burn store (`BurnStore`, **+ user-browsable burnt-music folder**), the `SetlistPlayer` burnt-or-stream sequencer, **the queue self-heal (per-job watchdog + transient backoff retry), the analog source config (`POCKETDJ_ANALOG_BASE`), the persistent collection-RIP Stop/progress poll, and native BACKGROUND PROCESSING (`TransferCoordinator` background `URLSession` + `pocketdj-transfers.json` + BGTasks + background audio).** |
| 6 | [**Search & Discovery**](./architecture/06-search-and-discovery.md) | *instantly find* | OpenSearch Serverless (aoss), the SigV4 + CloudFront-proxy trick, online/offline modes, **online pagination (`from/size` + `track_total_hits`) + server-side sort + the `genreCategory` field**, **the native Browse genre + collection-membership filters**, the star map. |
| 7 | [**Distribution, Clients & Edits**](./architecture/07-distribution-and-clients.md) | *portable, anywhere* | S3/CloudFront (public-read), the PWA + native clients, the deploy loop, the edits round-trip, the native app's streaming-account providers + ShazamKit recognizer (bundle `com.levi.pocketdj`), **and the `backfill-rip` skill for the catalog-id-crawl misses (`apple-music-catalog-misses.csv`).** |

---

## What's current vs. what's coming

The architecture is built so the next pillars slot in **without breaking the data
contract**. Honest status:

- **Built today:** all of ingest/enrichment, the catalog, the manual performance
  engine (`realize()` with seeded sampling + harmonic autofill), rip-on-demand with
  live HLS (now including the **native inline player** — `PlayerEngine`/`PlayerClock`/
  TimelineView — on browser *and* album rows, Ch. 5 §7), online search, multi-client
  distribution, and the native edits overlay (export/import).
- **New current-state — native streaming sources + ShazamKit recognition.** The
  native app adds **streaming-account sources** (Apple Music · Spotify · YouTube) beside
  the URL catalogs, plus the **"?♪?" ShazamKit recognizer** that maps the song in the
  room back to the crate (Ch. 7 §5). All of it is **additive and ships inert** behind
  `#if canImport` + feature flags. **Live vs scaffolded:** **Apple Music** is wired on
  (`PocketDJAppleMusicEnabled = YES`; system MusicKit consent, in-process playback —
  needs the App-ID MusicKit App Service — no entitlement — to run on device) and
  **ShazamKit** uses the public catalog (no entitlement, no App Service; just the
  framework + mic string); **Spotify** and **YouTube** are **scaffolded — pending an
  SDK + credentials** a developer drops in per
  [`docs/streaming-integration.md`](./streaming-integration.md). Bundle id is now
  **`com.levi.pocketdj`**. **Apple Music (Local) songs now actually *stream*** rather
  than always ripping: an out-of-band catalog-id resolver mints an `appleMusicId` onto
  each song (Ch. 3 §1.1), and the native `PlaybackCoordinator` tries that verified
  Apple Music stream **first**, degrading to rip-on-demand only on a miss (Ch. 5 §8).
  **That crawl has now completed — 76,134 / 92,865 songs resolved → stream; the 16,730
  misses fall back to ripping and are listed in `apple-music-catalog-misses.csv`, which the
  `backfill-rip` skill local-rips through `/rip-collection` (Ch. 7 §4).**
- **New current-state — stream-through-rip + offline Collection Rip/Burn.** When an
  Apple Music stream wins a play, the native app fires **one fire-and-forget rip** so the
  track is silently captured to the public S3 cache for later (zero playback latency,
  idempotent, never blocks; Ch. 5 §8). Playlist / pocket / setlist / source detail views
  gain **Rip collection** (batch `POST /rip-collection` → the durable queue → S3) and
  **Burn collection** (a new `@Observable` `BurnStore` serial download queue that pulls
  *already-ripped* songs to an on-device offline store + a mixer-readable `.txt` sidecar;
  Ch. 5 §9). Each manifest entry now stamps **`rippedAt`** so a burn re-downloads when the
  source rip is newer. The offline player + live-mixer that consume the burn store are
  still **deferred** — only the storage layout + seams ship.
- **New current-state — cloud rips, Stop, Setlist Play, burnt-music folder, richer
  Browse + paged search.** A handful of features round out playback/discovery: a
  **"Rip from cloud source"** setting captures an *analog* song from the iMac's Apple Music
  library when it **exactly** matches (tight `am-match`, Ch. 3 §1.3), else falls back to the
  vinyl rip — and a durable **cloud re-index** folds Apple Music length + cloud bpm/key/camelot
  into `current-index.json` with cloud precedence (Ch. 3 §1.2). A **`POST /rip-cancel`**
  endpoint backs a collection **Stop** that cancels an in-flight rip (dequeue + kill the
  capture worker) or burn (keeps finished files; Ch. 5 §2.1, §9). Burns can save to a
  **user-browsable folder** (security-scoped bookmark; Ch. 5 §9). A **Setlist Play** button
  runs a set in order via the **`SetlistPlayer`** sequencer (burnt-local-file else stream,
  auto-advance; Ch. 5 §10). Online search **pages** (`from/size` + `track_total_hits`,
  accumulating, real total) and applies the Browser **sort server-side** (Ch. 6 §4.1), and
  the native **Browse** gains **genre** (tier-1-category, multi-select any-of / none-of) +
  **collection-membership** filters and a **per-clause remove** (Ch. 6 §6).
- **New current-state — rip-server self-heal + analog source config + persistent
  collection-RIP Stop.** The rip server's concurrency-1 queue gains a **self-heal** layer
  (Ch. 5 §3.1): a **duration-aware per-job watchdog** (digital = `length×1.5+90s` clamped
  90s–30min; analog ffmpeg = fixed 12min) group-kills a hung capture so one stuck job can't
  freeze the queue, and a **capped exponential-backoff retry** (`[30s,2m,8m,8m]`,
  maxAttempts 5, `attempt` persisted in the durable queue record) re-runs **transient**
  failures (missing analog drive/file, aws/network, watchdog timeout) while leaving
  **permanent** ones (unknown song / no analog ref) + cancels alone — so a remounted drive
  self-heals. The analog path now reads `${POCKETDJ_ANALOG_BASE}/<originalFilename>`, set to
  **`/Volumes/RipBurnMix`** in the launchd plist (needs removable-volume TCC for `node`;
  Ch. 5 §3.2, Ch. 7 §6). The native collection **Stop** + a live **"X of N ripped"**
  progress now stay visible for a whole server-side RIP via a **manifest poll**
  (`CollectionRipBurnController`, Ch. 5 §9.1) instead of vanishing after the ~1-2s enqueue.
- **New current-state — native BACKGROUND PROCESSING (rip-in · burning · downloading ·
  setlist playback continue while suspended/locked).** A new
  **`TransferCoordinator`** owns one background `URLSession`
  (`com.levi.pocketdj.transfers`); Burn/download run as **download tasks** that survive
  suspension + resume + finish after a **cold background relaunch**, with per-item state
  persisted atomically to **`pocketdj-transfers.json`** (the sidecar text + security-scoped
  burn-folder bookmark are captured at enqueue so the **`@MainActor`-free** delegate
  finalizes files with zero main-actor access). A new **`AppDelegate`**
  (`@UIApplicationDelegateAdaptor` iOS / `@NSApplicationDelegateAdaptor` macOS) bridges the
  background-URLSession completion handler + registers/submits a **`BGProcessingTask`**
  (burn-drain) and **`BGAppRefreshTask`** (rip-reconcile); **background audio** completes via
  `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` next/previous driving `SetlistPlayer`
  (auto-advance while locked). Capability flips: `UIBackgroundModes` += `processing,fetch`,
  `BGTaskSchedulerPermittedIdentifiers` added (Ch. 5 §11, Ch. 7 §5.3).
- **Coming — AI-assisted auto-mixing & auto-building playlists.** The seams already
  exist (no migration needed to light them up): `SetlistTrack.mixSuggestions` +
  the `MixSuggestion` shape, the reserved `PocketKind:'performance'`, and the
  `realize()` sampling/autofill boundary an AI sequencer would extend. See
  [Ch. 4 §4](./architecture/04-performance-engine.md#4-the-ai-seam--auto-mixing--auto-building-coming).
- **Deferred — the iMac edits-merge tool.** The native edits round-trip is built on
  the client side and the schema is designed for it, but the iMac-side merge tool that
  folds exported edits back into `current-index.json` **does not exist yet**. See
  [Ch. 7 §3](./architecture/07-distribution-and-clients.md#3-the-edits-database--the-round-trip).

---

## Appendix — inconsistencies & notes for maintainers

Things found while writing that don't fully line up, gathered here so they're not lost:

1. **The iMac edits-merge tool does not exist yet.** `EditSchema.swift` /
   `EditsStore.swift` cite "the iMac merge tool that folds edits back into the index,"
   but there is no such script in `scripts/` or the skills. Client half built; server
   half deferred. (Ch. 7 §3)
2. **Web vs native edits are different mechanisms.** Web mutates IndexedDB in place (no
   portable doc, no round-trip); only native keeps the versioned `EditsDocument`. The
   "edits database" is a native-only entity today. (Ch. 7 §3)
3. **aoss collection vs index name.** Collection is `pocketdj-search` (id
   `zxvkpgoc5ivtrbqp37s5`); the index inside it is `pocketdj`. Client code and the
   CloudFront proxy path both use `pocketdj` (the index), which must match. (Ch. 6)
4. **`coverArtSources.url` extension drift.** `mirror-art.sh` / `index-json.ts` show
   `/art/<id>.jpg`; the Swift `Config.artURL` docstring shows `.webp`. The mirror
   writes `.jpg` (`image/jpeg`); the `.webp` comment appears stale. (Ch. 2, 7)
5. **`/stream/<id>.mp3` (progressive) vs `/hls/<id>/…` (HLS).** Both implemented, but
   the client detects live via `url.includes('/hls/')` and the job's `streamUrl` is the
   HLS playlist; iOS needs HLS, so `/stream` is a legacy/secondary route. (Ch. 5)
6. **`TrackSource:'autofill'` in data = `↔ bridge` in the UI** — code name and product
   label differ (a grep for "bridge" in the data layer comes up empty). (Ch. 4, 5)
7. **`POST /analysis` overloads "key".** The body uses `musicalKey` for the musical key
   but `key` for the S3 object key when creating a fresh entry — same word, two
   meanings in one payload. Not a bug, but a footgun. (Ch. 5)
8. **Streaming providers are scaffolded to different depths.** All three compile and
   show in Settings, but only **Apple Music** (flag on) + **ShazamKit** (public catalog)
   are wired live; **Spotify** + **YouTube** are stubs until a developer adds the SDK +
   credentials. The Settings row reads "Not available" for an unconfigured one, so the
   UI is honest — but "shipped" ≠ "usable" per provider. (Ch. 7 §5)
9. **`PlayerClock` is intentionally NOT `@Observable`.** The inline player's ~4×/s
   position lives on a plain `PlayerClock` sampled by a `TimelineView`, *by design* —
   making it `@Observable` would re-invalidate the panel and drop clicks on its control
   buttons (the documented "dead slide-out buttons" bug). A maintainer "fixing" the
   missing `@Observable` would regress it. (Ch. 5 §7)
10. **Bundle id moved to `com.levi.pocketdj`** (was `net.pocketdj.app`). A few external
    references (Developer-portal App ID, Spotify/YouTube OAuth redirect schemes
    `com.levi.pocketdj.spotify` / `.youtube`) must match this exactly; the `net.pocketdj.*`
    name is fully retired in `project.yml`. (Ch. 7 §5)
11. **`appleMusicId` is a *candidate*, not a verified catalog id.** It's an iTunes
    Search `trackId` — *empirically* the same value MusicKit plays by, but the equality
    is an undocumented assumption (regions/versions can drift, tracks get removed). The
    client must verify it with a real `MusicCatalogResourceRequest` and degrade to
    ripping on a miss; a maintainer who "optimizes" by playing `appleMusicId` *without*
    the `fetchRow` verification would silently regress to wrong/failed tracks.
    (Ch. 3 §1.1, Ch. 5 §8)
12. **Three names for the cloud-rip flag, on purpose.** Client/persisted `ripFromCloud`,
    the request-body field `"ripFromCloud"` (sent only when true), and the server job's
    `preferCloud` (the **RESOLVED** post-probe boolean) are deliberately distinct. The
    server persists `preferCloud` (not the raw request flag) and **never re-probes on
    resume**, so a track later deleted from the library can't flip the `resourceKey`
    between persist and resume. (Ch. 3 §1.2, design-rip-from-cloud.md)
13. **The cloud re-index writes a SIDE output, never the live catalog.**
    `scripts/reindex-cloud-analysis.mjs` writes `index-out/reindex/current-index.json` +
    a report and **never** mutates `public/current-index.json` or deploys; the owner
    reviews + applies by hand. A maintainer expecting it to publish would be surprised.
    (Ch. 3 §1.2)
14. **`am-match` deliberately trades coverage for fidelity.** Tight matching means analog
    songs that exist in Apple Music under a slightly different version label (a loose
    match) **silently rip from vinyl / keep the analog value** instead of cloud — by
    design (vinyl is always the correct personal cut), but it "misses" some cloud-eligible
    songs. (Ch. 3 §1.3)
15. **`/rip-cancel` refuses the kill mid-`uploading` and never Tier-2-falls-back.** A
    cancel landing while a job is uploading lets the idempotent `aws s3 cp` + `saveManifest`
    finish; a cancel mid-capture on an analog cloud rip does **not** fall back to vinyl
    (cancel means stop, not "try the other path"). A maintainer "simplifying" the cancel
    path could corrupt the manifest or resurrect a canceled rip as a vinyl rip. (Ch. 5 §2.1)
16. **Online pagination tops out at the 10k `from+size` window.** `hasMore` is false once
    the accumulator reaches the exact `total` *or* `SearchService.maxResultWindow` (10,000)
    — aoss's `index.max_result_window`. A query with >10k matches can't be paged to the end
    by offset; deep pagination would need `search_after`. (Ch. 6 §4.1)
17. **Online genre filter/sort depends on the `genreCategory` keyword existing in the
    index.** `FilterQuery`/`sortBody` map `genre → genreCategory`; if a stale index built
    before `scripts/es-index.mjs` added that field is live, online genre clauses silently
    match nothing. Re-run the `es-search-index` skill after upgrading. (Ch. 6 §2, §4.1, §6)
18. **The background download delegate MUST stay `@MainActor`-free.** `TransferCoordinator`'s
    `URLSessionDownloadDelegate` runs on a background queue and during cold relaunches when
    `BurnStore` may not exist — so it captures the sidecar text + the security-scoped
    burn-folder bookmark `Data` onto the `TransferRecord` at enqueue time and resolves the
    destination from *that*, never a `@MainActor` closure. A maintainer who "simplifies" by
    reading `SettingsStore`/the catalog inside the delegate reintroduces the
    `MainActor.assumeIsolated`-off-the-main-thread trap (the documented BLOCKER). (Ch. 5 §11.1)
19. **`isTransient` retries by default (allow-list of permanents).** The rip-server self-heal
    treats *everything except* `unknown songId` / `no analog file reference` / `canceled` as
    transient → retryable. A new genuinely-permanent failure mode would be retried 5× with
    backoff unless it's added to the permanent set — a footgun, not a bug. (Ch. 5 §3.1)
20. **The collection-RIP progress poll ends the *indicator*, not the rip.** Its
    `ripPollMaxTicks` (~2h) safety cap stops the poll to avoid a leaked Task; the server-side
    rip may still be running, and a manual Refresh reconciles. A maintainer treating the cap
    as "rip done/failed" would be wrong. (Ch. 5 §9.1)
21. **`UIBackgroundModes` + BGTask identifiers must agree across three places.** The two
    BGTask ids (`com.levi.pocketdj.burn-drain` / `.rip-reconcile`) are hard-coded in
    `TransferCoordinator`, declared in `BGTaskSchedulerPermittedIdentifiers`, and registered
    in `AppDelegate`; iOS refuses to register/submit an id missing from the plist. Changing
    one without the others silently disables a background task. (Ch. 5 §11.2, Ch. 7 §5.3)
