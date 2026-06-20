# Chapter 1 — Foundations: entities, ownership & the "files-as-API" spine

> Part of the [PocketDJ Architecture Book](../ARCHITECTURE.md). This chapter
> establishes the **vocabulary, the actors, and the single organizing principle**
> the rest of the book builds on. Read this first.

## Why this chapter exists

PocketDJ's goal — *Portable, Personal, Musical Performance Playlists Producer:
anyone, anywhere, instantly creating, playing and mixing playlists from diverse
musical sources* — imposes one ruthless constraint: **the thing the user touches
must work offline, anywhere, with no server they have to run.** The simplest way to
honor that is to make the backend produce **static, public, cacheable documents**
and make every client a **thin, offline-first consumer** of them.

So the whole architecture collapses to one sentence:

> **One iMac is the entire backend toolchain (ingest, enrichment, rip server,
> deployer); AWS S3 + CloudFront is a dumb, public-read content host; every client
> — the web PWA and the native SwiftUI apps — is a thin, offline-first consumer of
> the same static documents and the same rip API. There is no application server.
> The "API" is mostly files.**

Internalize that and every later chapter is just a refinement of it.

## The system at a glance

```
  ┌──────────────────────────── iMac (levis-imac) ────────────────────────────┐
  │  Filesystem            Indexers (Node + Docker)        Rip server         │
  │  ┌───────────────┐     ┌──────────────────────┐     ┌──────────────────┐  │
  │  │ vinyl rips    │────▶ │ analog-indexer       │     │ rip-server.mjs   │  │
  │  │ *Raw.mp3/aiff │     │ apple-music-indexer  │     │ (launchd agent,  │  │
  │  │ Library.xml   │────▶ │ es-index / mirror-art│     │  port 8787)      │  │
  │  └───────────────┘     └─────────┬────────────┘     └────────┬─────────┘  │
  │  Music.app + Audio Hijack         │ deploy.sh                 │ Tailscale  │
  │  (AppleScript / Shortcuts)        │                           │ HTTPS      │
  └───────────────────────────────────┼───────────────────────────┼───────────┘
                                       │                           │
                  ┌────────────────────▼─────────┐    ┌────────────▼──────────┐
                  │ AWS  (account 011183829623)  │    │  (writes via levi creds)│
                  │ S3 web bucket ── CloudFront   │    │  S3 rips bucket (public)│
                  │  current-index.json           │    │  rips/manifest.json     │
                  │  apple-music-index.json       │    │  rips/<id>.mp3 + waves  │
                  │  /art/* · app shell · sw.js   │    └────────────┬──────────┘
                  │  OpenSearch proxy (/pocketdj) │                 │
                  └───────────┬──────────────────┘                 │
                              │ public-read https                  │ public-read https
            ┌─────────────────┴───────────┬──────────────────┬─────┘
            ▼                             ▼                  ▼
   ┌────────────────┐          ┌──────────────────┐   ┌──────────────────┐
   │ Web PWA        │          │ SwiftUI apps     │   │ OpenSearch (aoss)│
   │ React/Vite     │          │ iPhone/iPad/Mac  │   │ collection       │
   │ IndexedDB      │          │ (apple/)         │   │ pocketdj-search  │
   └────────────────┘          └──────────────────┘   └──────────────────┘
```

**Reading the diagram.** The **iMac** (Tailscale name `levis-imac`) is the only
machine that *produces* anything. Three concerns live on it: (1) the **Filesystem**
holding source media — vinyl rips named `*Raw.mp3` and the exported Apple Music
`Library.xml`; (2) the **Indexers**, Node scripts (some shelling to a Docker/librosa
container) that turn media into JSON, plus `deploy.sh` which pushes results to AWS;
and (3) the **Rip server**, a long-running Node HTTP service (`scripts/rip-server.mjs`)
run as a launchd agent on port 8787 and exposed over **Tailscale HTTPS**. Music.app +
Audio Hijack (driven by AppleScript + Shortcuts) are how it captures Apple Music
audio in real time.

**AWS** is the passive middle. The **S3 web bucket** (fronted by **CloudFront** for
HTTPS — a PWA service worker requires it) serves the catalog documents, mirrored art
under `/art/*`, the app shell + `sw.js`, and a same-origin search proxy at
`/pocketdj`. The separate **S3 rips bucket** is the public audio cache. Both buckets
are **public-read but not public-write** — all writes go through the iMac with the
`levi` IAM credentials.

The three **clients** read the *same* public artifacts: the web **PWA** (React/Vite,
caches into IndexedDB) and the native **SwiftUI apps** under `apple/` both load the
catalog from CloudFront, play from the rips bucket, and search the `aoss` collection
`pocketdj-search`. They are client-only; none holds authority over the data.

## The entities, one paragraph each

| Entity | Where it runs | Owns / is authoritative for | Chapter |
|---|---|---|---|
| **iMac (central server)** | `levis-imac` | All production: source media, indexers, rip server, the `levi` AWS creds, the deployer | this chapter + 2, 5 |
| **S3 web bucket + CloudFront** | AWS us-west-2 | Public-read serving of catalog/art/app-shell/search-proxy | 7 |
| **S3 rips bucket** | AWS us-west-2 | Public-read audio cache (`rips/<id>.mp3` + manifest) | 5 |
| **Web PWA** | browser (installable) | A device-local IndexedDB copy of the catalog + collections | 7 |
| **SwiftUI apps** | iPhone/iPad/Mac | A device-local catalog + a versioned edits overlay | 7 |
| **Rip server API** | iMac, exposed via Tailscale | Creating rips on demand; the job state machine | 5 |
| **Filesystem (analog sources)** | iMac | The ground-truth vinyl audio (`*Raw`) | 2 |
| **Apple Music `Library.xml`** | iMac | The digital library + Persistent IDs | 2 |
| **AppleScript / Shortcuts "API"** | iMac | Driving Music.app + Audio Hijack to capture audio | 2, 5 |
| **OpenSearch Serverless (aoss)** | AWS us-west-2 | Full-catalog online search (`pocketdj-search`/`pocketdj`) | 6 |
| **Edits database** | clients (native = canonical) | User metadata overrides + the round-trip contract | 7 |

## The one principle: content-derived ids make everything idempotent

Every album and song has a **stable, content-derived id**:

```
 albumId = "alb_" + sha1(normArtist | normAlbum | dupIndex)[:12]
 songId  = "sng_" + sha1(albumId | track | disc)[:12]            # analog
 songId  = "sng_" + sha1("digital" | sourceName | persistentID)[:12]  # Apple Music
```

Because ids are derived from content (not random, not row-order), **re-running any
indexer is idempotent**, an **edit keyed by an id is unambiguous on every client and
every source**, and the same album owned on **vinyl *and* in Apple Music never
collides** (the digital id is namespaced by source). This single decision is what
lets the "files-as-API" model work without a coordinating server: the id *is* the
coordination.

## How the pieces serve the goal (the throughline)

- **Diverse sources** → Chapter 2 ingests vinyl + Apple Music (+ a streaming seam)
  into one shape.
- **Personal catalog** → Chapter 3 is the data model that one shape becomes.
- **Playlists you produce** → Chapter 4 is pockets → playlists → setlists, and the
  realize engine (where **AI auto-mixing/auto-building lands next**).
- **Play & mix** → Chapter 5 makes the catalog audible anywhere (rip-on-demand).
- **Find the right record** → Chapter 6 is discovery + online search.
- **Portable, anywhere** → Chapter 7 is distribution + the thin clients + the edits
  round-trip.

## Next

→ [Chapter 2 — Ingest & Enrichment](./02-ingest-and-enrichment.md)
