# PocketDJ — Architecture Index

The one-screen map of the PocketDJ system. Read this page, pick your **platform
doc**, and from there dive into the shared **chapter files** that hold the full
context (entities, data flows, schemas, diagrams, worked examples).

## The goal

> **PocketDJ — Portable, Personal, Musical Performance Playlists Producer:** let
> anyone, anywhere, **instantly create, play, and mix playlists from diverse musical
> sources.**

## The system in one screen

```
                         ┌──────────────  SHARED CORE  ──────────────┐
  sources                │  iMac toolchain          AWS              │   clients
  ─────────              │  ───────────────         ───              │   ───────
  vinyl rips (*Raw) ───▶ │  indexers / enrichment   S3 + CloudFront  │ ◀── web PWA
  Apple Music Library ─▶ │  rip server (Tailscale/  (public-read     │ ◀── Apple app
  "My Digital" files ──▶ │   Funnel HTTPS)          files-as-API)    │      (SwiftUI,
  imported transfers ──▶ │  jukebox broker          SQS + EC2 workers│       universal)
                         │  deploy loop             (scale-to-0)     │ ◀── Android app
                         │                          aoss search      │      (planned)
                         └───────────────────────────────────────────┘
```

**The shared core, in brief.** Multiple ingest pipelines on one iMac normalize
diverse sources into **one catalog shape** with stable, content-derived ids,
published as static JSON + art to **S3 behind CloudFront** (public-read — the "API"
is mostly files). The iMac also runs the **rip server** (rip-on-demand, live HLS, a
public S3 rips cache, burns, stems) and the **jukebox broker** (a crowd-request
line with a static S3 guest page). Heavy audio work — Demucs stems, bpm/key/
beat-grid/waveform analysis, faster-whisper lyrics — is offloaded over **SQS to
autoscaling EC2 workers** that scale to zero. Online full-text search is
**OpenSearch Serverless (aoss)** reached through a CloudFront SigV4 proxy. Every
client — the web PWA and the native apps — is a thin, **offline-first** consumer of
the same static documents and the same rip API; there is no application server.

## Platform docs

| Doc | What it covers |
|---|---|
| [**ARCHITECTURE-APPLE.md**](./ARCHITECTURE-APPLE.md) | The **shipped system**: the shared core above in full, plus everything Apple-client-specific — the universal SwiftUI app (iPhone/iPad/Mac + visionOS), all tabs and engines (Mix, Studio, Demux), CloudKit sync, MusicKit/ShazamKit, widgets, CarPlay, App Intents, multi-window, TestFlight distribution — with the per-component **Status** ledger and the maintainer **Appendix**. |
| [**ARCHITECTURE-ANDROID.md**](./ARCHITECTURE-ANDROID.md) | The **Android port** — a living doc, updated as it is implemented. Locked stack decisions (Kotlin 2.x + Compose, Media3, minSdk 35 / target 36), the sources reality on Android (no MusicKit, no CloudKit), the phase plan, and open questions. Mirrors the Apple doc's sections. |

## Chapters (shared reference)

One chapter per architectural pillar; both platform docs point into these.

| # | Chapter | Pillar |
|---|---|---|
| 1 | [**Foundations**](./architecture/01-foundations.md) | Entities, ownership, the files-as-API spine, content-derived ids. **Start here.** |
| 2 | [**Ingest & Enrichment**](./architecture/02-ingest-and-enrichment.md) | The ingest pipelines: vinyl, Apple Music, digital files, audio analysis, art, stems, lyrics. |
| 3 | [**Catalog & Data Model**](./architecture/03-catalog-and-data-model.md) | The index-JSON schema, internal model, collections + favorites documents. Reference chapter. |
| 4 | [**Performance Engine**](./architecture/04-performance-engine.md) | Pockets → playlists → setlists, `realize()`, the Mix engine, the Studio. |
| 5 | [**Playback & Rip-on-Demand**](./architecture/05-playback-and-rip-on-demand.md) | The rip-server API, live HLS, burns, offline playback, transport. |
| 6 | [**Search & Discovery**](./architecture/06-search-and-discovery.md) | aoss online search, Browse filters, history, Discover, the star map. |
| 7 | [**Distribution, Clients & Edits**](./architecture/07-distribution-and-clients.md) | S3/CloudFront hosting, the clients, the deploy loop, the edits round-trip, system integration. |

For the **outside-in, customer/product** story — what the DJ sees and does, screen
by screen — read [`STORYBOOK.md`](./STORYBOOK.md).
