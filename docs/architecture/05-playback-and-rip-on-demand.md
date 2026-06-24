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
| `POST /rip-collection` `{songIds[]}` | batch-enqueue a whole collection (reuses the durable queue) | `{ results:[{songId,status,jobId,url}], counts }` |
| `POST /rip-cancel` `{songIds[]}` | cancel queued matching jobs + kill the in-flight capture child (§2.1) | `{ results:[{songId,status}], counts }` (`status ∈ canceled\|notFound\|alreadyDone`) |
| `GET /jobs/:id` | poll a job | `JobView` |
| `GET /hls/<songId>/index.m3u8` · `…/seg_N.ts` | live HLS (iOS-native) | playlist / TS segment |
| `GET /stream/<songId>.mp3` | live progressive mp3 (tail) | chunked `audio/mpeg` |
| `POST /analysis` `{songId,bpm,…}` | external analysis submit | `{ ok, songId }` |

Auth is an **optional** bearer token (`RIP_TOKEN`): all gated routes go through one
shared `authed()` check that is **permissive (public) when no token is configured** — so
during development the server runs **tokenless / public** for frictionless integration
testing. `/rip` and `/rip-collection` sit below the *same* gate, so they are public (or
gated) **identically**; there is no `/rip-collection`-specific fail-closed branch. Media
paths (`/hls`, `/stream`) also accept `?token=` because a native `<audio>` can't set an
Authorization header. `version` is `RIP_PROTOCOL = 2`; the client
(`EXPECTED_RIP_VERSION = 2`, `RipServerService.expectedVersion = 2`) shows an
"outdated — restart it" banner if a reachable server reports `< 2`.

**`POST /rip-collection` — batch rip a whole collection.** A thin batch wrapper over the
same `acceptRip(songId)` helper `/rip` uses, so it reuses the durable per-`songId` queue,
single-flight dedup, concurrency-1 worker, and S3 upload **verbatim** — no second queue.
The body is `{ songIds: [...] }` (deduped server-side, empty allowed, **no length cap** —
it is async and the queue scales out). The response is `{ results, counts }`: one
`{ songId, status, jobId, url }` per id where `status ∈ ready|queued|inflight|unknown`
(already-cached → `ready`+`url`; new job → `queued`; joined an in-flight `resourceKey`
→ `inflight`; not in catalog → `unknown`), plus a `counts` rollup. For an analog album
with several selected songs the *leader* creates one durable queue file (`resourceKey =
albumId`) and siblings report `inflight`, resolving via the manifest when the album rip
completes. Re-POSTing a collection is a no-op for already-ripped / in-flight songs. The
native app ([`RipsStore.ripCollection`](../../apple/PocketDJ/State/RipsStore.swift)) calls
it and **falls back to a per-song `/rip` loop** if the server `404`s the path (older
build); it classifies each fallback result by the song's actual job phase so the counts
line up with the batch path's vocabulary.

### 2.1 `POST /rip-cancel` — STOP a rip + kill the capture worker

**Why.** A cloud rip is **real-time** (a 4-minute song takes ~4 minutes of Audio Hijack
capture; Ch. 8), and a whole-collection Rip serializes at concurrency-1, so a user who
fired a large set needs a **Stop**. `POST /rip-cancel {songIds:[...]}` cancels every
matching job and is **idempotent** — re-sending or canceling an already-finished song is
a clean no-op. The native [`RipsStore.cancelCollection`](../../apple/PocketDJ/State/RipsStore.swift)
calls it from the collection **Stop** button (Ch. 5 §9 / storybook §33); an older server
that 404s the path is a silent no-op.

```
 cancelOne(songId, canceledAlbums):
   manifest[songId]?           → 'alreadyDone'   (already ripped — nothing to cancel)
   resolve inflight job by BOTH candidate keys: [songId, albumId]   (digital/cloud · analog)
   no job                      → 'notFound'
   job is the RUNNING one (activeJobId == jobId):
        job.canceled = true
        phase=='uploading' → DON'T kill (aws s3 cp + saveManifest are idempotent; let finish)
        else activeChild.p → process.kill(-pid, SIGKILL)   (GROUP kill: reaps rip-one,
                                                             tail, HLS ffmpeg grandchildren)
   job is QUEUED → splice from queue + inflight.delete + clearQueue + phase='error'(canceled)
   → 'canceled'   (analog album: remember albumId so batch siblings also report 'canceled')
```

**Reading the diagram.** Cancellation hinges on two pieces of pump() state:
**`activeJobId`** is set the instant a job leaves the queue (**before** spawn, closing the
shift→spawn race — a cancel landing in that gap flips `job.canceled` and the **pre-spawn
guard** in `runJob` short-circuits to `fail`), and **`activeChild.p`** is the in-flight
**capture** child (`rip-one.mjs` / the analog `ffmpeg`) — the *only* process cancel ever
kills. The capture children are `spawn`ed **detached** (own process group) so a single
`process.kill(-pid, SIGKILL)` reaps the worker **and** its grandchildren (the rip skill, the
stream tail, the HLS ffmpeg). Cancel **refuses the kill mid-`uploading`** — the `aws s3 cp`
and `saveManifest` are idempotent and must finish — and a **canceled mid-capture analog
cloud rip does NOT Tier-2-fall-back to vinyl** (cancel means *stop*, not *try the other
path*). Because one analog job covers a whole album, the handler resolves **album-first**:
canceling any sibling removes the shared `albumId` inflight entry, so it records the
`albumId` in `canceledAlbums` and fills `'canceled'` for the batch's other album songs that
would otherwise miss their own lookup. Terminal cleanup is per-branch — a queued cancel does
its own `inflight.delete`; a running cancel lets the job's terminal `canceled`-guard call
`fail()` (which deletes inflight), then `pump()` drains the next queued job.

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
ripped-but-unanalyzed entries on boot. The durable record also carries the retry
**`attempt`** count (§3.1) so a restart preserves the self-heal budget.

### 3.1 Queue self-heal — per-job watchdog + transient backoff retry

**Why.** The queue is **concurrency-1** and capture is **real-time**: a single capture
that *hangs* (Music.app / Audio Hijack wedged, an ffmpeg that never closes) would leave
`working` true forever and **freeze the whole queue** behind it, and a *transient* blip
(a vinyl drive unmounted for a moment, a network hiccup) would permanently fail a job
that a retry seconds later would sail through. The self-heal layer in
[`scripts/rip-server.mjs`](../../scripts/rip-server.mjs) (the `SELFHEAL` config +
`pump()` race + `scheduleRetry()`) makes one stuck or flaky job **unable to wedge the
queue** and lets a remounted drive **self-heal**. End-to-end test:
[`scripts/test/rip-selfheal-e2e.mjs`](../../scripts/test/rip-selfheal-e2e.mjs)
(`RIP_TEST_*` env vars shrink the timeouts/backoff so a hang→retry cycle runs in
seconds).

```
 pump(): shift job → activeJobId set → Promise.race([ runJob(job), watchdog(deadline) ])
   │
   ├─ runJob wins → job sets its OWN terminal phase (ready | error)
   └─ watchdog wins (deadline elapsed):
        group-kill activeChild.p (process.kill(-pid, SIGKILL) — same kill /rip-cancel uses)
        reject('watchdog timeout') → job fail()s

 jobDeadlineMs(job, song):
   analog (sourceType==='analog' && !preferCloud) → analogCapMs               = 12 min (fixed)
   digital / cloud                                → clamp( (song.length||6min)*1.5 + 90s,
                                                            floor 90s … ceil 30min )

 on terminal error → retryable = phase==='error' && !canceled
                                  && isTransient(job,msg) && attempt < maxAttempts(5)
   isTransient:  /unknown songId/ → false (PERMANENT)
                 /no analog file reference/ → false (PERMANENT)
                 canceled → false
                 else (analog source missing, aws/s3/network, watchdog timeout,
                       spawn/exit, generic capture failure) → TRUE
   retryable → scheduleRetry(): bump attempt, KEEP resourceKey inflight across the gap,
               re-persist the durable queue record, setTimeout(backoffMs[attempt-1]) → enqueue
               backoffMs = [30s, 2m, 8m, 8m]   (index by attempt-1, clamped to last)
   not retryable → terminal 'error' (gave-up logged), pump() drains the next job
```

**Reading the diagram.** `pump()` sets **`activeJobId`** the instant a job leaves the
queue (before spawn — the same pre-spawn cancel guard §2.1 relies on), then
**`Promise.race`s** the real `runJob` against a **duration-aware watchdog**. The
**deadline** is computed per job by `jobDeadlineMs`: an analog ffmpeg transcode (fast,
not real-time) gets a generous **fixed 12-minute** cap; a digital/cloud **real-time**
capture gets `song.length × 1.5 + 90s` (the 90s buffers spawn/seek/upload slack),
**clamped to a 90s floor** (never kill a legitimate short capture early) and a **30-min
ceiling** (no single track legitimately runs that long; an unknown length assumes a
6-min song). If the watchdog wins the race it **group-kills** the in-flight capture
child with the *same* `process.kill(-pid, SIGKILL)` `/rip-cancel` uses (§2.1 — the
detached process group reaps the worker and its grandchildren) and rejects with
`watchdog timeout`, so the job `fail()`s and `pump()` advances. On any terminal error
the server classifies it via **`isTransient`**: an *unknown song* or *no analog file
reference* is **permanent** (and a cancel is never a retry), so it stays failed;
**everything else** — a missing analog drive/file, an aws/network error, the watchdog
timeout, a spawn/exit failure — is **transient** and, within the `maxAttempts` (5)
budget, **`scheduleRetry()`** bumps the `attempt`, **keeps the `resourceKey` marked
inflight across the backoff gap** (so single-flight holds and a duplicate `/rip` still
joins), re-persists the durable queue record with the bumped attempt, and `setTimeout`s
a re-`enqueue` after a **capped exponential backoff** (`[30s, 2m, 8m, 8m]`, indexed by
`attempt-1` and clamped to the last). Crucially the retry is scheduled **without holding
the worker** — `pump()` is free to run the next queued song during the backoff window —
so one flaky job can't starve the rest. A cancel landing in the backoff window
supersedes the pending retry (the timer checks `job.canceled` + that the `resourceKey`
still points at it). Because the bumped `attempt` rides the durable per-`songId` queue
record (§3), a **server restart mid-backoff preserves the remaining retry budget**.

### 3.2 Analog source config — `POCKETDJ_ANALOG_BASE` + removable-volume TCC

**Why.** The analog (vinyl) path resolves the raw album file at
`${analogBase}/<album.pointer.originalFilename>` — e.g. `SWVNewBeginningsRaw.mp3`
(the `…Raw` filename Ch. 2 indexes from). `analogBase` is
`process.env.POCKETDJ_ANALOG_BASE` (tilde-expanded) and **defaults to `~/Downloads`**
when unset. On Levi's iMac the raw rips do **not** live in `~/Downloads` — they're on
an **external drive, `/Volumes/RipBurnMix`** — so an unset base makes
`runAnalogJob`'s `existsSync(src)` miss and **every analog rip fail** `analog file not
found: …` (now a *transient* failure, §3.1, so it backs off and retries — letting a
remounted drive self-heal, but never succeeding while the base is wrong).

So the launchd agent
([`scripts/launchd/com.pocketdj.ripserver.plist`](../../scripts/launchd/com.pocketdj.ripserver.plist))
sets, under `EnvironmentVariables`:

```
 POCKETDJ_ANALOG_BASE = /Volumes/RipBurnMix
```

Two operational gotchas come with reading an external volume from a launchd-spawned
node:

- **Removable-volume TCC.** macOS gates `/Volumes/*` behind the **Files & Folders /
  removable-volume** privacy permission. `node` (the binary launchd runs) must be
  granted *Removable Volumes* access (System Settings ▸ Privacy & Security ▸ Files and
  Folders) or `existsSync`/`ffmpeg` read fails even with the base set correctly.
- **`originalFilename` resolution.** The rip uses the album's
  `pointer.originalFilename` verbatim (`join(analogBase, originalFilename)`), so the
  filename in the index must match the on-disk name exactly; a missing
  `pointer.originalFilename` is the **permanent** `no analog file reference` failure
  (never retried, §3.1).

`GET /health` echoes the resolved `analogBase` (and the boot log prints it) so a
mis-set base is visible without reading the source. This config is also carried in the
foundations capability table (Ch. 1) and the launchd-agent note (Ch. 7 §6).

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
`startMs`/`durationMs`, a **`rippedAt`** epoch-ms completion stamp, and background
analysis (`bpm`/`musicalKey`/`camelot`/`waveform`/`analyzed`). `JobView` is the
client-facing job projection: `phase` (the `RipPhase` enum), an optional `streamUrl`
once live HLS is ready, and `progress` (definite for a real-time digital capture,
`indeterminate` otherwise).

**`rippedAt` — the freshness stamp for offline burns.** The server writes `rippedAt =
Date.now()` into the manifest entry whenever a rip completes and uploads (analog album
completion shares one stamp across all the album's songs; digital/skill completion stamps
after the S3 upload; `POST /analysis` stamps a freshly-minted entry). It is a **plain
optional field** — older entries that predate it still load. The native offline-burn
store (§9) uses it as a staleness signal: a downloaded burn is treated as stale and
re-downloaded when its source entry's `rippedAt` is newer than when the burn was last
downloaded, catching re-rips and analysis-overlay bpm/key updates beyond the size check.

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
play / pause / scrub — **and next / previous, which advance a running setlist while
locked** (§11.3) — and configures the `.playback` audio session so audio continues in the
background (the `UIBackgroundModes` capability, Ch. 7 §6).

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

---

## 8. Stream-first, rip-last — the native provider chain (`PlaybackCoordinator`)

**Why.** Ripping is the *universal* fallback — it makes any song audible — but it's
expensive (a real-time Apple Music capture + upload) and a poor first choice when the
user already has an **Apple Music subscription** that can stream the catalog track
instantly. So the native ▶ tries a real Apple Music **stream first** and only rips when
that can't resolve. (Vinyl never streams — it has no catalog id — so it goes straight to
the rip path.)

**Source of truth:**
[`apple/PocketDJ/Playback/PlaybackCoordinator.swift`](../../apple/PocketDJ/Playback/PlaybackCoordinator.swift)
(the ordering engine),
[`apple/PocketDJ/Playback/AppleMusicPlaybackProvider.swift`](../../apple/PocketDJ/Playback/AppleMusicPlaybackProvider.swift)
(the streaming `TrackPlaybackProvider`),
[`apple/PocketDJ/Services/Streaming/AppleMusicProvider.swift`](../../apple/PocketDJ/Services/Streaming/AppleMusicProvider.swift)
(`resolve(_:)`, the catalog matcher),
[`apple/PocketDJ/Playback/RipServerPlaybackProvider.swift`](../../apple/PocketDJ/Playback/RipServerPlaybackProvider.swift)
(the terminal rip fallback, §1–§7).

```
 row ▶ tap → PlaybackCoordinator.play(song)
   │  providers(for: song):    // SOURCE-AWARE order
   │    sourceOfSong(id) == "Apple Music (Local)" && appleMusic.isReady ?
   │        → [AppleMusic, ripServer]   else → [ripServer]
   ▼  try each until one returns true (becomes activeBackend)
 ┌──────────────────────────────────────────────────────────────────────┐
 │ AppleMusicPlaybackProvider.tryPlay → AppleMusicProvider.resolve(song): │
 │   1) song.appleMusicId  → fetchRow(storeID:)  ── VERIFY via real       │
 │        (the index CATALOG stage, Ch.3 §1.1)      MusicCatalogResource- │
 │   2) am:<storeID> id    → fetchRow(storeID:)     Request; a hit IS the │
 │   3) "title artist"     → catalog search(top 1)  verification          │
 │   hit → MusicItemID → ApplicationMusicPlayer.play()  ⇒ true (WIN)      │
 │   all miss / playback throws (no subscription) → false                 │
 └────────────────────────────────┬─────────────────────────────────────┘
                                   ▼  false → fall through (graceful degrade)
                       RipServerPlaybackProvider.tryPlay  (rip-on-demand, §3 — ALWAYS last)
```

**Reading the diagram.** `PlaybackCoordinator.providers(for:)` builds a **source-aware**
ordered list: for a song whose origin source is `Config.appleMusicSourceName`
("Apple Music (Local)") and when `appleMusic.isReady` (enabled + MusicKit-authorized),
it puts the Apple Music streaming provider **first**; the rip server is **always
appended last** as the terminal fallback, so any song still plays. `play()` cycles the
list, calling `tryPlay` on each until one returns `true` (recorded as `activeBackend`,
which drives the inline player's branch + the "via …" badge); switching backends stops
the previously-active one so two engines never play at once.

**The fix this chapter's branch lands.** `AppleMusicProvider.resolve(_:)` now tries the
index's **`appleMusicId`** (Ch. 3 §1.1) **first** — `fetchRow(storeID:candidate)`. The
key point: that resolved id is a *candidate* from the iTunes Search API, never trusted
blindly — the `fetchRow` issues a real `MusicCatalogResourceRequest`, so **a hit is the
verification**. On a miss (wrong id, region gating, removed track) it falls to (2) the
own-namespaced `am:<storeID>` id, then (3) a top-result title/artist search, and finally
returns `nil` → `tryPlay` returns `false` → the coordinator **degrades to the rip
provider** (unchanged). Before this branch, Apple Music (Local) songs — whose ids are
shaped `sng_…` (which step 2 can't decode) — *always* missed resolution and *always*
fell through to a rip; with the `appleMusicId` candidate they now stream via Apple Music
in the common case. (This is the same degradation the storybook §29 "Play" describes.)

**Stream-through-rip — capture for offline while the stream plays.** Streaming an Apple
Music track plays it *now* but leaves nothing on the public S3 cache for later (offline,
or another device). So when the Apple Music provider **wins** a play, the coordinator
fires **one fire-and-forget rip** — `Task { await ripProvider.requestAsyncRip(song.id) }`
right after `activeBackend = .appleMusic`, **before `return`** — so the track is silently
captured to S3 in the background. It is a plain `Task` (not `Task.detached`): the await
chain that started playback has already completed, so this adds **zero playback latency**,
and playback is **never** blocked or failed by the rip. `requestAsyncRip` delegates to
[`RipsStore.requestRipIfNeeded`](../../apple/PocketDJ/State/RipsStore.swift), whose
idempotency is three-layered: (1) a cheap `@MainActor` guard returns early if the song is
already cached or has a live job; (2) a **synchronous `requesting` Set** insert *before*
the first `await` closes the guard race so it is single-flight per process; (3) the
server's manifest-skip + `inflight` join make it exact-once across restarts / devices.
The method **never throws** to the caller. Vinyl never streams, so this only fires on the
Apple-Music-won path; the resulting rip is the same durable mp3 every later play (and
every Burn, §9) reads.

---

## 9. Collection Rip + Burn — the offline local store (`BurnStore`)

**Why.** §1–§8 make a song audible *while connected to the rip server / S3*. To carry a
whole **set** (a playlist, pocket, setlist, or source) into a room with no signal, two
collection-level verbs are needed: **Rip** the whole collection (server-side capture to
S3) and **Burn** it (download the ripped audio + a mixer-readable sidecar to the device).
These are deliberately split: **Rip** is server-only and never blocks; **Burn** only
downloads songs that are *already ripped* and never blocks on a live capture.

**Source of truth:**
[`apple/PocketDJ/State/RipsStore.swift`](../../apple/PocketDJ/State/RipsStore.swift)
(`ripCollection`, `cancelCollection`, `downloadDataIfCached`, `burnsDirectory`),
[`apple/PocketDJ/State/BurnStore.swift`](../../apple/PocketDJ/State/BurnStore.swift)
(the download queue + local index + `requestStop` + the security-scoped folder
resolution),
[`apple/PocketDJ/Views/SettingsView.swift`](../../apple/PocketDJ/Views/SettingsView.swift)
(`burnFolderSection`, the folder picker) +
[`apple/PocketDJ/Settings/SettingsStore.swift`](../../apple/PocketDJ/Settings/SettingsStore.swift)
(`burnFolderBookmark`),
[`apple/PocketDJ/State/CollectionsStore.swift`](../../apple/PocketDJ/State/CollectionsStore.swift)
(`songIds(forPlaylist/forPocket/forSetlist/forSource)` + `burnTuples` resolvers),
[`apple/PocketDJ/Views/CollectionRipBurn.swift`](../../apple/PocketDJ/Views/CollectionRipBurn.swift)
(the shared Rip/Burn buttons + controller, storybook §33).

**Rip (collection).** `RipsStore.ripCollection(songIds)` dedupes and `POST`s
`/rip-collection` (§2), updating `jobs[…]` for `queued`/`inflight` results and returning
the per-song counts for a partial-success summary. If the server `404`s the path it falls
back to looping `requestRipIfNeeded` per song and **classifies each by the song's actual
job phase** (ready/queued/inflight/unknown) so the synthesized counts match the batch
vocabulary. No local download happens — Rip is purely "send the set to be recorded."

**Burn (collection) — `BurnStore`.** An `@Observable @MainActor` store mirroring the
durable-JSON pattern (`pocketdj-burns.json` in Application Support, atomic write,
decode-on-init, `PDJ_USE_FIXTURE` test seam). It runs a **serial, one-by-one download
queue keyed by `songId`**, downloading **only already-ripped songs** via the new
`RipsStore.downloadDataIfCached` — which returns `nil` (rather than rip-on-demand-blocking
like `downloadData`) when the song isn't cached. Per song:

```
 burn(songs, lookup):  for each song, sequentially —
   isFresh? (state==.ready ∧ file exists ∧ size==bytes ∧ manifest.rippedAt ≤ downloadedAt) → skip
   cachedURL == nil → record "not ripped — Rip first" → continue   (NEVER ensureURL)
   downloadDataIfCached → (data, ManifestEntry)
   analog → <albumId>.mp3 (one shared file/album, reuse if a sibling wrote it; seek by startMs)
   digital → <songId>.mp3
   write <songId>.txt sidecar (BPM · Key+Camelot · Sentiment · Album + metadata + raw JSON)
   record BurnItem{ audio/sidecar names, bpm/key/camelot/durationMs/startMs, bytes,
                    rippedAt(from entry), downloadedAt(now), state:.ready }  → save()
```

**Freshness — `isFresh(_:dir:rippedAt:)`.** A burn is reused only when its file still
exists **and** its size matches the recorded `bytes` **and** the manifest entry's
`rippedAt` is **not newer** than the burn's `downloadedAt`. A newer `rippedAt`
(re-rip, or an analysis overlay updating bpm/key) ⇒ stale ⇒ re-download; a legacy entry
with no `rippedAt` degrades to the size-only check. Edge handling: per-item `do/catch`
isolates partial success (one bad song doesn't abort the set); an
`NSFileWriteOutOfSpaceError` early-aborts the rest with a single "out of space" summary;
an empty collection is a no-op; with no rip server it still burns the cached songs and
reports the rest as "not ripped".

**The offline-ready local store.** `pocketdj-burns.json` is the **machine-readable
catalog of offline-available tracks** a future offline player / live-mixer enumerates —
each `BurnItem` carries the analyzed `bpm`/`musicalKey`/`camelot`/`durationMs` and, for
analog, the `startMs` seek offset into the shared per-album mp3. `localURL(forSong:)`
existence-checks before returning a URL (so a purged file degrades gracefully),
`reconcileOnLaunch()` prunes items whose audio vanished, and `remove(_:)` + `totalBytes`
make the layout eviction-ready. Offline playback and live mixing themselves are
**deferred** — this is the storage layout + seams those will consume, feeding
`PlayerEngine.load(url:live:startMs:title:artist:)` (§7), which already accepts any local
URL + `startMs`. The human-readable `<songId>.txt` sidecar mirrors the `burn-setlist`
skill's format (§6) as a companion; the JSON index, not the prose, is the source of truth.

**The user-browsable burnt-music folder (security-scoped bookmark).** By default burns
write to the app-private Application Support `burns/` dir. A **Settings ▸ Choose
burnt-music folder** picker (`SettingsView.burnFolderSection`) lets the user save them to a
folder they can browse in Finder/Files instead: one cross-platform `.fileImporter([.folder])`
presents an `NSOpenPanel` on macOS and the directory document picker on iOS. The picked
URL is **security-scoped**, so the store persists a **bookmark** (`makeBookmark` —
`.withSecurityScope` on macOS, plain on iOS) in `SettingsStore.burnFolderBookmark` rather
than a raw path. Each `BurnItem` records **`appStorage: Bool`** so a later folder switch
never mis-resolves or prunes an item against the wrong dir: `resolveBurnFolder` resolves the
bookmark (re-persisting a stale one only on the **write** path), brackets scoped access
around the whole `burn(...)` loop, and **falls back to app storage on any problem** (denied,
unmounted, not writable). `localURL`/`remove`/`reconcileOnLaunch` resolve each item via
`itemDir(_:)` read-only and **skip** (never prune) an item whose user folder is currently
unmounted — no data destruction from an ejected drive.

**Stop a burn (Feature 1).** The same collection **Stop** that cancels a server rip
(§2.1) also stops a burn: `BurnStore.requestStop()` sets a `stopRequested` flag the serial
`burn(...)` loop checks between items, so **already-downloaded files are kept** and the rest
are simply not attempted (`BurnResult.stopped`). The view's controller routes the one Stop
button to the right path — cancel the app-side burn `Task` for a burn, `POST /rip-cancel`
for a rip — by tracking which long-running op is in flight.

### 9.1 Persistent collection-RIP Stop + live progress (the `CollectionRipBurnController` poll)

**Why.** A **burn** runs *in-app*: its `burn(...)` Task lives for the whole download, so
`working` stays true and the Stop button is naturally visible the entire time. A
**collection RIP** is different — `ripCollection` only **enqueues** (the `/rip-collection`
POST returns in ~1–2s), and the actual capture happens **server-side, real-time,
concurrency-1, over minutes-to-hours**. With the old logic, Stop was tied to `working`, so
it vanished the instant the enqueue POST returned — leaving the user **no way to cancel** a
long-running set rip they'd just started, and **no progress** for it. The
[`CollectionRipBurnController`](../../apple/PocketDJ/Views/CollectionRipBurn.swift) now
drives a **manifest poll** that keeps a Stop + a live "X of N ripped" indicator visible
until the server finishes the queue.

```
 rip(ids):  working=true → ripCollection(ids) (enqueue) → working=false
   pending = queued+inflight > 0 ?  → startRipPoll(ids)
                                                 │
   startRipPoll:  ripInProgress = true; capture lastRipIds = ids
     loop (≤ ripPollMaxTicks ≈ 1600 @ 4.5s = ~2h cap):
        sleep(ripPollIntervalMs)  → rips.refreshManifest()
        done = ids.count { rips.cachedURL(id) != nil }
        ripProgress = "ripping — \(done) of \(total) done"
        done == total → finishRipPoll() (ripInProgress=false, "Ripped N of N")
   STOP (visible while working || ripInProgress):
        inFlightOp==.burn → burns.requestStop() + burnTask.cancel()
        else (rip)        → clearRipProgress() + cancelCollection(lastRipIds)  (POST /rip-cancel)
```

**Reading the diagram.** After `ripCollection` enqueues, if anything is still
`queued`/`inflight` the controller starts **`startRipPoll`**: it flips
**`ripInProgress`** true (the buttons view shows Stop while `working || ripInProgress`,
and the screen-level overlay shows a persistent **"ripping — X of N done"** capsule with
its own Stop **outside the Menu**, since a Menu dismisses its content on selection), then
loops on a cancellable Task — every `ripPollIntervalMs` (~4.5s) it `refreshManifest()`s
the **public S3 manifest** and counts how many of the captured `lastRipIds` now have a
`cachedURL`, driving `ripProgress` + the result summary. It stops when all are ripped
(`finishRipPoll`), on Stop, or after a generous **safety cap** (`ripPollMaxTicks` ≈ 1600
ticks ≈ 2h) so the poll Task **never leaks or polls forever** (a real-time concurrency-1
rip can be slow, but a leaked Task is worse than ending the *indicator* early — a manual
Refresh still reconciles). **Stop** routes on the in-flight op: a burn signals the
`BurnStore` loop + cancels the app-side Task (§9); a rip — whether still enqueuing
(`inFlightOp == .rip`) **or** already enqueued and polling (`inFlightOp == nil` but
`ripInProgress`) — tears down the poll and `cancelCollection(lastRipIds)` → **`POST
/rip-cancel`** (§2.1). It's idempotent: a second Stop after the ids are cleared cancels
nothing. (The burn's own progress capsule is unchanged; a third overlay branch reads the
background-transfer coordinator's `progressSnapshot` for the backgrounded-burn path, §11.)

---

## 10. Setlist PLAY — the `SetlistPlayer` sequencer (burnt-or-stream)

**Why.** A setlist is an ordered set; the DJ wants a single **Play** that runs it
top-to-bottom hands-free. `SetlistPlayer` is a thin sequencer that plays each track in
order, auto-advancing on end, and — crucially — chooses **burnt-local-file-if-present,
else stream** per track, so a partially-burnt set still plays end-to-end (offline tracks
from disk, the rest streamed).

**Source of truth:**
[`apple/PocketDJ/Playback/SetlistPlayer.swift`](../../apple/PocketDJ/Playback/SetlistPlayer.swift),
driven by the **Play/Stop** toolbar button in
[`apple/PocketDJ/Views/SetlistDetailView.swift`](../../apple/PocketDJ/Views/SetlistDetailView.swift)
(storybook §32).

```
 SetlistPlayer.play(items)  ── items = [{id,title,artist}] in setlist order
   index=0; player.onTrackEnded = handleEnded   (owns the hook only while running)
   ▼ playCurrent()  — resolves the SOURCE FRESH each track:
   burns.localURL(forSong: id) ≠ nil ?
        → set rips.nowPlaying + player.load(localURL, live:false, startMs:nil)   (BURNT)
        else → coordinator.play(id)   (Apple Music → rip fallback, §8)           (STREAM)
              coordinator.lastErrorMessage ≠ nil → advance NOW (dead source, no end event)
              player.isLive            → waitingForLive = true ("Next" affordance, no auto-end)
   ▼ handleEnded()  (player.onTrackEnded fires on a finite item)
   GUARD rips.nowPlaying?.songId == queue[index].id  → advance() ; index≥count → stop()
```

**Reading the diagram.** `play(items)` seeds the queue and takes ownership of the shared
`PlayerEngine.onTrackEnded` hook (released in `stop()`). `playCurrent()` re-resolves the
source **fresh each track** (a burnt file may have been purged since the queue was built):
a burnt local file drives the **same `PlayerEngine`** the inline player binds to (set
`nowPlaying`, then `load`), so the existing per-row `InlinePlayerSlot` (§7) lights up the
current track with **zero new player UI**; otherwise it streams via `PlaybackCoordinator`
(§8, Apple Music → rip fallback). Auto-advance rides the engine's finite-item end
notification, but with an **ownership guard** — `handleEnded` ignores a stray end from an
unrelated manual single-row play by checking `rips.nowPlaying?.songId == queue[index].id`.
Two edges keep it from freezing: a **dead source** (coordinator error, or a purged burnt
file) advances immediately since no end event will ever fire, and a **live HLS** capture
(no natural end) sets `waitingForLive` so the UI shows a manual **Next** instead of stalling.
Reaching the end tears down cleanly (releases the hook, clears now-playing) so the toolbar
flips back to **Play**.

---

## 11. Background processing — transfers + audio survive suspend/lock (native)

**Why.** §9–§10 burn/download/play **only while the app is foreground**. A foreground
`URLSession.shared.data(for:)` is killed the moment iOS suspends the app — so a Burn of a
large set, a single-song Download, or a Setlist Play would all **stall when the user locks
the phone or switches apps**. This branch makes rip-in reconcile, **burning, downloading,
AND setlist playback continue while backgrounded / suspended / locked** (iOS especially;
macOS compiles and relies on the background `URLSession` since it doesn't suspend the same
way). Four pieces cooperate: a background-`URLSession` **`TransferCoordinator`**, an
**`AppDelegate`** that bridges the system's relaunch callbacks + schedules BGTasks,
**background audio** Now-Playing/remote-commands, and the **capability/config** flips
(Ch. 7 §6).

**Source of truth:**
[`apple/PocketDJ/State/TransferCoordinator.swift`](../../apple/PocketDJ/State/TransferCoordinator.swift),
[`apple/PocketDJ/AppDelegate.swift`](../../apple/PocketDJ/AppDelegate.swift),
[`apple/PocketDJ/PocketDJApp.swift`](../../apple/PocketDJ/PocketDJApp.swift)
(`@UIApplicationDelegateAdaptor` / `@NSApplicationDelegateAdaptor` + the `.background`
scenePhase hook),
[`apple/PocketDJ/Playback/PlayerEngine.swift`](../../apple/PocketDJ/Playback/PlayerEngine.swift)
(MPNowPlayingInfoCenter + MPRemoteCommandCenter, including `next`/`previous`).

### 11.1 `TransferCoordinator` — one background URLSession + download-task delegate

```
 BurnStore.burn(songs) (coordinator injected, §9)
   beginRun() (reset run counters) → for each ALREADY-RIPPED song, on the @MainActor:
     CAPTURE at enqueue: sidecarText (pre-rendered), burnFolderBookmark Data,
                         wasAppStorage, manifest fields, title/artist
     enqueueDownload(url, token, TransferRecord)  ─┐
                                                    ▼
 TransferCoordinator (process-wide .shared, NSObject, NOT @MainActor)
   one URLSession.background(withIdentifier:"com.levi.pocketdj.transfers"),
       sessionSendsLaunchEvents=true
   persist record → pocketdj-transfers.json (ATOMIC, BEFORE task.resume())
   downloadTask(with:request).resume()    (survives suspend; resumes; finishes after relaunch)
        │  delegate callbacks arrive on a BACKGROUND queue (NSLock-guarded map)
        ▼
   urlSession(_:downloadTask:didFinishDownloadingTo:)   ── NONISOLATED, ZERO @MainActor access
     join taskIdentifier → TransferRecord (the cold-relaunch reconnect)
     resolveDestDir(record): wasAppStorage ? AppSupport/burns
                             : resolve record.burnFolderBookmark (the CAPTURED Data) + scope
                             (fall back to app storage if the user folder is gone — never drop)
     move temp → <dir>/<audioFileName>  (analog: reuse a sibling's shared <albumId>.mp3)
     write <sidecarFileName> from record.sidecarText
     remove record + persist + finishedTotal++ + publishProgress (main hop)
     DispatchQueue.main → onBurnFinalized(record, bytes)  → BurnStore upserts .ready BurnItem
```

**Reading the diagram.** `TransferCoordinator.shared` is a **single process-wide
`NSObject`** owning the one **background `URLSession`** (identifier
`com.levi.pocketdj.transfers`, `sessionSendsLaunchEvents = true`) and acting as its
`URLSessionDownloadDelegate`. A background session must be created **once per identifier
per process** and exist **at launch** (so a cold relaunch can finish in-flight files), and
its delegate callbacks arrive on a **background queue** — which is why the coordinator is
**deliberately not `@MainActor`**: it serializes its persisted map behind an `NSLock` and
hops to the main actor *only* to notify `BurnStore` of a finished/failed item.
`BurnStore.burn` (when a coordinator is injected — it's **optional**, `nil` ⇒ the original
in-process serial loop the tests use, byte-for-byte unchanged) hands each already-ripped
song to **`enqueueDownload`** as a background **download task**, which **survives
suspension, resumes, and finishes even after a cold background relaunch** — the whole
point. Each task's `TransferRecord` is **persisted atomically to `pocketdj-transfers.json`
BEFORE `task.resume()`** (a death between persist and resume is recoverable), and the
record's `taskIdentifier ⇄ songId ⇄ destination` join is the **only** thing that lets the
delegate finish a file after a cold relaunch (the delegate gets only the
`downloadTask.taskIdentifier`).

**The @MainActor-free delegate rule (the load-bearing constraint).** The download delegate
runs on a non-main queue with **no inherited security scope** and may run during a **cold
background relaunch when `BurnStore` doesn't even exist yet** — so it must touch **neither
the main actor nor any `@MainActor`-isolated state**. Everything it needs is therefore
**captured onto the `TransferRecord` at enqueue time (on the `@MainActor`)**: the
**pre-rendered sidecar text** (no catalog lookup in the delegate) and the **security-scoped
burn-folder bookmark `Data`** (so `resolveDestDir` re-resolves the user folder purely from
disk via `record.burnFolderBookmark` — never a `@MainActor` closure, with **no
`MainActor.assumeIsolated` off the main thread to trap**, the documented BLOCKER fix). The
delegate moves the temp file synchronously (it vanishes on return), reusing a sibling's
shared `<albumId>.mp3` for analog, falls back to app storage if the user folder is gone
(**never dropping the file**), writes the sidecar from the stored text, then makes the
**single** main hop to `onBurnFinalized` so `BurnStore` upserts the `.ready` `BurnItem`.
Stop (§9.1) calls `cancelAll(songIds:)` → cancels the in-flight background tasks + drops
their records; **`reconcileOnLaunch`** cross-checks persisted records against the session's
live tasks on foreground/launch and drops any whose task is gone. Live **progress** is read
by the UI **only** from the main-actor `progressSnapshot` (published via an explicit main
hop on every record change), never the `NSLock`-guarded delegate-queue counters — no
data-race-by-convention; the overlay's "Burning N of M" background-burn branch (§9.1) reads
exactly that snapshot.

### 11.2 `AppDelegate` — the completion bridge + BGTasks

SwiftUI can't express two things, so `PocketDJApp` adds an
`@UIApplicationDelegateAdaptor(AppDelegate.self)` (iOS) /
`@NSApplicationDelegateAdaptor(MacAppDelegate.self)` (macOS):

- **The background-launch-events bridge (iOS).** When a background download finishes while
  the app is suspended, the system **relaunches** it and calls
  `application(_:handleEventsForBackgroundURLSession:completionHandler:)`. The delegate
  **stashes that system completion handler** on `TransferCoordinator.shared` (matching the
  session identifier first), and the coordinator **invokes it exactly once, on the main
  thread, from `urlSessionDidFinishEvents`** — the `UIApplicationDelegate` contract that
  tells the system the app is done processing so it can re-suspend. `didFinishLaunching`
  also calls `coordinator.activate()` to **force the session (and its delegate) into
  existence at launch**.
- **BGTasks (iOS-only, `#if os(iOS)`).** The delegate **registers** two tasks and the
  `.background` scenePhase hook **submits** them: a **`BGProcessingTask`**
  (`com.levi.pocketdj.burn-drain`) that re-arms itself + `reconcileOnLaunch`s stuck
  transfers (completing the BGTask from *inside* the async reconcile callback, not before
  it runs), and a **`BGAppRefreshTask`** (`com.levi.pocketdj.rip-reconcile`,
  `earliestBeginDate` +15 min) that re-arms + refreshes the **public rips manifest** so a
  backgrounded collection RIP's progress (§9.1) reconciles — via a tiny `@MainActor`
  `RipReconcileBridge` the app wires to `{ await rips.refreshManifest() }` (the task itself
  holds no store references). Both identifiers must appear in
  `BGTaskSchedulerPermittedIdentifiers` (Ch. 7 §6). **macOS** (`MacAppDelegate`) only
  `activate()`s the session — it doesn't suspend the same way and `BGTaskScheduler` is
  unavailable, so background transfers ride the background `URLSession` directly.

### 11.3 Background audio — Now Playing + remote commands drive the sequencer

Background **audio** was already configured (`PlayerEngine` sets the `.playback`
`AVAudioSession`, the `UIBackgroundModes: [audio]` capability), but a *locked* setlist
needs the lock screen to **advance the set**. `PlayerEngine` now wires
**`MPNowPlayingInfoCenter`** per track (title/artist/elapsed/rate/`IsLiveStream`) and a
full **`MPRemoteCommandCenter`** — `play`/`pause`/`toggle`/`changePlaybackPosition` plus
**`nextTrackCommand`/`previousTrackCommand`**. The next/previous commands route through the
engine's `onNext`/`onPrevious` hooks, which **`SetlistPlayer`** (§10) owns only while a set
is running — so the lock screen / Control Center / AirPods / CarPlay **auto-advance the
setlist while the screen is off**, and the commands stay disabled (reject input) when no
set is running. `setNextPreviousEnabled` toggles them with the sequencer's lifecycle.

## Next

→ [Chapter 6 — Search & Discovery](./06-search-and-discovery.md)
