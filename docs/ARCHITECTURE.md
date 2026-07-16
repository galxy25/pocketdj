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
  a **streaming-account source** (Apple Music) and a **ShazamKit**
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
  │ ENRICHMENT       │   │ DATA MODEL     │   │ ENGINE  (Mix · +AI ↗)  │
  │ vinyl·AppleMusic │   │ index JSON ·   │   │ pockets→playlists→     │
  │ ·audio·grid·stems│   │ model·collections   │ setlists·realize·Mix   │
  └──────────────────┘   └───────┬────────┘   └───────────┬────────────┘
                                 │                         │ setlist (Song IDs)
        ┌────────────────────────┼─────────────────────────┘
        ▼                        ▼                          ▼
  ┌────────────────┐   ┌──────────────────┐      ┌────────────────────────┐
  │ Ch.6 SEARCH &  │   │ Ch.5 PLAYBACK &  │      │ Ch.7 DISTRIBUTION &    │
  │ DISCOVERY      │   │ RIP-ON-DEMAND    │      │ CLIENTS                │
  │ aoss · starmap │   │ rip·burns·stems  │      │ S3/CloudFront·PWA+     │
  │ online/offline │   │ ·live HLS·offline│      │ native·TestFlight·edits│
  └────────────────┘   └──────────────────┘      └────────────────────────┘

         everything stands on ── Ch.1 FOUNDATIONS (entities · files-as-API · ids)
```

**Reading the map.** Across the top is the **production-to-performance spine**:
**Ch. 2** ingests diverse sources (vinyl, Apple Music, audio analysis, beat grids,
stems, art) into the **one catalog shape** of **Ch. 3**, which the **Ch. 4**
performance engine turns into realized setlists **and mixes live on a two-deck DJ
board** (the Mix engine, §7) — and is where **AI auto-*building*** lands next (the ↗
seam). The bottom row is how that catalog and those setlists reach the user:
**Ch. 6** makes it findable (search + the spatial star map), **Ch. 5** makes it
audible anywhere (rip-on-demand into a public S3 cache, live HLS, and **offline burns +
stems**), and **Ch. 7** distributes the artifacts to thin clients (the PWA + the native
TestFlight app) and closes the **edits round-trip** back to the catalog. Everything rests on **Ch. 1 Foundations** — the entities, the
"files-as-API" principle, and the content-derived ids that make the whole
server-less coordination work.

---

## Table of contents

| # | Chapter | Pillar of the goal | What's inside |
|---|---|---|---|
| 1 | [**Foundations**](./architecture/01-foundations.md) | the whole | System entities, ownership table, the files-as-API spine, content-derived ids. **Start here.** |
| 2 | [**Ingest & Enrichment**](./architecture/02-ingest-and-enrichment.md) | *diverse sources* | Filesystem (vinyl `*Raw`), `Library.xml`, AppleScript/Shortcuts capture, the 5-stage analog indexer, Apple Music indexer, audio analysis + art mirroring. |
| 3 | [**Catalog & Data Model**](./architecture/03-catalog-and-data-model.md) | *personal catalog* | Index JSON schema (incl. the `appleMusicId` **catalog-id stage** and the **cloud re-index** that folds Apple Music length/bpm/key in with cloud precedence via **tight `am-match`**), internal model, collections — incl. the **`CollectionsDocument` schema versioning (v2→v3) + flat playlist `folders`** — the one shape everything speaks. Reference chapter. |
| 4 | [**Performance Engine**](./architecture/04-performance-engine.md) | *Playlists Producer* | Pockets → playlists → setlists, the `realize()` engine, iTunes mirroring, **the Play/Shuffle reusable "Now Playing" setlist (`playNow`)**, **the two-deck Mix engine (first-party `AVAudioEngine` — tempo/pitch/seek/crossfader/4 effects, grid-aware beat-match, Auto-Mix, and offline STEM DECKS, §7)**, **and the AI auto-*building* seam, whose first consumer is the Siri "Create Pocket" on-device-LLM builder (§4.1)**, **and the native PERFORMANCE tab (Studio, §8+) — samples, beat-synced loops, a 16-step sequencer, MIDI virtual instruments with score/PDF/MIDI export, per-track cue points, and **on-device key detection that makes studio creations harmonically-mixable collection tracks (§8.8)**, whose creations ride collections as namespaced ids**. |
| 5 | [**Playback & Rip-on-Demand**](./architecture/05-playback-and-rip-on-demand.md) | *play & mix* | The rip server API (incl. batch `POST /rip-collection`, the `POST /rip-cancel` **stop + worker-kill**, the `rippedAt` manifest stamp, **the analog per-song CUT export + `POST /backfill-cuts` / `POST /retag-cuts`**), job state machine, live HLS, the public rips cache, mini-player + setlist playback, the native inline player (`PlayerEngine`/`PlayerClock`/TimelineView, **with a length-aware position end-boundary + held playback security-scope**), the stream-first → rip-last provider chain (`PlaybackCoordinator`) **with stream-through-rip**, the offline Collection Rip/Burn store (`BurnStore`, **+ user-browsable burnt-music folder + the metadata burn-filename scheme + the per-song analog-cut burn + the `@Observable` background-burn progress mirror**), the **length-aware + manual-jump-adopting** `SetlistPlayer` burnt-or-stream sequencer with **persistent ⏮/⏭ transport**, **the home NOW PLAYING deck (§10.1 — spinning beat-grid-rate gold record, live Up-Next queue edits by row identity, debounced add-search, iOS home/restore + macOS-Mix launch defaults)**, **the global device/cloud `PlaybackMode` + shared `playLocalFile` (burned-first + scope-held on EVERY song-start path) + the explicit offline catalog disk cache (`CatalogService` `catalog-cache/`)**, **the queue self-heal (per-job watchdog + transient backoff retry), the analog source config (`POCKETDJ_ANALOG_BASE`), the persistent collection-RIP Stop/progress poll, native BACKGROUND PROCESSING (`TransferCoordinator` background `URLSession` + `pocketdj-transfers.json` + BGTasks + background audio), the cloud-analog → `public/current-index.json` IN-PROCESS fold (`cloud-reindex-fold.mjs`), **the measured BEAT-GRID pass (`/backfill-beatgrids` → `beatGridBpm`/`firstDownbeatMs`/`steady`)**, and **STEMS end-to-end (server Demucs `/stemify` → public `rips/stems/`; the collection-burn STEM pull; the offline `StemPlayer` audition).** |
| 6 | [**Search & Discovery**](./architecture/06-search-and-discovery.md) | *instantly find* | OpenSearch Serverless (aoss), the SigV4 + CloudFront-proxy trick, online/offline modes, **online pagination (`from/size` + `track_total_hits`) + server-side sort + the `genreCategory` field**, **the native Browse genre + collection-membership filters**, **on-device Browse paging + the results memo (pre-built rows, `resultsKey`-keyed sort cache, growing-prefix render — instant tab/kind switching at ~100k songs)**, **Play History (§8, the `PlayHistoryStore` append-only per-play log) + the Artists browse kind (§9, shuffle a whole discography)**, the star map. |
| 7 | [**Distribution, Clients & Edits**](./architecture/07-distribution-and-clients.md) | *portable, anywhere* | S3/CloudFront (public-read), the PWA + native clients, **the native app as a single universal SwiftUI target (iPhone/iPad/Mac, iOS 18/macOS 15) built with XcodeGen and shipped to TestFlight (`apple-publish`/`testflight.sh`)**, the deploy loop, the edits round-trip, the native app's streaming-account providers + ShazamKit recognizer (bundle `com.levi.pocketdj`), **the `backfill-rip` skill for the catalog-id-crawl misses (`apple-music-catalog-misses.csv`), and the App Intents layer (§7) — Siri/Shortcuts/Spotlight: play/shuffle playlist + pocket, auto-mix with lock-screen-seam pause/resume, Spotlight entity indexing + intent donations, and the Siri "Create Pocket" builder — plus **CarPlay (§9), a thin template UI over the shared engines, and the Now Playing widgets (§10) — a WidgetKit extension fed over the `group.com.levi.pocketdj` App Group with intent-driven transport**.** |

---

## Status — what's built, by component

The architecture is built so the next pillars slot in **without breaking the data
contract**. This is an honest map of what ships today versus what's deferred, organized
by **component** (not by date): "Built" is shipping; "Deferred" means the seams exist and
the implementation is pending.

### Ch. 2 — Ingest & Enrichment
**Built:** the analog 5-stage indexer; the Apple Music (Local) indexer; audio analysis +
art mirroring; the `appleMusicId` catalog-id crawl (76,134 / 92,865 songs resolved →
stream; the remaining misses fall back to ripping and are listed in
`apple-music-catalog-misses.csv`, which the `backfill-rip` skill local-rips through
`/rip-collection`); the measured **beat-grid** pass (`/backfill-beatgrids`); **Demucs
stems** (`/stemify`, `/backfill-stems`); the **cloud re-index** fold (tight `am-match`,
per-field cloud precedence).

### Ch. 3 — Catalog & Data Model
**Built:** the index-JSON indexer↔app contract; the internal on-device model; collections
schema versioning (v2→v3 playlist folders, v3→v4 pocket folders, v4→v5 lossy
`[PlaylistNode]` decode + studio ids, v5→v6 converted-pocket source provenance + the
catalog-refresh three-way sync); the rips-manifest cut / beat-grid / stem fields;
the explicit offline catalog disk cache (`CatalogService`).

### Ch. 4 — Performance Engine
**Built:** `realize()` (seeded sampling + harmonic autofill); iTunes mirroring; the reusable
Play/Shuffle "Now Playing" setlist (`playNow`); the two-deck **Mix engine** (tempo · pitch ·
seek · equal-power crossfader · four effects · grid-aware beat-match Sync · timed **Auto-Mix**
with FX/Mix glide + pause-resume · offline **stem decks** · session audio recording · cue/PFL ·
beat pulse · pre/post VU meters · portrait deck-layout view modes); the **Studio** Performance
tab (samples · loops · 16-step sequencer · MIDI instruments with score / PDF / MIDI ·
cue points · **instrumentals** rendered to real audio · **on-device key detection** ·
performance items as first-class **collection tracks**); the Siri **"Create Pocket"** builder —
the AI seam's first shipped consumer.
**Deferred:** AI-curated auto-*building* of the set itself (the seams exist —
`SetlistTrack.mixSuggestions`, `PocketKind:'performance'`, and the `realize()` autofill
boundary an AI sequencer would extend); Studio **network + BLE MIDI**; the **PWA Studio UI**
(the web client silently drops studio ids from `realize`); routing the 32 MB instrument-pack
download through `TransferCoordinator`.

### Ch. 5 — Playback & Rip-on-Demand
**Built:** the rip-server API (batch `/rip-collection`, `/rip-cancel` stop + worker-kill,
the `rippedAt` stamp); queue self-heal (per-job watchdog + capped backoff retry); the analog
source config (`POCKETDJ_ANALOG_BASE`); live HLS; the native inline player
(`PlayerEngine`/`PlayerClock`, length-aware position end-boundary, held security scope); the
stream-first → rip-last `PlaybackCoordinator` with stream-through-rip; the offline `BurnStore`
(user-browsable burn folder, metadata burn-filenames, analog per-song cut export +
`/backfill-cuts` / `/retag-cuts`, `@Observable` background-progress mirror); the length-aware,
manual-jump-adopting `SetlistPlayer` with persistent ⏮/⏭ transport; the home **Now Playing**
deck; the global device/cloud `PlaybackMode` + shared `playLocalFile`; the persistent
collection-RIP Stop + progress poll; **background processing** (`TransferCoordinator`
background `URLSession` + BGTasks + background audio); the in-process cloud-analog fold; **stems
end-to-end** (`StemPlayer` audition + collection-burn stem pull); the storage manager (delete
tools + soft-cap LRP prune).

> The offline player and live mixer that consume the burn store — **once deferred** — now
> ship: `SetlistPlayer`, the Mix engine, and the stem decks all read the burned local files.

### Ch. 6 — Search & Discovery
**Built:** OpenSearch Serverless (aoss) + the SigV4 / CloudFront-proxy trick; online/offline
modes; online pagination (`from`/`size` + `track_total_hits`) + server-side sort + the
`genreCategory` field; the native Browse **genre** + **collection-membership** filters; the
**Artists** browse kind + shuffle-by-artist; the **Play History** timeline
(`PlayHistoryStore`, append-only); on-device Browse paging + the results memo; the star map.

### Ch. 7 — Distribution, Clients & Edits
**Built:** the S3 / CloudFront public-read content host; the PWA + a **single universal SwiftUI
target** (iPhone/iPad/Mac, with a native **visionOS** destination and **⌘N** multi-window),
built with XcodeGen and shipped to TestFlight (`apple-publish`); the deploy loop; the native
streaming-account (**Apple Music**) source + **ShazamKit** recognizer (including the
recognizer's *add-to-library → rip/burn* path); **CarPlay**; the `backfill-rip` skill for the
catalog-id-crawl misses; **App Intents** (Siri / Shortcuts / Spotlight); virtual-instrument
packs as a new public-read S3 artifact class.
**Deferred:** the **iMac edits-merge tool** — the client half and the schema are built, but the
server-side script that folds exported edits back into `current-index.json` does not exist yet.
(Web edits mutate IndexedDB in place with no portable round-trip; the versioned `EditsDocument`
is native-only — see [Ch. 7 §3](./architecture/07-distribution-and-clients.md#3-the-edits-database--the-round-trip).)

## Appendix — inconsistencies & notes for maintainers

Things found while writing that don't fully line up, gathered here so they're not lost:

1. **The iMac edits-merge tool does not exist yet.** `EditSchema.swift` /
   `EditsStore.swift` cite "the iMac merge tool that folds edits back into the index,"
   but there is no such script in `scripts/` or the skills. Client half built; server
   half deferred. (Ch. 7 §3)
2. **Web vs native edits are different mechanisms.** Web mutates IndexedDB in place (no
   portable doc, no round-trip); only native keeps the versioned `EditsDocument`. The
   "edits database" is a native-only entity today. (Ch. 7 §3)
3. **aoss collection vs index name.** Collection is `pocketdj-search` (NextGen
   scale-to-zero, id `mii9dwge3uiee2tvivt5` — changes on rebuild; clients read the host
   from `public/search-config.json`); the index inside it is `pocketdj`. Client code and
   the CloudFront proxy path both use `pocketdj` (the index), which must match. (Ch. 6)
4. **`coverArtSources.url` extension drift.** `mirror-art.sh` / `index-json.ts` show
   `/art/<id>.jpg`; the Swift `Config.artURL` docstring shows `.webp`. The mirror
   writes `.jpg` (`image/jpeg`); the `.webp` comment appears stale. (Ch. 2, 7)
5. **Live streaming is HLS-only; the legacy `/stream/<id>.mp3` route was removed.** The
   client detects live via `url.includes('/hls/')` and the job's `streamUrl` is the
   `/hls/<id>/index.m3u8` playlist; iOS needs HLS, and the durable public mp3 covers
   every non-live play, so the old progressive-mp3 route is gone (a maintainer wiring a
   client to `/stream` would 404). (Ch. 5 §2)
6. **`TrackSource:'autofill'` in data = `↔ bridge` in the UI** — code name and product
   label differ (a grep for "bridge" in the data layer comes up empty). (Ch. 4, 5)
7. **`POST /analysis` overloads "key".** The body uses `musicalKey` for the musical key
   but `key` for the S3 object key when creating a fresh entry — same word, two
   meanings in one payload. Not a bug, but a footgun. (Ch. 5)
8. **Streaming is Apple Music + ShazamKit.** **Apple Music** (flag on) + **ShazamKit**
   (public catalog) are the wired-live streaming/recognition paths; the Settings row reads
   "Not available" until Apple Music is provisioned, so the UI is honest. (Earlier Spotify
   + YouTube provider scaffolding was removed.) (Ch. 7 §5)
9. **`PlayerClock` is intentionally NOT `@Observable`.** The inline player's ~4×/s
   position lives on a plain `PlayerClock` sampled by a `TimelineView`, *by design* —
   making it `@Observable` would re-invalidate the panel and drop clicks on its control
   buttons (the documented "dead slide-out buttons" bug). A maintainer "fixing" the
   missing `@Observable` would regress it. (Ch. 5 §7)
10. **Bundle id moved to `com.levi.pocketdj`** (was `net.pocketdj.app`). External
    references (the Developer-portal App ID) must match this exactly; the `net.pocketdj.*`
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
13. **Two cloud-fold paths with opposite write targets — by design.** The **offline CLI**
    `scripts/reindex-cloud-analysis.mjs` writes a **SIDE output**
    (`index-out/reindex/current-index.json` + a report) and **never** touches
    `public/current-index.json`; the **rip-server in-process fold** (Ch. 5 §13) *does* write
    `public/current-index.json` directly (atomic, fold-fields-only working-tree guard,
    `report.changed`-gated). Both share the same pure `scripts/lib/cloud-reindex-fold.mjs`,
    but **neither deploys** — the in-process one logs a publish hint and leaves CloudFront
    untouched. A maintainer expecting *either* to ship the catalog, or expecting the CLI to
    mutate the live file, would be surprised. (Ch. 3 §1.2, Ch. 5 §13)
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
22. **The "Now Playing" setlist is deliberately NOT `realize()`.** `CollectionsStore.playNow`
    builds the reserved `set_now_playing` setlist **directly** from the resolved song ids —
    literal order, unresolvable ids dropped, **no** autofill/pocket-sampling/dedup. A
    maintainer "unifying" Play through `realize()` would reintroduce reordering and bridge
    inserts the ▶/🔀 buttons exist to avoid (and would start appending history takes). It's
    also cleared on launch + filtered out of `setlists(forPlaylist:)` history on purpose.
    (Ch. 4 §6)
23. **Playback `PlaybackMode` is read through a lazy seam so a mid-set flip is deferred.**
    `SetlistPlayer.playbackMode` is a `() -> PlaybackMode` closure read **per track**, so
    toggling device⇄cloud mid-set applies to the **next** track (the current one finishes
    under its starting mode). In **device** mode Play-All **skips** un-burned tracks (no
    fallback to cloud — that's the single-row tap's behaviour, not Play-All's), and a wholly
    un-burned set raises the one-shot `deviceQueueUnplayable` banner instead of silently
    ending. A maintainer expecting Play-All to stream a missing track in device mode, or the
    flip to interrupt the current track, would be wrong. (Ch. 5 §10, §12)
24. **The analog burn file is named ALBUM-level, not per-song.** Because one analog rip is a
    whole-side mp3 shared by every song of the album, `BurnStore.fileNames` gives analog the
    `Artist-Album-Year-Genre` prefix (no per-song bpm/key) so all the album's songs map to the
    **same** audio name — the shared-file reuse / `isFresh` / dedup logic depends on that. The
    `idSuffix` (albumId/songId) + extension are **never** truncated; only the descriptive
    prefix is capped. A maintainer adding per-song tokens to the analog prefix would break the
    shared-file dedup. (Ch. 5 §9)
25. **The analog CUT is BURN-ONLY — playback never touches `cutKey`.** Playback of an analog
    song stays *album mp3 + `startMs` seek*; `cutKey`/`cutBytes`/`cutRippedAt` (manifest) and
    `cutFileName`/`cutDownloadedAt` (`BurnItem`) are consumed **only** by the burn's per-song
    export. The cut goes under the **public** `rips/` prefix with a `.cut.` infix
    (`rips/<songId>.cut.mp3`) to stay distinct from a per-song cloud rip's `rips/<songId>.mp3`.
    A maintainer routing playback through the cut (or filing it under a private prefix) would
    break offline play and the public read. (Ch. 5 §5, §9, Ch. 3 §1)
26. **The position end-boundary arms ONLY on a non-nil analog `startMs`.** `PlayerEngine`'s
    `endBoundarySec` (= `startMs+length`) exists so a track inside a **shared** album mp3
    advances at its own length; a **per-song** file (`startMs` nil) must rely on its natural
    end, because the catalog `length` can be missing/short and would cut it early. Both end
    paths funnel through one `signalTrackEnded` latch (reset per `load`/`setEndBoundary`) so the
    set can't double-advance. A maintainer arming the boundary for every track would truncate
    per-song burns. (Ch. 5 §7, §10)
27. **Burned playback MUST hold the security scope until the player is done.** `localURL`
    stops the scoped-folder access in its `defer` (fine for an existence check), so playback
    uses **`localURLForPlayback`**, which keeps the scope OPEN and hands `PlayerEngine` a
    `release` closure fired on the next `load`/`stop`. Releasing early leaves AVPlayer unable to
    read a user-folder burn → a silent 0:00/no audio. Relatedly, the playback `resolveBurnFolder`
    read path uses `requireWritable=false` (an offline iCloud-Drive folder resolves read-only).
    A maintainer reusing `localURL` for playback regresses the offline no-audio bug. (Ch. 5 §9, §12)
28. **The catalog disk cache is a deliberate replacement for `URLCache`, and is per-source.**
    `CatalogService` keeps an explicit `catalog-cache/<sha256-of-url>.json` because `URLCache`
    silently refuses to persist the (large) index past relaunch, leaving offline launch with
    nothing. `AppModel.fetchIndex` fails only when **every** enabled source has neither network
    nor cache — an un-cached source is skipped so an already-cached one still opens. A
    maintainer reverting to `.returnCacheDataElseLoad`-on-`URLCache` alone would silently break
    offline relaunch. (Ch. 5 §12, Ch. 7 §1)
29. **The "Burning N of M" overlay reads `BurnStore.backgroundProgress`, NOT the coordinator.**
    `TransferCoordinator` is a plain `NSObject` (it must be the background-`URLSession` delegate),
    so a view bound to its `progressSnapshot` never re-renders as downloads finish (the
    "burning number doesn't update" bug). The count is mirrored onto the `@Observable`
    `BurnStore.backgroundProgress` via an `onProgress` main-actor hook. A maintainer re-binding
    the overlay to the coordinator would freeze it at the enqueue total. (Ch. 5 §9)
30. **The Mix spec is "research"; the shipped `MixEngine.swift` is authoritative — and the
    node order differs.** `docs/design/mix-ondevice-tempo-pitch-beatmatch-spec.md` is dated
    "not yet built" and its graph diagram (`TimePitch → EQ → Reverb → Dynamics`, no inputMixer,
    no flanger) does **not** match the code. The live `connectChain()` order is
    `player → inputMixer → timePitch → comp(Dynamics) → filter(EQ) → reverb → flanger(Delay) →
    mainMixer`, and the engine adds Auto-Mix + stem decks the spec never covered. Trust the
    code. (Ch. 4 §7)
31. **`stemVersion` (singular) is the canonical "is stemmed" flag — there is no `stemKeys`
    / `stemRippedAt`.** The manifest stem group is `stems:{vocals,drums,bass,other}` (the 4 S3
    keys) + `stemModel`/`stemVersion`/`stemFormat`/`stemmedAt`/`stemBytes`; presence of
    `stemVersion` ⇒ stemmed (`RipsStore.isStemmed`). It's **distinct from `analysisVersion`**
    (the shared bpm/key/**beat-grid** stamp), so a Demucs model change never forces a beat-grid
    re-run and vice-versa. A maintainer collapsing the two version stamps would couple unrelated
    re-analysis sweeps. (Ch. 3 §4.3, Ch. 5 §15)
32. **Stems + beat grids are PER-SONG, even for analog.** A vinyl song stems/grids its per-song
    **cut** (`rips/<id>.cut.mp3`), never the shared album side — so a stem key is always
    `rips/stems/<songId>/…` and a grid is keyed by `songId`. A maintainer stemming the album mp3
    would mis-key every analog song to one blob. (Ch. 5 §14, §15)
33. **Every stem surface is OFFLINE-ONLY (burned local files), and burning FETCHES stems — it
    never separates them.** The Mix stem decks (`MixEngine`), the SongDetail audition
    (`StemPlayer`), and the collection-burn pull all require the 4 stems to be **burned locally**
    and require all four present; the "Stems" affordance only appears for a track the **server**
    has already stemmed (`rips.isStemmed` ⇒ `stemVersion != nil`). `MixResolver` likewise drops
    any song with no burned file, so a mix is offline-by-construction. A maintainer wiring stem
    playback to a stream, or triggering Demucs from the burn, breaks the model. (Ch. 4 §7.6,
    Ch. 5 §9, §15)
34. **`/health` advertises `stems:true` as a capability flag with NO `RIP_PROTOCOL` bump.**
    Stems and beat grids are **additive** manifest fields, so the protocol version stays `2` and
    an older client neither sees the "outdated — restart it" banner nor breaks; it just ignores
    the new fields. A maintainer bumping `RIP_PROTOCOL` for an additive field would needlessly
    flag every old client as outdated. (Ch. 5 §2, §15)
35. **The native app is ONE universal target, not three.** `apple/project.yml` declares a single
    `application` target with `supportedDestinations:[iOS,macOS]` × `TARGETED_DEVICE_FAMILY "1,2"`
    (iOS 18 / macOS 15); iPhone/iPad/Mac come from that one target + `#if os(...)` forks, and the
    `.xcodeproj` is **generated** by XcodeGen (a file added via the Xcode UI is dropped on the
    next `xcodegen generate`). A maintainer adding per-platform targets or hand-editing the
    project would fight the generator. (Ch. 7 §2.1)
36. **Two different "setlist CSV"s exist — don't conflate them.** The native app exports a
    **universal tracklist CSV** (`#, Title, Artist, Album, Year, Genre` — `TracklistCSV`, chosen via
    the PocketDJ/CSV format picker) that deliberately carries **no** BPM/key/**Song ID**. The
    `burn-setlist` **tooling skill** still requires a **richer** `#,Artist,Title,BPM,Key,Length,
    Source,Sequence,Song ID` CSV (it resolves rips by the **Song ID** column) — that Song-ID export
    is the **PWA/tooling** path, not the native app's. A maintainer feeding the native universal CSV
    to `burn-setlist` would get "Song ID column missing"; downstream audio resolution rides the
    **`.pocketdj.zip`** (catalog-by-id) instead. (Ch. 4 §5, Ch. 5)
37. **`apple/PocketDJ/Performance/` is the realize engine; the Performance *tab* lives in
    `apple/PocketDJ/Studio/`.** The directory `Performance/` predates the Studio and holds
    `RealizeEngine.swift` (with a `struct Performance` at `RealizeEngine.swift:44`) — the pockets →
    playlists → **setlist realize** math, nothing to do with the UI tab named "Performance". The new
    top-level tab's code (samples/loops/sequencer/instruments/cues) is entirely under `Studio/`, and
    every new type carries a `Studio*` / `Instrument*` prefix precisely so it can't collide with the
    reserved `Performance` type or the reserved `PocketKind:'performance'` (the AI-crate seam). A
    maintainer who "consolidates the two Performance folders," renames `Studio/` to `Performance/`, or
    adds a bare `Performance`-named type would conflate the realize engine with the tab and shadow the
    existing struct. Note also `RootView.Section.performance` **rawValue is `"Performance"`** and is
    persisted (`settings.lastSection`) — renaming the case rawValue silently strands users on a dead
    restore key. (Ch. 4 §1, §8)
38. **Studio ids must NEVER reach a rip / burn / stemify / CSV resolver — the exclusion is
    per-consumer, and enforced in TWO places.** Studio samples/loops/patterns ride collections'
    plain string arrays as `smp_`/`lp_`/`ptn_` ids, so *every* collection-shaped id list is a
    potential leak. The policy is intentionally **per-consumer, not global**: playback, counts/runtime,
    and realize node-placement **include** studio ids (`CollectionsStore.playableIds(forSetlist:)`,
    the studio-aware catalog), while Rip/Burn/Stemify, the tracklist CSV (`songIds(forSetlist:)`), and
    realize *autofill* **exclude** them. The client fence is `RipsStore.excludingStudioIds` (+ the
    single-song `fencedStudioId` guard); the **server** independently rejects `smp_|lp_|ptn_|tk_` at
    `/rip`, `/rip-collection`, `/stemify` in `scripts/rip-server.mjs`, because the rip server is
    **shared infrastructure across app versions** — an *old* build with no Studio, playing a studio row
    through its play-through-coordinator, must not live-search-rip a garbage title into the **public**
    bucket. A maintainer who routes playback through the catalog-only `songIds(...)` (studio rows go
    silent) or drops either the client fence or the server guard (studio garbage hits S3) breaks the
    model. `cue_` ids are deliberately **not** in `StudioFactory.studioPrefixes` — a cue never rides a
    collection array. (Ch. 4 §6, Ch. 5 §2, §9; STORYBOOK [The Studio](./storybook/studio.md))
39. **Loop files are LPCM CAF with an authoritative frame count — AAC would tick at the seam.** Every
    other Studio artifact (samples, take audio, pattern bounces) is `.m4a`, but a **loop** is written
    as **LPCM CAF** (`loop-<id>.caf`, `StudioFolders`/`StudioRender.cafSettings`) and carries an
    authoritative `frames: Int64` in `StudioLoop`. AAC's encoder priming/padding adds a few ms of
    silence at file head/tail, so an m4a loop **ticks** on every wrap; CAF has no such gap, the render
    truncates to exactly the beat-window frame count, and the audition trims/pads the decoded buffer to
    `frames` before `scheduleBuffer(..., .loops)`. A maintainer who "unifies" loops to `.m4a` for
    consistency, or treats `lengthMs` (advisory) as the loop length instead of `frames`, reintroduces
    the seam tick and drifts the beat. (Ch. 4 §9; STORYBOOK [The Studio](./storybook/studio.md))
40. **`StudioRender` bounces with `AVAudioFile(forWriting:)`, NEVER the realtime `MixTapSink`
    recipe.** The offline renderer (`StudioRender.swift`) runs
    `AVAudioEngine.enableManualRenderingMode(.offline)` and writes output with
    `AVAudioFile(forWriting:settings:)` — **blocking** writes with no backpressure. The Mix session
    recorder's `MixTapSink`/`AVAssetWriter` path is a **realtime** tap that *drops buffers when the
    encoder is busy* (the common case offline), so only its **failure-latch** discipline carries over,
    not the writer. Render rules that matter: samples/bounces render `ceil(frames/rate)` **+ an FX tail
    drain** (until < −60 dBFS or a 3 s cap); **loops truncate to the exact beat-window frames** (tails
    cut — seams stay clean); and the timePitch/AU **priming-latency head is trimmed** so written frame
    0 is musical frame 0 (else every baked loop opens with silence and beat-sync dies). A maintainer
    who swaps in the `MixTapSink` recipe offline gets silently truncated/dropped renders. (Ch. 4 §8,
    §9; appendix #39)
41. **The collections v5 lossy `[PlaylistNode]` decode is the unknown-kind insurance — never revert
    it to a whole-array `try?`.** `collectionsSchemaVersion = 5` ships **`LossyDecodableArray<T>`** at
    **every** node-list site — a playlist's `sequences` chapters, the recursive `children`, AND the
    document's top-level `[Playlist]` list — so a single node the running build can't decode (a
    *future* new `PlaylistNode.Kind`, or a corrupt element) drops **only that node**, never its
    siblings, chapter, playlist, or document. This is what makes studio ids (and any later new kind)
    safe to add without a migration wiping older builds — the synthesized-`Codable` trap, where one
    unknown enum case throws the whole array. A maintainer who "simplifies" a lossy list back to
    `try? container.decode([PlaylistNode].self)` (or forgets the per-element box on a newly-added
    nested array) reinstates the whole-playlist-wipe bug the v5 decode exists to prevent. The v4→v5
    migration is a deliberate **no-op** (shape unchanged; v5 *is* the decode behavior). (Ch. 3 §3.1,
    Ch. 4 §8; STORYBOOK [The Studio](./storybook/studio.md))
42. **`AudioSessionPolicy.micCaptureActive` guards EVERY `setCategory(.playback)` call site — it is
    not optional at any of them.** The mic recorder / instrument-take capture runs the iOS session as
    `.playAndRecord`; a stray `setCategory(.playback)` from any *other* engine mid-take (a setlist
    auto-advance, a StemPlayer load) is itself a **route-changing** operation that would yank the
    category out from under the live input tap and drop the recording. So a process-wide nonisolated
    atomic `AudioSessionPolicy.micCaptureActive` is set for the take's duration and **every**
    `setCategory(.playback)` site NO-OPs on it: `MixEngine`, `PlayerEngine`, `StemPlayer`,
    `MixSessionsView`'s `RecordingAudioPlayer`, and the Studio's own engines. A maintainer who adds a
    **new** playback engine (or a new `setCategory(.playback)` call) without wiring this guard
    reintroduces the take-killing route change — the flag only protects the sites that check it.
    (Ch. 4 §8; STORYBOOK [The Studio](./storybook/studio.md))
