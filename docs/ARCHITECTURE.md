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
| 3 | [**Catalog & Data Model**](./architecture/03-catalog-and-data-model.md) | *personal catalog* | Index JSON schema, internal model, collections — the one shape everything speaks. Reference chapter. |
| 4 | [**Performance Engine**](./architecture/04-performance-engine.md) | *Playlists Producer* | Pockets → playlists → setlists, the `realize()` engine, iTunes mirroring, **and the deferred AI auto-mixing seam**. |
| 5 | [**Playback & Rip-on-Demand**](./architecture/05-playback-and-rip-on-demand.md) | *play & mix* | The rip server API, job state machine, live HLS, the public rips cache, mini-player + setlist playback, **and the native inline player (`PlayerEngine`/`PlayerClock`/TimelineView).** |
| 6 | [**Search & Discovery**](./architecture/06-search-and-discovery.md) | *instantly find* | OpenSearch Serverless (aoss), the SigV4 + CloudFront-proxy trick, online/offline modes, the star map. |
| 7 | [**Distribution, Clients & Edits**](./architecture/07-distribution-and-clients.md) | *portable, anywhere* | S3/CloudFront (public-read), the PWA + native clients, the deploy loop, the edits round-trip, **and the native app's streaming-account providers + ShazamKit recognizer (bundle `com.levi.pocketdj`).** |

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
  needs the App-ID MusicKit service to run on device) and **ShazamKit** uses the public
  catalog (entitlement-only); **Spotify** and **YouTube** are **scaffolded — pending an
  SDK + credentials** a developer drops in per
  [`docs/streaming-integration.md`](./streaming-integration.md). Bundle id is now
  **`com.levi.pocketdj`**.
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
```
