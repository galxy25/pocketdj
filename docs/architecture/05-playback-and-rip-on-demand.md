# Chapter 5 — Playback & Rip-on-Demand: making the crate audible anywhere

> Part of the [PocketDJ Architecture Book](../ARCHITECTURE.md). Prereqs:
> [Ch. 1 Foundations](./01-foundations.md), [Ch. 2 Ingest](./02-ingest-and-enrichment.md).
> This is the **"play and mix"** pillar — turning a metadata catalog into something
> you can actually hear, from a phone, anywhere.

---

## 1. Why a rip server at all

The catalog is metadata; the audio is not in the catalog. Vinyl audio is a big raw
file on the iMac, and Apple Music tracks mostly **stream** (no local file). To make
the crate **playable end-to-end from a phone**, something on the iMac must, on demand:
locate or capture the audio, transcode it to a portable mp3, push it to the **public**
cache, and — for Apple Music — let the client **play while capture is still running**.
That something is `scripts/rip-server.mjs` — the one piece of live, privileged compute
the clients talk to, reached securely over **Tailscale HTTPS**.

The payoff: **rip once → instant forever, anywhere.** Because the cache is a
public-read S3 bucket, every later play works **with the rip server off** — the
server is only needed to *create* a rip.

---

## 2. The rip server API

**Source of truth:** [`scripts/rip-server.mjs`](../../scripts/rip-server.mjs) (server),
[`src/store/useRipsStore.ts`](../../src/store/useRipsStore.ts) (web client),
[`apple/PocketDJ/State/RipsStore.swift`](../../apple/PocketDJ/State/RipsStore.swift) +
[`apple/PocketDJ/Playback/PlayerEngine.swift`](../../apple/PocketDJ/Playback/PlayerEngine.swift)
(native iOS/Mac app client — same manifest + `/rip`/`/jobs`/HLS contract as the web
client; `AVPlayer` plays the live HLS *and* the durable mp3 natively, behind an inline
slide-out player with a `MPNowPlayingInfoCenter` lock-screen transport).
A dependency-free `node:http` server on port 8787 that shells to
`ffmpeg`, `aws` (profile `levi`), the digital worker `scripts/rip-one.mjs`, and the
Docker librosa analyzer (`scripts/lib/audio-analyze.mjs`). Catalog from `RIP_SOURCES`
(`public/current-index.json,public/apple-music-index.json`); mirrors the rips bucket
manifest in memory.

| Method · Path | Purpose | Response |
|---|---|---|
| `GET /health` | version handshake + stats | `{ ok, host, version, hls, bucket, catalog:{songs,albums}, cached, auth }` |
| `GET /status/:songId` | is it ripped? | `{ ready:true, url, entry }` or `{ ready:false, job }` |
| `POST /rip` `{songId}` | start/join a rip | `JobView` |
| `GET /jobs/:id` | poll a job | `JobView` |
| `GET /hls/<songId>/index.m3u8` · `…/seg_N.ts` | live HLS (iOS-native) | playlist / TS segment |
| `GET /stream/<songId>.mp3` | live progressive mp3 (tail) | chunked `audio/mpeg` |
| `POST /analysis` `{songId,bpm,…}` | external analysis submit | `{ ok, songId }` |

Auth is a bearer token (`RIP_TOKEN`); media paths (`/hls`, `/stream`) also accept
`?token=` because a native `<audio>` can't set an Authorization header. `version` is
`RIP_PROTOCOL = 2`; the client (`EXPECTED_RIP_VERSION = 2`,
`RipServerService.expectedVersion = 2`) shows an "outdated — restart it" banner if a
reachable server reports `< 2`.

---

## 3. The job phase state machine

```
   POST /rip {songId}
        │
        ▼
   ┌─────────┐   single-flight per resourceKey
   │ queued  │   (analog: albumId · digital: songId)
   └────┬────┘
        ▼
   ┌──────────┐         ANALOG path                 DIGITAL path (Apple Music)
   │ searching│   resolve file at analogBase   resolve persistentID via Library.xml
   └────┬─────┘   /<originalFilename>          rip-one.mjs → Audio Hijack capture (Ch.2)
        ▼
   ┌──────────┐   ffmpeg → whole-album mp3     tail-capture exposes ► streamReady
   │ ripping  │───────────────┐               ──┐ (streamUrl: /hls/<id>/index.m3u8)
   └────┬─────┘               │                 │
        │              (analog never streams)   ▼
        │                              ┌───────────┐  client plays LIVE here
        │                              │ streaming │  while capture continues
        │                              └─────┬─────┘
        ▼                                    ▼
   ┌──────────┐   aws s3 cp rips/<id>.mp3   register manifest entry for this songId
   │ uploading│   register EVERY song of
   └────┬─────┘   the album (one upload)
        ▼
   ┌──────────┐   url = https://…/rips/<id>.mp3   → enqueueAnalysis(songId)
   │  ready   │   (or ── error ── on any failure)   (background bpm/key/waveform, Ch.2)
   └──────────┘
```

**Reading the diagram.** A `POST /rip {songId}` creates a job starting in **queued**.
`resourceKey` enforces **single-flight**: analog jobs key on `albumId` (one rip serves
a whole album side), digital jobs on `songId`; a duplicate request joins the existing
job. **searching** splits the two paths. **Analog** resolves the raw file at
`analogBase/<album.pointer.originalFilename>` and, in **ripping**, `ffmpeg`-transcodes
the *whole album* to one 256k mp3 — it never enters **streaming** (already
faster-than-real-time; the user seeks within the album file). **Digital** hands off to
`rip-one.mjs`, which drives Audio Hijack to record Music in real time; once the
growing capture has a first segment it sets `streamReady`, exposing
`streamUrl = /hls/<songId>/index.m3u8`, and reports **streaming** — the client plays
the **live HLS** stream (red ● LIVE) *while capture continues*. Both reach
**uploading** (`aws s3 cp` to `rips/<id>.mp3`) and register manifest entries (analog
registers **every** song of the album from one upload, each with its `startMs` for
auto-seek). **ready** publishes `url = https://pocketdj-rips-…/rips/<id>.mp3` and
enqueues background analysis. Any failure → **error**.

**Durability.** An accepted `/rip` writes `<tmp>/queue/<songId>.json`, deleted only on
terminal (ready/error) — so a pending rip **survives a restart** (`resumePending()`
re-enqueues, skipping anything already cached). `resumeAnalysis()` likewise re-queues
ripped-but-unanalyzed entries on boot.

---

## 4. Transport — client ↔ server ↔ S3

```
 client tap ▶/⤓
     │ ensureUrl(songId): urlFor() checks manifest first (cache hit ⇒ done)
     ▼ (miss)
 POST https://levis-imac.tail2e2bdf.ts.net/rip {songId}   (Tailscale HTTPS)
     ▼
 rip-server.mjs ── analog: ffmpeg whole-album mp3
     │           ── digital: rip-one.mjs → Audio Hijack live capture → HLS
     │ aws s3 cp (profile levi)
     ▼
 S3 rips bucket  rips/<id>.mp3  +  rips/manifest.json   (public-read)
     ▼ client refreshManifest() / direct GET
 audio plays from https://pocketdj-rips-…/rips/<id>.mp3   (works with server OFF)
```

**Reading the diagram.** `ensureUrl(songId)` checks the in-memory **manifest**
(`urlFor`) first — a hit returns the public mp3 URL, no server needed. On a miss the
client `POST /rip` over **Tailscale HTTPS**. The server runs the analog/digital path
and `aws s3 cp`s the result (mp3 + updated `manifest.json`) into the **public-read**
rips bucket as `levi`. The client then streams the live URL immediately or, after
`refreshManifest()`, plays the durable public mp3 — which works even with the server
off.

---

## 5. The rips manifest + job payloads

**Source of truth:** `scripts/rip-server.mjs` (producer), `src/store/useRipsStore.ts`
(consumer).

```
 rips/manifest.json : { [songId]: ManifestEntry }
   ManifestEntry { key:"rips/<id>.mp3", ext, bytes, source:'analog'|'digital',
                   albumId?, startMs?, durationMs?, rippedAt,
                   bpm?, musicalKey?, camelot?, waveform?, analyzed? }

 JobView { jobId, songId, phase:RipPhase, message?, url?, error?,
           streamUrl?(/hls/<id>/index.m3u8), progress?{elapsedMs,totalMs,pct,indeterminate} }
   RipPhase = queued | searching | ripping | streaming | uploading | ready | error
```

**Reading the diagram.** `manifest.json` is keyed by `songId` → a `ManifestEntry`:
where the audio lives (`key`), how it was made (`source`), the auto-seek
`startMs`/`durationMs`, and background analysis (`bpm`/`musicalKey`/`camelot`/
`waveform`/`analyzed`). `JobView` is the client-facing job projection: `phase` (the
`RipPhase` enum), an optional `streamUrl` once live HLS is ready, and `progress`
(definite for a real-time digital capture, `indeterminate` otherwise).

**Folding analysis back into the UI.** The per-rip analysis lives in the **manifest**,
not the catalog index. The native app's shared `SongRowView` therefore OVERLAYS a
manifest entry's analyzed `bpm`/`musicalKey`/`camelot` onto the catalog index values
([`apple/PocketDJ/Views/CollectionSongRow.swift`](../../apple/PocketDJ/Views/CollectionSongRow.swift)),
so a freshly-ripped song's row shows its computed tempo/key even when the index had
none. Analog rips leave those fields nil (the whole album plays from one file) and the
row keeps the catalog values.

---

## 6. Client playback features built on this

- **Mini player** — `useRipsStore` docks a player with ⏮/⏭, auto-seek to a track's
  `startMs` within a whole-album rip, and a **waveform scrub bar** (lazy-loaded PNG).
- **iOS unlock** — `primeAudio()` plays a tiny silent clip inside the tap gesture so a
  later-resolved live URL can play (iOS autoplay rule).
- **Setlist actions** — `playQueue` (rip-ahead so the next track is ready before the
  current ends), `ripAll` (parallel pre-rip), `burn` (rip any missing, then download
  the set as one zip). These operate on a setlist's tracks (Ch. 4).
- **`burn-setlist` skill** — server-side counterpart: carves each song out of its raw
  vinyl rip by `pointer.startMs/endMs` (Ch. 2) into mix-ready files + metadata
  sidecars.

---

## 7. The native inline player — `PlayerEngine` · `PlayerClock` · TimelineView

**Why.** The web client docks a single *mini-player* at the bottom. The native
iOS/Mac app wanted the player **inline, right under the row you played** — on the
Browser song list **and** an album's track table — so the playing track keeps its
place in context. That means many potential player slots in a long, recycling list,
and a position readout that ticks ~4×/s while sibling control buttons must stay
tappable. The design that makes that work is small but load-bearing.

**Source of truth:**
[`apple/PocketDJ/Playback/PlayerEngine.swift`](../../apple/PocketDJ/Playback/PlayerEngine.swift),
[`apple/PocketDJ/Views/CollectionSongRow.swift`](../../apple/PocketDJ/Views/CollectionSongRow.swift)
(`RowTransport` · `InlinePlayerSlot` · `InlinePlayerPanel` · `InlinePlayerExpanded` ·
`WaveformView`),
[`apple/PocketDJ/State/RipsStore.swift`](../../apple/PocketDJ/State/RipsStore.swift)
(`nowPlaying` + `play()`),
[`apple/PocketDJ/Views/AlbumDetailView.swift`](../../apple/PocketDJ/Views/AlbumDetailView.swift)
(album-row transport + slot).

```
 row ▶ tap (RowTransport.doPlay)
   │  isNowPlaying? ── yes ──▶ player.toggle()          (no re-rip)
   ▼  no
 let now = await rips.play(song, startMs:)   ── sets RipsStore.nowPlaying = NowPlaying{songId,url,live,startMs,title,artist,waveform}
   │                                            (@discardableResult → returns the NowPlaying)
   ▼
 player.load(url:live:startMs:title:artist:)  ── the ONE-AND-ONLY engine load (the panel never loads it)
   │
   ▼
 InlinePlayerSlot(songId)  ── shown only where rips.nowPlaying?.songId == songId
   └─ InlinePlayerPanel
        ├─ header: player-toggle · title/artist · player-chevron · player-close · ● live
        └─ InlinePlayerExpanded            (own subview → isolates the 4×/s churn)
             ├─ WaveformView (edge-to-edge, loaded once via URLSession)
             └─ scrubber: TimelineView(.periodic 0.25s) SAMPLES player.clock.currentTime
                          Slider(0...player.duration) → player.seek(to:) on edit-end
```

**Reading the diagram.** A row's **`RowTransport`** ▶ either toggles the engine (if
this row is already now-playing) or starts a fresh play: it awaits
**`RipsStore.play(song,startMs:)`**, which resolves the playable URL (cache hit, live
HLS, or rip-then-play per §3), sets `RipsStore.nowPlaying`, and — now
**`@discardableResult`** — *returns* that `NowPlaying`. The caller then calls
**`player.load(...)` exactly once**, from this explicit tap. This single-owner rule is
deliberate: the **panel never loads the engine**, because `InlinePlayerSlot` recycles
inside the `LazyVStack` and a load in its lifecycle would auto-play on a re-render or
stomp a user's pause. **`InlinePlayerSlot(songId:)`** renders the panel only where
`rips.nowPlaying?.songId == songId`, so exactly one row in the whole list shows it.

**`PlayerEngine`** ([`PlayerEngine.swift`](../../apple/PocketDJ/Playback/PlayerEngine.swift))
is a thin `@MainActor @Observable` wrapper over one **`AVPlayer`** — which plays HLS
(`.m3u8`) **and** mp3 natively, so no third-party HLS library is needed on Apple
platforms. `load(url:live:startMs:…)` swaps the item; a non-live (analog) item seeks to
`startMs` once it reports a usable duration; a live HLS item starts immediately and
never seeks (no static duration). It also wires **`MPNowPlayingInfoCenter` +
`MPRemoteCommandCenter`** so the lock screen / Control Center / AirPods / CarPlay drive
play / pause / scrub, and configures the `.playback` audio session so audio continues
in the background (the `UIBackgroundModes: [audio]` capability, Ch. 7).

**The `PlayerClock` / TimelineView trick (the load-bearing part).** The playback
position ticks ~4×/s (a `addPeriodicTimeObserver` at 0.25 s). If that tick lived on the
`@Observable` engine, every update would invalidate the inline panel — re-laying-out
its control buttons and **dropping in-flight clicks** on play/pause · chevron · ✕ (the
"dead slide-out buttons" bug, proven by a UI-test toggle-count probe). So the fast
position lives on a separate, **deliberately non-`@Observable`** `PlayerClock`
(`engine.clock.currentTime`): reading it registers no Observation dependency, so a tick
invalidates nothing. The scrubber instead **samples** the clock on a
`TimelineView(.periodic(by: 0.25))` schedule — which redraws *its own* content without
touching Observation — so the sibling buttons keep their identity. **Duration** *is*
observable on the engine (it changes once per track and the slider's range must react).
The same churn-isolation discipline drives three more choices in
[`CollectionSongRow.swift`](../../apple/PocketDJ/Views/CollectionSongRow.swift):
`InlinePlayerExpanded` is its own subview (so the tick re-renders only it, not the
header buttons); `WaveformView` loads its PNG **once** via `URLSession` into one
`@State` rather than using `AsyncImage` (whose phase churn dropped sibling clicks); and
the panel border is drawn with **`.allowsHitTesting(false)`** so the shape overlay
doesn't swallow taps to the controls beneath it. The waveform is a fixed-height,
edge-to-edge `.background` so it lines up with the full-width scrubber and never
resizes the panel. (For a **live** stream there's no scrubber — `InlinePlayerExpanded`
shows a *"Streaming live as it rips"* state and a `● live` badge instead, since a live
HLS playlist has no fixed length.)

**Album rows reuse all of this.**
[`AlbumDetailView.swift`](../../apple/PocketDJ/Views/AlbumDetailView.swift)'s `TrackRow`
ends with the same `RowTransport`, and each track's `NavigationLink` is followed by an
`InlinePlayerSlot(songId:)` — so the identical inline player appears below an album
track, not just a browser row. **Download** (`RowTransport` ⤓) resolves the durable mp3
bytes via `rips.downloadData(_:)` — which runs the same `ensureURL(allowLive: false)`
resolution (cached S3 mp3, else rip-on-demand wait, driving the row's live rip-phase
label) and returns the raw `Data` — then wraps them in a `RippedAudioFile: FileDocument`
(an mp3 `UTType`) and presents a SwiftUI **`.fileExporter`** so the user picks the save
location: an **`NSSavePanel`** on macOS, the document picker in export mode on iOS/iPadOS,
defaulted to an `Artist - Title` filename (`RipsStore.downloadBaseName`; the exporter
appends `.mp3`). The OS writes the file to the chosen destination; cancel + export errors
reset the button (errors surface in the row's alert). `rips.download(_:)` — the older
"write to Documents" path — remains, layered on `downloadData`, but the row no longer
uses it (no more Documents-then-share).

## Next

→ [Chapter 6 — Search & Discovery](./06-search-and-discovery.md)
