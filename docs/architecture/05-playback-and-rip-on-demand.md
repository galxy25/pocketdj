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
| `GET /health` | version handshake + stats | `{ ok, host, version, hls, stems, analogBase, bucket, catalog:{songs,albums}, cached, auth }` |
| `GET /status/:songId` | is it ripped? | `{ ready:true, url, entry }` or `{ ready:false, job }` |
| `POST /rip` `{songId}` | start/join a rip | `JobView` |
| `POST /rip-collection` `{songIds[]}` | batch-enqueue a whole collection (reuses the durable queue) | `{ results:[{songId,status,jobId,url}], counts }` |
| `POST /rip-cancel` `{songIds[]}` | cancel queued matching jobs + kill the in-flight capture child (§2.1) | `{ results:[{songId,status}], counts }` (`status ∈ canceled\|notFound\|alreadyDone`) |
| `GET /jobs/:id` | poll a job | `JobView` |
| `GET /hls/<songId>/index.m3u8` · `…/seg_N.ts` | live HLS (iOS-native) | playlist / TS segment |
| `POST /analysis` `{songId,bpm,…}` | external analysis submit | `{ ok, songId }` |
| `POST /backfill-cuts` · `POST /retag-cuts` | analog per-song CUT export / re-tag (§14) | `{ ok, candidates }` |
| `POST /backfill-beatgrids` | compute measured beat grids over the corpus (§15.1) | `{ ok, candidates }` |
| `POST /stemify` `{songId}` · `/stemify-collection` `{songIds[]}` · `/stemify-cancel` `{songIds[]}` · `/backfill-stems` | Demucs 4-stem separation (§15) | `StemJobView` / counts |

Auth is an **optional** bearer token (`RIP_TOKEN`): all gated routes go through one
shared `authed()` check that is **permissive (public) when no token is configured** — so
during development the server runs **tokenless / public** for frictionless integration
testing. `/rip` and `/rip-collection` sit below the *same* gate, so they are public (or
gated) **identically**; there is no `/rip-collection`-specific fail-closed branch. The HLS
media path (`/hls`) also accepts `?token=` because a native player can't set an
Authorization header. (The legacy progressive-mp3 `/stream/<id>.mp3` route has been
**removed** — iOS needs HLS, and the durable public mp3 covers every non-live play.)
`version` is `RIP_PROTOCOL = 2`; the client
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
   analog (sourceType==='analog' && !preferCloud) → analogCapMs               = 20 min (fixed)
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
not real-time) gets a generous **fixed 20-minute** cap (raised from 12 to cover the
per-song cut passes — Ch. 5 §14); a digital/cloud **real-time**
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
                   bpm?, musicalKey?, camelot?, waveform?, analyzed?,
                   cutKey?, cutBytes?, cutRippedAt?,                    // analog per-song CUT (§14)
                   firstBeatMs?, firstDownbeatMs?, beatGridBpm?, beatsPerBar?,   // BEAT GRID (§15.1)
                   tempoConfidence?, tempoVar?, steady?, beatgrid?, analysisVersion?,
                   stems?:{vocals,drums,bass,other}, stemModel?, stemVersion?,    // STEMS (§15)
                   stemFormat?, stemmedAt?, stemBytes? }

 JobView { jobId, songId, phase:RipPhase, message?, url?, error?,
           streamUrl?(/hls/<id>/index.m3u8), progress?{elapsedMs,totalMs,pct,indeterminate} }
   RipPhase = queued | searching | ripping | streaming | uploading | ready | error
```

**Reading the diagram.** `manifest.json` is keyed by `songId` → a `ManifestEntry`:
where the audio lives (`key`), how it was made (`source`), the auto-seek
`startMs`/`durationMs`, a **`rippedAt`** epoch-ms completion stamp, and background
analysis (`bpm`/`musicalKey`/`camelot`/`waveform`/`analyzed`). For an **analog** entry it
may also carry the per-song **CUT** triple (`cutKey`/`cutBytes`/`cutRippedAt`) — the
individual track sliced out of the album for the Burn's single-file export, §14;
playback is unchanged (album `key` + `startMs` seek). Two further analysis groups attach
**additively** (every field optional, so older entries decode unchanged): the **beat grid**
(`beatGridBpm`/`firstDownbeatMs`/`steady` + the rest, the measured downbeat grid the Mix
engine's Sync rides — §15.1) and the **stem** keys (`stems:{vocals,drums,bass,other}` + the
Demucs provenance — §15). `JobView` is the client-facing job projection: `phase` (the
`RipPhase` enum), an optional `streamUrl` once live HLS is ready, and `progress` (definite
for a real-time digital capture, `indeterminate` otherwise). Stem jobs poll their own
`StemJobView` off a dedicated stem queue (§15).

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
platforms. `load(url:live:startMs:endBoundaryMs:scopeRelease:…)` swaps the item; a
non-live (analog) item seeks to `startMs` once it reports a usable duration; a live HLS
item starts immediately and never seeks (no static duration). It also wires
**`MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`** so the lock screen / Control
Center / AirPods / CarPlay drive play / pause / scrub — **and next / previous, which
advance a running setlist while locked** (§11.3) — and configures the `.playback` audio
session so audio continues in the background (the `UIBackgroundModes` capability,
Ch. 7 §6).

**The position end boundary + the shared one-shot end latch (§10's load-bearing primitive).**
A track that lives inside a **shared album-rip mp3** (an analog album, or a cloud rip of an
analog side — one file, several songs, each at its own `startMs`) plays *past* its own
logical end straight into the next album track, because `.AVPlayerItemDidPlayToEndTime`
only posts at the end of the **whole file**. So the setlist sequencer needs the track to
advance at its **own known length**, not the file's. `load`'s **`endBoundaryMs`** (and the
no-reload **`setEndBoundary(ms:)`**) arm a `endBoundarySec` — an absolute position (seconds)
within the file — and the **periodic time observer** (the same 0.25s `addPeriodicTimeObserver`
that drives the clock) calls **`checkEndBoundary(atSeconds:)`** each tick: once the position
crosses the boundary it signals end. Because position only advances while playing, a paused
track can't fire it early; a live stream is never armed (`endBoundarySec` stays nil). Both
end paths — the natural `.AVPlayerItemDidPlayToEndTime` **and** the position boundary —
funnel through **`signalTrackEnded()`**, a **one-shot latch** (`trackEndSignaled`, reset on
every `load`/`setEndBoundary`): whichever lands first fires `onTrackEnded` and the other is
suppressed, so a set can never double-advance. `checkEndBoundary` is split out from the
observer purely so the fire is **deterministically unit-testable** (drive a position in, assert
exactly one end).

**The security-scope release (offline burned-folder playback).** A burned file in a
**user-picked** (security-scoped) folder must keep its scoped access **open the whole time
`AVPlayer` reads it** — releasing it early leaves the player unable to read the file, a silent
**0:00 / no-audio**. So `load`'s **`scopeRelease`** closure holds that scope for the lifetime
of the item: `load` calls the *previous* item's `scopeRelease?()` before swapping, stores the
new one, and `stop` releases it (nil for app-storage files, which need no scope). This is the
playback-side half of `BurnStore.localURLForPlayback` (§9), which opens the scope and hands the
release here.

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
resizes the panel. The scrubber's end timestamp **falls back to the catalog index length**
(`app.songsById[songId].length`, via `InlinePlayerExpanded.catalogDurationSec` —
`max(player.duration, catalogDurationSec, 0.01)`) when the audio file's real duration isn't
known yet (still loading, or a burned file whose duration can't be read), so the panel always
shows a sensible `/ m:ss`. (For a **live** stream there's no scrubber —
`InlinePlayerExpanded` shows a *"Streaming live as it rips"* state and a `● live` badge
instead, since a live HLS playlist has no fixed length.)

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

**Cloud-offline fast skip — the 12s rip POST timeout.** The rip path's `POST /rip` in
[`RipsStore.play`](../../apple/PocketDJ/State/RipsStore.swift) sets
**`timeoutInterval = 12`** (matching `RipServerService.health`). Without it, a **configured
but unreachable** rip server — the common case at a venue: the Tailscale/home iMac is asleep
while the phone's on venue wifi — would hang on `URLSession.shared`'s **60s default** before
failing, stalling a cloud-mode **Play-All** for a full minute per un-burned track before the
sequencer could skip it. The 12s cap makes that fail in seconds so the set advances promptly.
(`remoteLastModifiedMs`'s HEAD, §14, uses the same 12s.)

### 8.1 Offline-first catalog — explicit per-source disk cache + graceful degrade

**Why.** Playback offline (§9) is pointless if the **catalog itself** won't open offline.
`URLRequest.cachePolicy = .returnCacheDataElseLoad` leans on `URLSession`'s shared `URLCache`,
which silently **refuses to persist** responses past its small default capacity — and the
catalog index (1,300+ albums) routinely **exceeds** it, so an offline relaunch had nothing to
fall back to and opened **empty**.

**Source of truth:**
[`apple/PocketDJ/Services/CatalogService.swift`](../../apple/PocketDJ/Services/CatalogService.swift)
(the per-source disk cache),
[`apple/PocketDJ/State/AppModel.swift`](../../apple/PocketDJ/State/AppModel.swift)
(`fetchIndex` multi-source degrade).

```
 CatalogService.loadIndex():
   try  GET url (.returnCacheDataElseLoad, 30s) → decode IndexJSON
        success → writeCache(rawBytes, for: url)  (ONLY after a valid decode)  → return
   catch (no network / non-2xx / decode fail):
        loadCachedIndex(for: url) ≠ nil → return it          (OFFLINE fallback)
        else → re-throw                                       (never loaded online)

 cacheFileURL(for url) = AppSupport/catalog-cache/<SHA-256(url.absoluteString)>.json
        (SHA-256, NOT Swift's per-process-seeded Hasher — must survive relaunch)

 AppModel.fetchIndex():  for url in enabledSourceURLs:
        try load → indexes.append    else → remember firstError, SKIP this source
   guard !indexes.isEmpty  else throw firstError    (fail ONLY if EVERY source failed)
```

**Reading the diagram.** `loadIndex()` fetches + decodes as before, then — **only after a
valid decode** (so a partial/garbage response is never cached) — persists the **raw bytes** to
an explicit file under `Application Support/catalog-cache/`, named by the **SHA-256 of the
source URL string** (a deterministic, flat, O(1), *relaunch-stable* filename — Swift's `Hasher`
is per-process-seeded and wouldn't survive a relaunch). On **any** failure — no network, a
non-2xx, a decode error — it serves the last good index for **that source** from disk and only
re-throws when there's no cache (a source never loaded online). A plain file in Application
Support has no `URLCache` capacity cap, so the catalog opens with its **full** contents
offline. `AppModel.fetchIndex` then **degrades gracefully across sources**: a source that
fails *and* has no cache is **skipped** so the **other** sources' cached catalogs still open;
the whole load fails **only when every source failed** (`indexes` empty). One un-cached source
can't hide an already-cached one. (`cacheDirectory`/`cacheFileURL` take a `dir` override as the
unit-test seam, so the round-trip is testable without touching Application Support.)

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
   resolve catalog (song s, album a) BEFORE naming   → fileNames(songId, entry, song:s, album:a)
   downloadDataIfCached → (data, ManifestEntry)
   analog → <Artist-Album-Year-Genre>-<albumId>.mp3   (ALBUM-LEVEL prefix; one shared file/album,
                                                        reuse if a sibling wrote it; seek by startMs)
   digital → <Artist-Song-Album-Year-Genre-Camelot-Key-BPM>-<songId>.mp3   (PER-SONG prefix)
   write <Artist-Song-…-BPM>-<songId>.txt sidecar (BPM · Key+Camelot · Sentiment · Album + meta + JSON)
   record BurnItem{ audio/sidecar names, bpm/key/camelot/durationMs/startMs, bytes,
                    rippedAt(from entry), downloadedAt(now), state:.ready }  → save()
```

**The metadata filename scheme (§9.0).** The burned audio + sidecar names now carry a
**sanitized, descriptive prefix** so a file is identifiable in Finder/Files without opening
the sidecar — built by `BurnStore.fileNames(for:entry:song:album:)` (the catalog `song`/
`album` are resolved **before** naming so the prefix has the real metadata). The digital
per-song prefix is **`Artist-Song-Album-Year-Genre-Camelot-Key-BPM`** (analyzed
bpm/key/camelot preferred from the manifest `entry`, falling back to the catalog song);
the **analog** shared whole-album file gets an **album-level** prefix
(`Artist-Album-Year-Genre`, **no** per-song bpm/key — it's one file for the whole side, so
every song of the album must map to the *same* audio name to keep the shared-file
reuse/dedup/`isFresh` logic correct). The `.txt` sidecar always uses the per-song prefix.
Each token is **sanitized** (`sanitizeToken`: illegal/reserved filename chars **and** the
`-` separator → spaces, whitespace collapsed, capped at 40 chars) and missing fields are
**dropped** (no empty placeholder tokens); `descriptiveName` then joins the prefix with
`-`, **caps only the prefix** (150 chars) and **never truncates** the `idSuffix` (the
`albumId` for analog / `songId` for digital, from the manifest key's basename) or the
extension — so keying, dedup, and finalize stay stable. A blank prefix degrades to just
`<id>.<ext>`.

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
`PlayerEngine.load(url:live:startMs:title:artist:…)` (§7), which already accepts any local
URL + `startMs`. The human-readable `<songId>.txt` sidecar mirrors the `burn-setlist`
skill's format (§6) as a companion; the JSON index, not the prose, is the source of truth.

**Burning the stems too (so a burn *mixes* offline, not just plays).** After the audio +
sidecar pass, `burn(...)` runs **`burnCollectionStems(songs, dir:)`** so a burned collection
can drive the Mix tab's **stem decks** (Ch. 4 §7.6) and the **stem-audition panel** (§15)
with **no network**. It considers only songs the **server has already stemmed**
(`rips.manifest[id]?.stemVersion != nil` — burning **fetches** stems, it never triggers
separation), **skips** any whose four stems are already on disk (`stemFilesPresent`), is
**STOP-aware** (between songs) and **best-effort** (a stem failure never fails the burn), and
drives its own "Stems · …" progress pill. `downloadStems(songId:dir:)` writes the four parts
under deterministic `stem-<songId>-<part>.mp3` names (`stemNames =
[vocals,drums,bass,other]`) — these are **not** tracked in the `BurnItem` ledger (their names
can't collide with the audio/cut suffixes). Because the pass runs on **every** `burn(...)`
and is idempotent, **re-burning a collection picks up stems that became available since** the
last burn; the count lands in `BurnResult.stemmedSongs`. (A per-song `burnStems(forSong:) →
(urls, release)` does the same for the SongDetail audition, §15.)

**`localURLForPlayback` — the scope-held playback resolver.** `localURL(forSong:)` is the
**existence-check** path: it opens the user-folder scope, stats the file, and **stops the
scope immediately in its `defer`** — correct for a yes/no check, but fatal for *playback*,
because `AVPlayer` reads the file lazily over the whole track and the scope is already gone (a
silent **0:00 / no-audio offline**). So every **song-start path now resolves through
`localURLForPlayback(forSong:)`** instead: it keeps the scoped access **open** and returns
`(url, release:(() -> Void)?)` — the `release` is handed to `PlayerEngine.load`'s
`scopeRelease` (§7), which holds it for the item's lifetime and calls it on the next
`load`/`stop`; `release` is nil for app-storage files. (A *missing* file still stops the scope
so it never leaks.) The read side of `resolveBurnFolder` also gained
**`requireWritable: false`**: playback only needs the folder **readable**, so a Files-provider
folder that resolves but isn't currently writable (e.g. an offline iCloud Drive folder) still
satisfies a read — gating reads on writability was a *second* way burned songs failed to
resolve. `itemDir` (the read/playback path) now calls
`resolveBurnFolder(allowRePersist:false, requireWritable:false)`.

**Burned-first on every song-start path (offline-first).** Every play entry point now prefers
a **burned local file before any rip/stream**, in **both device and cloud mode** — so a song
already on the device plays with **zero latency and no network**: the row ▶
(`RowTransport.doPlay` in [`CollectionSongRow.swift`](../../apple/PocketDJ/Views/CollectionSongRow.swift),
an O(1) `songId`→dict hit + one `fileExists`), the keyboard **⌘P** (`BrowseView`'s play
handler), and **Play-All** (the `SetlistPlayer` cloud branch, §10) all do
`burns.localURLForPlayback → playLocalFile` first, falling through to the coordinator only
when there's no local file. The same change fixed the row's **dead pause button for burned
songs**: a burned file has **no coordinator backend** (`activeBackend == nil`), so the
now-playing toggle now routes `isAppleMusic ? coordinator.togglePlayPause() : player.toggle()`
— the rip-stream and the burned file both toggle the shared `PlayerEngine` directly.

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
nothing. (The burn's own progress capsule is unchanged; a third overlay branch shows the
**"Burning N of M"** background-burn progress, §11.1.)

**The "Burning N of M" count fix — the `@Observable` progress mirror.** That overlay
branch (`CollectionRipBurnAlert.backgroundBurnProgress` in
[`CollectionRipBurn.swift`](../../apple/PocketDJ/Views/CollectionRipBurn.swift)) used to read
the **`TransferCoordinator.progressSnapshot`** directly — but the coordinator is a plain
**`NSObject`** (it *must* be, to be the background-session delegate, §11.1), so SwiftUI can't
track it and the overlay **froze at the enqueue total**, never re-rendering as each background
download finished (the "burning number doesn't update" bug). The fix: the coordinator now also
calls an **`onProgress(enqueued,finished)`** hook on the **main actor** alongside
`progressSnapshot` (from `publishProgress`), and `BurnStore` wires it to mirror the value into
its own **`@Observable backgroundProgress`** property. The overlay reads
**`burns.backgroundProgress`** — a tracked `@Observable` on the `@MainActor @Observable`
`BurnStore` — so it re-renders as each download completes. The counters are run-scoped
(`beginRun` republishes `(0,0)`), so a second burn starts at 0.

---

## 10. Setlist PLAY — the `SetlistPlayer` sequencer (burnt-or-stream)

**Why.** A setlist is an ordered set; the DJ wants a single **Play** that runs it
top-to-bottom hands-free. `SetlistPlayer` is a thin sequencer that plays each track in
order, auto-advancing on end, and — crucially — chooses **burnt-local-file-if-present,
else stream** per track, so a partially-burnt set still plays end-to-end (offline tracks
from disk, the rest streamed). This branch makes its advance **length-aware** (so a track
inside a *shared* album mp3 advances at its OWN end), gives it a **persistent ⏮/⏭
transport**, and lets a **manual row ▶ on an in-set track reposition the running set**
instead of derailing it.

**Source of truth:**
[`apple/PocketDJ/Playback/SetlistPlayer.swift`](../../apple/PocketDJ/Playback/SetlistPlayer.swift),
driven by the **Play/Stop + ⏮/⏯/⏭** toolbar in
[`apple/PocketDJ/Views/SetlistDetailView.swift`](../../apple/PocketDJ/Views/SetlistDetailView.swift)
(storybook §32). The `Item` now carries **`lengthMs`** (the track's known length from the
setlist snapshot, `track.shownMs`) — `playableItems(_:)` maps it in.

```
 SetlistPlayer.play(items)  ── items = [{id,title,artist,lengthMs?}] in setlist order
   index=0; isRunning=true
   player.onTrackEnded = handleEnded ;  player.onNext = skipNext ;  player.onPrevious = skipPrevious
   player.setNextPreviousEnabled(true)   (lock-screen ⏭/⏮ enabled only while running)
   (observeNowPlaying armed ONCE in init — self-re-arms; NOT re-armed per play())
   ▼ playCurrent()  — resolves the SOURCE FRESH each track, branching on playbackMode():
   bound = sharedFileEndBoundaryMs(it, startMs)   = startMs + lengthMs   (nil if startMs nil)
   mode == .device :                                          (§12 — global toggle)
        burns.localURLForPlayback(id) ≠ nil ?
            → playLocalFile(url, startMs, endBoundaryMs: bound, release: res.release)  (BURNT)
                                                                  loadedAnyDeviceTrack=true
            else → SKIP the track (advance NOW — un-burned, no file, no end event)
   mode == .cloud (else) :
        burns.localURLForPlayback(id) ≠ nil ?
            → playLocalFile(url, startMs, endBoundaryMs: bound, release: res.release)  (BURNT)
            else → coordinator.play(id)   (Apple Music → rip fallback, §8)             (STREAM)
                  coordinator.lastErrorMessage ≠ nil → advance NOW (dead source, no end event)
                  player.isLive → waitingForLive = true ("Next" affordance, no auto-end)
                  else (cloud-analog = ONE shared mp3) → player.setEndBoundary(ms: bound)
   ▼ handleEnded()  (natural end OR position boundary — §7 one-shot latch)
   GUARD rips.nowPlaying?.songId == queue[index].id  → advance() ; index≥count → stop()
        on stop, if mode==.device && !loadedAnyDeviceTrack → deviceQueueUnplayable=true (banner)

 observeNowPlaying → adoptNowPlayingIfJumped()  (RipsStore.nowPlaying changed):
   re-arm observation ; guard isRunning ; nowPlaying.songId ≠ queue[index].id ?
     pos = nearestOccurrence(of: npId, to: index)   (in-set? FORWARD-preferred on a tie)
     index = pos ; player.setEndBoundary(ms: startMs(nowPlaying) + lengthMs)   ← ADOPT
```

**Reading the diagram.** `play(items)` seeds the queue, flips `isRunning`, and takes
ownership of the shared `PlayerEngine.onTrackEnded` hook **plus `onNext`/`onPrevious`** and
enables the lock-screen ⏭/⏮ — all released in `stop()`. `playCurrent()` re-resolves the
source **fresh each track** (a burnt file may have been purged since the queue was built),
computes the **length boundary** `bound = startMs + lengthMs` via `sharedFileEndBoundaryMs`,
and **branches on the global `playbackMode()` seam** (§12).

**Length-aware advance.** `sharedFileEndBoundaryMs` returns nil when `startMs` is nil — a
**per-song** file (digital rip, digital cloud rip) has its **own** natural end, so it must
*not* be cut at the catalog length (which can be missing or short). A **non-nil `startMs` is
exactly the signal that the track shares a multi-song file** — only analog album rips share
one mp3 across songs, and each carries a per-song `startMs` — so there the boundary
`startMs + lengthMs` is armed (via `endBoundaryMs:` on a burnt file, or `setEndBoundary` after
a cloud-analog stream resolves) and the **position observer advances at the track's own end**
even though `.AVPlayerItemDidPlayToEndTime` won't fire until the end of the **whole** album
file. Both end signals funnel through §7's **one-shot latch**, so the shared boundary and a
natural end can't double-advance.

**Mode branch.** In **`.cloud`** (today's default) it plays the burnt local file if present
else streams via `PlaybackCoordinator` (§8). In **`.device`** it plays **only** the burnt
local file and **skips** an un-burned track (advance immediately — no file, no end event);
a mode flip applies to the **next** track (the current one finishes under the mode it
started with). Either way a burnt local file drives the **same `PlayerEngine`** the inline
player binds to — via the shared `playLocalFile` helper (§12), now passing `endBoundaryMs:`
**and the `release:`** from `localURLForPlayback` (§9) so a user-folder file's security scope
stays open through playback — so `nowPlaying` + the per-row `InlinePlayerSlot` (§7) + the row
pause/resume toggle stay consistent and the current track lights up with **zero new player UI**.
If a whole device-mode set reaches the end having loaded **no** burnt file, the end-of-set
teardown raises a one-shot **`deviceQueueUnplayable`** flag the playback surface reads to show a
transient "nothing on device" banner (cleared on the next `play(_:)` or
`clearDeviceUnplayable()`).

**Manual-jump adoption — `observeNowPlaying` / `adoptNowPlayingIfJumped`.** Before this branch,
tapping a row ▶ on a song that's already *in* the running set changed `RipsStore.nowPlaying`,
which `handleEnded`'s ownership guard read as a **stray** play — so when that manually-started
track ended, the guard failed and the **set silently stopped**. Now the sequencer **observes**
`RipsStore.nowPlaying` (`withObservationTracking`, armed **once in `init`** and self-re-arming
on the first line of every callback — never re-armed from `play()`, which would stack
observers): when the now-playing song is a **different queue member** than the current index, it
**adopts** the jump — moves `index` onto that occurrence and re-arms its length boundary off
`nowPlaying.startMs` (the source the row actually loaded). The sequencer's *own* plays already
set `nowPlaying = queue[index]`, so the equality guard makes those a no-op (no restart loop),
and `handleEnded`'s guard then **passes** for the adopted track so it auto-advances normally.
**Duplicate songs** are disambiguated by **`nearestOccurrence(of:to:)`** — the occurrence
nearest the current index, **preferring a forward occurrence on a tie** (the DJ usually taps a
row later in the set), since the now-playing handoff carries no queue position.

**Persistent prev/next transport.** `play()` enables the lock-screen `nextTrackCommand` /
`previousTrackCommand` (via `setNextPreviousEnabled(true)`, §11.3) and wires the engine's
`onNext`/`onPrevious` to **`skipNext()`** (= `advance()`) and **`skipPrevious()`** (clamps to
index 0, never below; re-resolves + plays the now-current track). The iOS play-mode toolbar
surfaces the same ⏮/⏯/⏭ **centered** in the nav bar (`SetlistDetailView`'s `.principal`
`transportCluster`), so prev/next are always reachable, not just on a live track. Two edges
still keep cloud mode from freezing: a **dead source** (coordinator error, or a purged burnt
file) advances immediately since no end event fires, and a **live HLS** capture (no natural
end) sets `waitingForLive` so the UI shows a manual **Next**. Reaching the end tears down
cleanly (releases the hooks, disables ⏭/⏮, clears now-playing) so the toolbar flips back to
**Play**.

**The iOS play-mode toolbar.** While a set plays on iOS,
[`SetlistDetailView.setlistToolbar(_:)`](../../apple/PocketDJ/Views/SetlistDetailView.swift)
reshapes the bar into a clean music transport: the **⏮ · ⏯ · ⏭ `transportCluster` is centered**
via `.principal` (its middle toggles play/pause on whichever backend is active —
`coordinator.togglePlayPause()` for Apple Music else `player.toggle()`), **STOP takes the play
button's trailing slot** (`startStopButton` — not a menu item), and the secondary actions
(**Edit · Rip · Burn as separate flat items · Rename · Delete**) collapse into a single •••
`overflowMenu` (Edit is present-but-disabled mid-set, since reordering would desync the
sequencer's queue index). **macOS** keeps the flat trailing toolbar (no `.principal` nav bar)
with prev/next inline while running.

### 10.1 The home Now Playing deck — live queue edits + the spinning record

`NowPlayingPanel` (`apple/PocketDJ/Views/NowPlayingPanel.swift`) rides the shell's
sidebar (RootView) — the iPhone home menu / the iPad+macOS left column — whenever
`sequencer.isRunning && !(mix.isRunning || mix.autoMixing)` (collection playback in
any mode EXCEPT Mix; the Mix engines own their audio). Contents, top-down: current
`queue[index]`'s title/artist · `RecordPlayerView` · ⏮ ⏯ ⏭ (the §10 cross-backend
toggle) · the **Up Next** list · a debounced add-search.

- **`RecordPlayerView`** — gold disc (`Theme.accent2`) with grooves and the album's
  `CoverImage` as center label, inside a `Theme.accent` (blue) chassis + fixed
  tonearm. Spin rate = **one revolution per 4-beat bar**: `burns.beatGrid(forSong:)`'s
  measured `beatGridBpm` first, catalog `bpm` fallback, 33⅓ RPM unknown. Rendering is
  a **paused `TimelineView`** (zero redraws while paused — the Mix beat-pulse
  discipline); pause FREEZES the angle (accumulated into `baseAngle`) and resume
  continues from it. iPhone landscape (`verticalSizeClass == .compact`) drops the
  record and keeps the functional rows.
- **Live queue edits — the `SetlistPlayer` seam** (§10's queue is otherwise
  immutable): `upcoming` (= `queue[(index+1)...]`), `moveUpcoming(fromOffsets:toOffset:)`
  (offsets CLAMPED to the live tail — a track ending mid-drag must not trap),
  `removeUpcoming(uids:)` (removal by per-row `Item.uid` IDENTITY, so a ✕ tap that
  races an auto-advance still removes exactly the tapped song, never whatever
  shifted into the slot), and `appendToQueue(_:)` (picked up by the next `advance()`;
  no-op when idle). All three touch ONLY positions `> index` — `handleEnded`'s
  ownership guard and jump-adoption key off `queue[index]`, so the current track
  never restarts and `nowPlayingRevision` never bumps (no SetlistDetailView restart).
  Note the panel renders the EPHEMERAL run — edits don't write back to the frozen
  `set_now_playing` snapshot (same contract as §10's disabled mid-set Edit).
- **Add-search** — `NowPlayingSearch`: pure tokenized all-tokens-match over
  name+artist, ranked exact-name > name-prefix > catalog order, capped (10 albums /
  25 songs). The panel runs it **debounced (200 ms) on a detached task over value
  snapshots** (`.task(id: query)` cancels stale runs) — never a full-catalog scan on
  the main actor. Albums render above songs, both sections collapsible; ＋ appends a
  song or the album's `app.tracks(for:)` expansion.
- **Testing seams**: `PDJ_HOLD_PLAYBACK` freezes `playCurrent` (running state, no
  audio) so UI tests can drive running-state surfaces on the fixture;
  `NowPlayingUITests` + `NowPlayingQueueTests`/`NowPlayingSearchTests` cover the
  panel, the race clamps, and the launch defaults (below).
- **Launch defaults** (RootView): iOS lands on the home menu unless
  `settings.lastSection` restores the last-visited section (persisted on every
  section change; `""` = home; a fresh iPad picks MIX — like the Mac — with the
  sidebar row selected to match); macOS always lands on Mix. The iOS home title is plain "PocketDJ"
  (macOS keeps "✦ PocketDJ").

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
data-race-by-convention. The coordinator is a plain `NSObject` (not `@Observable`), so the
same main hop *also* fires an **`onProgress(enqueued,finished)`** callback that
**`BurnStore` mirrors into its `@Observable backgroundProgress`** — and the overlay's "Burning
N of M" branch reads **that** tracked value (§9.1), not the un-observable `progressSnapshot`,
so it actually re-renders as each background download finishes.

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

---

## 12. Global device / cloud playback MODE — `PlaybackMode` + the shared `playLocal` helper

**Why.** §8–§11 always resolve a source per-play: stream-first, rip-last, with burnt files
opportunistically preferred. But a DJ in a no-signal room wants the **whole app** to commit
to **playing burned files off the device**, and a DJ with signal wants it to commit to
**streaming** — a single global switch, like the browser's on-device/online search toggle.
`PlaybackMode` is that switch; it changes how every Play surface resolves a source.

**Source of truth:**
[`apple/PocketDJ/Settings/SettingsStore.swift`](../../apple/PocketDJ/Settings/SettingsStore.swift)
(`PlaybackMode` enum + the persisted `playbackMode` property),
[`apple/PocketDJ/Views/PlaybackModeToggle.swift`](../../apple/PocketDJ/Views/PlaybackModeToggle.swift)
(the toolbar toggle),
[`apple/PocketDJ/Playback/PlaybackCoordinator.swift`](../../apple/PocketDJ/Playback/PlaybackCoordinator.swift)
(the shared `playLocalFile` helper),
[`apple/PocketDJ/Playback/SetlistPlayer.swift`](../../apple/PocketDJ/Playback/SetlistPlayer.swift)
(`playbackMode` seam, §10).

```
 PlaybackMode { cloud, device }        persisted on SettingsStore.playbackMode (default .cloud)
   toggle: PlaybackModeToggle  — one toolbar button on the Setlist / Playlist / Pocket bars
     icon  cloud-glyph (cloud) ⇄ current-device-glyph (iphone/ipad/macbook) (device)

 .cloud   = today's behaviour — PlaybackCoordinator stream-first (Apple Music → rip, §8)
 .device  = play ONLY burned local files
     Play-All (SetlistPlayer §10)  → SKIPS un-burned tracks; "nothing on device" banner if NONE
     single-row tap                → burnt file if present, else FALL BACK TO CLOUD (one song)

 playLocalFile(url, songId, title, artist, startMs, rips, player,
               endBoundaryMs?, release?)                            ── SHARED @MainActor helper
   rips.setNowPlaying(NowPlaying{songId,title,artist,url,live:false,startMs})
   player.load(url, live:false, startMs, …, endBoundaryMs: endBoundaryMs, scopeRelease: release)
   (used by SetlistPlayer device+cloud burnt paths AND the row ▶ / ⌘P burnt path → one consistent now-playing,
    one length-boundary, one held security scope)
```

**Reading the diagram.** **`PlaybackMode`** is a two-case enum (`cloud` | `device`)
persisted on `SettingsStore.playbackMode` (default `.cloud`, raw-string-coded so an older
saved settings blob coalesces to `.cloud`). The **`PlaybackModeToggle`** is a single
toolbar button — styled like the browser's on-device/online search toggle, showing a
**cloud** glyph in cloud mode and the **current-device** glyph (`iphone`/`ipad`/`macbook`)
in device mode — dropped onto the **Setlist / Playlist / Pocket** detail toolbars. In
**`.cloud`** every Play resolves through the stream-first coordinator (§8) exactly as
before. In **`.device`** the app commits to burned files: **Play-All** (the `SetlistPlayer`
sequencer, §10) plays only burnt local files and **skips** un-burned tracks — raising the
"nothing on device" banner if the whole set is un-burned — while a **single-row tap**
plays the burnt file if present and otherwise **falls back to cloud** for that one song (a
single missing track shouldn't go silent). The **mode is read lazily** through a
`playbackMode: () -> PlaybackMode` seam on `SetlistPlayer` (injected from settings), so
**flipping the toggle mid-set applies to the *next* track** — the current track finishes
under the mode it started with.

**The shared `playLocalFile` helper (the consistency rule).** A burnt local file can be
started from several surfaces — the `SetlistPlayer` device **and** cloud burnt paths *and*
the single-row ▶ / ⌘P burnt-file transport — and all must leave **`RipsStore.nowPlaying`**
(and therefore the inline player + the row pause/resume toggle) in the *same* state as the
rip path does. So they all call **one `@MainActor` `playLocalFile`** in
`PlaybackCoordinator.swift`: it stamps `nowPlaying` then `load`s the **same `PlayerEngine`**
the inline waveform/scrubber (§7) binds to, passing `startMs` as the analog seek offset into
a shared album mp3 **plus the optional `endBoundaryMs:`** (the length boundary for a shared
album file, §10) **and `release:`** (the held security scope for a user-folder file, mapped
to the engine's `scopeRelease`, §7/§9), mirroring `RipServerPlaybackProvider.tryPlay` for the
rip path. One helper ⇒ now-playing, the length boundary, and the security scope are consistent
no matter which surface started the burned file.

---

## 13. Cloud-analog → `public/current-index.json` — the in-process fold (closing the gap)

**Why.** [Ch. 3 §1.2](./03-catalog-and-data-model.md#12-the-cloud-re-index--folding-apple-music-truth-into-the-analog-catalog)
describes the **offline** cloud re-index that folds Apple Music length + cloud bpm/key into
the analog catalog — but it ran only as a manual CLI tool writing a side output (appendix
inconsistency #13). That left a gap: when a **cloud rip of an analog song** finishes
analysis on the live rip server, its freshly-computed bpm/key/camelot/length sat in the
**rips manifest** and never reached the public catalog until someone re-ran the CLI by hand.
This branch closes that loop — the rip server now folds a just-analyzed cloud-analog entry
into `public/current-index.json` **in-process**, the moment analysis completes.

**Source of truth:** the extracted pure fold
[`scripts/lib/cloud-reindex-fold.mjs`](../../scripts/lib/cloud-reindex-fold.mjs)
(`foldCloudReindex(index, lib, manifest)` — now shared by **both** the offline CLI
[`scripts/reindex-cloud-analysis.mjs`](../../scripts/reindex-cloud-analysis.mjs) and the
server) and the rip server's debounced driver in
[`scripts/rip-server.mjs`](../../scripts/rip-server.mjs)
(`requestPublicFold` / `runPublicFoldOnce` / `foldPublicIndex`, the `RIP_PUBLIC_FOLD` /
`RIP_PUBLIC_INDEX` config). End-to-end test:
[`scripts/test/rip-public-fold-e2e.mjs`](../../scripts/test/rip-public-fold-e2e.mjs).

```
 enqueueAnalysis(songId) completes  (digital/cloud rip, source:'digital' && analyzed)
   isCloudAnalogEntry(songId)? ── analyzed digital manifest entry ──▶ requestPublicFold()
        │                                                              (analog rips never fold —
        │                                                               they keep the catalog values)
        ▼  DEBOUNCE (1.5s trailing) — a collection rip's many analyses coalesce into ONE fold
 runPublicFoldOnce()  (single-flight: foldRunning guard; a mid-run request re-fires trailing)
        ▼
 foldPublicIndex()                                  ── synchronous metadata pass, in-memory catalog
   guard: index exists · manifest.sourceType=='analog' · library index warm
   WORKING-TREE GUARD: head = git show HEAD:<rel>; isFoldOnlyDiff(head, index)?
        any difference OUTSIDE fold-owned fields {length,bpm,key,camelot,cloudReindex} → REFUSE
        (don't clobber uncommitted NON-reindex edits; no git/HEAD baseline ⇒ proceed)
   report = foldCloudReindex(index, libIndex, manifest)      ── EXACT am-match only, cloud precedence
   report.changed == 0 → no-op (idempotent: values already folded)
   else: stamp index.manifest.cloudReindex{generatedAt, source:'rip-server in-process', counts}
         ATOMIC write: <path>.fold-<pid>.tmp → renameSync(tmp, path)   (atomic on same fs)
         log "✓ public-fold: N updated"  +  "⚠ did NOT deploy — run scripts/deploy.sh"
```

**Reading the diagram.** When `enqueueAnalysis` finishes for a rip, the server asks
**`isCloudAnalogEntry`** — true only for an analyzed **digital** manifest entry (the only
kind a cloud/digital rip produces; an analog rip keeps the catalog's per-song values and so
never triggers a fold). If so it calls **`requestPublicFold`**, which **debounces** to a
single **trailing** run (1.5s) so a whole-collection cloud rip's many back-to-back analyses
coalesce into **one** fold, and runs it **single-flight** (a request arriving mid-run
re-fires exactly one trailing run). The fold itself is **in-process** (no detached node),
running **inside the analysis flow** over the **in-memory catalog** + the warm library
index + the live manifest — a fast metadata pass. It reuses the **same pure
`foldCloudReindex`** the offline CLI uses (extracted into `scripts/lib/cloud-reindex-fold.mjs`
so there's one implementation): **exact `am-match` only** (Ch. 3 §1.3 — a loose/none match
never overwrites), per-field **cloud precedence** (length from Apple Music `Total Time`;
bpm/key/camelot from the cloud rip keyed by the song's own id or the derived Apple-Music
songId), each touched song **provenance-stamped** with `cloudReindex`, and **idempotent**
(a re-run with the values already folded reports `changed == 0` and writes nothing).

Three safety properties make it safe to run on the live catalog automatically: it **never
auto-deploys** (it logs a publish hint — `run scripts/deploy.sh` — and leaves CloudFront
untouched, so the owner still reviews + ships the catalog); it **guards the working tree**
by diffing the committed (`git show HEAD:<path>`) JSON against the on-disk file and
**refusing** to write if any difference lives **outside** the fold-owned fields
(`{length, bpm, key, camelot, cloudReindex}`), so it can never clobber an unrelated
uncommitted edit (no git baseline ⇒ nothing to protect ⇒ proceed); and it writes
**atomically** (temp file in the same dir + `renameSync`). It also only folds when the
target's `manifest.sourceType === 'analog'` (it's the *analog* catalog being enriched with
cloud truth). Disable entirely with `RIP_PUBLIC_FOLD=0`; point at a different catalog with
`RIP_PUBLIC_INDEX`.

---

## 14. The analog CUT pipeline — per-song slices for the Burn's single-track export

**Why.** An analog rip is **one whole-album mp3**; the app plays a song out of it by seeking
to `startMs` (§3). That's perfect for in-app playback but wrong for **other DJ software**,
which wants a folder where every track is its **own file** ("full song list" view). The Burn
already downloads the whole-album backcase; this branch makes the rip server *also* slice each
analog song into its **own cut** so the Burn can drop the **individual track alongside** the
album. Playback is **unchanged** — `cutKey` is consumed only by the Burn; the album mp3 +
`startMs` seek stays the playback source.

**Source of truth:** the rip server cut pass + endpoints in
[`scripts/rip-server.mjs`](../../scripts/rip-server.mjs) (`runAnalogJob`'s cut loop,
`cutDurationMs`, `backfillCuts`, `retagCuts`, the `POST /backfill-cuts` + `POST /retag-cuts`
routes), the manifest `cutKey`/`cutBytes`/`cutRippedAt` triple (§5), and the device side in
[`apple/PocketDJ/State/BurnStore.swift`](../../apple/PocketDJ/State/BurnStore.swift)
(`exportAnalogCuts`) +
[`apple/PocketDJ/State/RipsStore.swift`](../../apple/PocketDJ/State/RipsStore.swift)
(`url(forKey:)` · `remoteLastModifiedMs` · `downloadBytes`).

```
 SERVER — runAnalogJob, AFTER the whole-album mp3 is uploaded (album mp3 still in tmp):
   for each analog song of the album (skip cloud-rip songs):
     startMs = pointer.startMs ?? entry.startMs
     durMs   = cutDurationMs(s,e) = length ?? durationMs ?? (pointer.endMs - startMs)
     startMs|durMs missing → album-only (no cut)
     ffmpeg -ss startMs/1000 -i <album.mp3> -t durMs/1000 -map 0:a:0 -b:a 256k
            -metadata title/artist/album  -id3v2_version 3   →  <songId>.cut.mp3
     aws s3 cp → rips/<songId>.cut.mp3        (the PUBLIC rips/ prefix; `.cut.` infix)
     entry.cutKey/cutBytes/cutRippedAt = …    (and persist derived durationMs if it was null)
     (per-cut failure is NON-FATAL — the album entry alone still plays + is the backcase)

   POST /backfill-cuts  → backfillCuts():  retro-slice EVERY analog entry missing a cutKey,
        straight from the RAW album source (NO whole-album re-transcode); single-flight
   POST /retag-cuts     → retagCuts():  tag-only remux of EVERY existing cut
        (download → ffmpeg -c copy -map_metadata -1 + fresh title/artist/album → re-upload),
        bumps cutRippedAt so the app auto-repulls; no re-encode, no source drive needed

 DEVICE — BurnStore.exportAnalogCuts(songs, dir)  (in-process, inside burn()'s held folder scope):
   for each analog song whose manifest entry has a cutKey:
     cutName = descriptiveName(digitalSongPrefix, idSuffix: songId, "mp3")   (PER-SONG name)
     remoteMs = rips.remoteLastModifiedMs(url(forKey: cutKey))   (HEAD → Last-Modified epoch-ms)
     local present ∧ storedCutDownloadedAt ≥ remoteMs → KEEP (up-to-date)
     offline (HEAD failed) ∧ local present            → KEEP (don't clobber)
     else: data = downloadBytes(url(forKey: cutKey))
           DELETE old cut (prev name if renamed, + target) AFTER bytes in hand → write atomic
           item.cutFileName = cutName ; item.cutDownloadedAt = remoteMs ?? now
   (a cut failure NEVER fails the burn)
```

**Reading the diagram — server.** After `runAnalogJob` uploads the whole-album mp3 (which is
still in `tmp`), it loops the album's analog songs and, for each, derives the cut length via
**`cutDurationMs`** — the catalog `length`, else the manifest `durationMs`, else **derived from
the segment boundaries** (`pointer.endMs - startMs`), since many analog tracks carry start/end
boundaries but a **null** `length`. With a usable `startMs` + duration it `ffmpeg -ss …-t …`
slices the song out, **tags it** title/artist/album as **ID3v2.3**, and `aws s3 cp`s it to
**`rips/<songId>.cut.mp3`** — under the **public `rips/` prefix** (the bucket policy makes only
`rips/*` public) and distinguished from a per-song *cloud* rip's `rips/<songId>.mp3` by the
**`.cut.` infix** — then records `cutKey`/`cutBytes`/`cutRippedAt` on the manifest entry (and
persists the derived `durationMs` if it was null). A per-cut failure is **non-fatal** (the
album entry alone still plays and is the backcase), and a cancel/error mid-loop breaks out and
cleans the temp cut. The watchdog's analog cap was raised **12 → 20 min** to cover the extra
ffmpeg+upload passes (§3.1).

Two **out-of-queue** endpoints (single-flight via `backfillRunning`, returning a candidate
count immediately and logging progress) cover albums ripped *before* the feature and tag fixes:
**`POST /backfill-cuts`** retro-slices every analog entry **missing** a `cutKey` straight from
the **raw album source** (no whole-album re-transcode), giving old albums the per-song export
retroactively; **`POST /retag-cuts`** does a **tag-only remux** of *every existing* cut —
download, `ffmpeg -c copy -map_metadata -1` with fresh title/artist/album, re-upload — so **no
re-encode and no source drive are needed**, and it **bumps `cutRippedAt`** so the app's
S3-timestamp auto-repull (below) pulls the re-tagged file. Both share the in-memory `manifest`
object so a concurrent rip's `saveManifest` won't drop the new `cutKey`s.

**Reading the diagram — device (`BurnStore.exportAnalogCuts`).** The Burn loop calls this
**in-process, inside the held burn-folder scope**, after writing the per-song sidecars. For
each analog song whose manifest entry carries a `cutKey` it names the cut with the **per-song
`digitalSongPrefix`** (digital-style, so the single-track cut pairs with the per-song sidecar,
distinct from the album-level whole-file name, §9.0) and decides whether to (re)download via an
**auto-repull check**: `RipsStore.remoteLastModifiedMs` HEADs the public cut URL and parses its
**`Last-Modified`** into epoch-ms (RFC-1123, fixed POSIX/GMT); if the device's
`cutDownloadedAt` is **≥** that, the local cut is up-to-date and **kept** — but a **newer** S3
`Last-Modified` (which a manual `/retag-cuts` or re-upload bumps) means the cut is stale and
gets re-pulled, **with no manifest change required**. Offline (HEAD failed) with a local cut
present keeps it (never clobber). On a (re)download it fetches the bytes (`downloadBytes`), and
**only after the new bytes are in hand** deletes the **old** cut (both the previously-recorded
name — in case the descriptive name changed — and the current target) so an updated, re-tagged
version cleanly replaces the prior file without ever losing the existing one on a failed
download, writes atomically, and records `cutFileName`/`cutDownloadedAt`. A cut failure
**never fails the burn**. The `BurnItem` gains **`cutFileName`/`cutDownloadedAt`** (both
optional for back-compat decode), and `finalizeBurn` **preserves** them when the later
background album-download finalizes the item (otherwise rebuilding the item would drop the cut
fields written during the in-process cut pass).

---

## 15. Stems end-to-end — server Stemify, offline stem store, and stem audition

**Why.** Mixing the *parts* of a track — drop the vocal, ride the drums — is the marquee
DJ move the Mix engine's **stem decks** (Ch. 4 §7.6) want. That needs four isolated stems
per song, computed once on the iMac and carried to the phone like any other rip. So
**Stemify** is a third capture pipeline beside analog-rip and digital-rip: the rip server
runs **Demucs** to separate a song into four stems, uploads them to the **public** rips
cache, and stamps the manifest — and the Burn (§9) pulls them so a burned collection
**mixes** fully offline.

**Source of truth:** the rip server's stem pipeline + endpoints in
[`scripts/rip-server.mjs`](../../scripts/rip-server.mjs) (`stemQ`, `applyStems`,
`/stemify*`, `/backfill-stems`) and the separator
[`scripts/lib/audio-stem.mjs`](../../scripts/lib/audio-stem.mjs) +
[`scripts/stems-index.sh`](../../scripts/stems-index.sh); the Docker/Python assets under
[`.claude/skills/analog-indexer/stems/`](../../.claude/skills/analog-indexer/stems/)
(`Dockerfile`, `separate-one.py` — a sub-asset of the analog-indexer, sibling to the
librosa `audio/` stage); the device side in
[`apple/PocketDJ/Playback/StemPlayer.swift`](../../apple/PocketDJ/Playback/StemPlayer.swift)
+ [`apple/PocketDJ/Views/StemAuditionPanel.swift`](../../apple/PocketDJ/Views/StemAuditionPanel.swift)
(audition) and the manifest reader in
[`apple/PocketDJ/State/RipsStore.swift`](../../apple/PocketDJ/State/RipsStore.swift)
(`stems`/`stemVersion`/`isStemmed`/`stemURLs`). Design:
[`docs/design/stems-demucs-stemify-spec.md`](../design/stems-demucs-stemify-spec.md).

```
 SERVER — POST /stemify {songId}  (or /stemify-collection, /backfill-stems[stale-only])
   source-select (mirrors beatgrid): digital → its rips/<id>.mp3 ; analog → its CUT rips/<id>.cut.mp3
        (stems are PER-SONG, keyed by songId — an analog song stems its cut, NEVER the album side)
   dedicated concurrency-1 stemQ  (durable intent <tmp>/stem-queue/<songId>.json,
        watchdog ~30min, STEM_MAX_ATTEMPTS=3 poison cap, DEFERS while a real-time capture runs)
   Demucs htdemucs (v4 default; POCKETDJ_DEMUCS_MODEL) → 4 stems vocals/drums/bass/other, mp3 256k
        runtime: native MPS on Apple Silicon (default) · Docker-CPU pocketdj-stems (fallback)
   aws s3 cp → rips/stems/<songId>/<stem>.mp3   (PUBLIC rips/ prefix)
   applyStems(entry): stems{vocals,drums,bass,other}=keys · stemModel · stemVersion(=1) ·
                      stemFormat · stemmedAt · stemBytes      (additive; presence ⇒ stemmed)
        │
        ▼  GET /health → { …, stems:true }   (capability flag — NO protocol bump)
 DEVICE — burn pulls them (§9 burnCollectionStems) → stem-<songId>-<part>.mp3 in the burn folder
   Mix stem decks (Ch.4 §7.6)  ·  SongDetail stem-audition panel (§15.2)
```

**Reading it — the server.** `/stemify` (per-song), `/stemify-collection` (batch, capped),
`/stemify-cancel` (Stop), and `/backfill-stems` (re-stem only stale/missing) all feed a
**dedicated concurrency-1 `stemQ`** that is separate from the rip queue, with its own
durable per-`songId` intent dir, a ~30-min watchdog, a `STEM_MAX_ATTEMPTS = 3` poison-input
cap, and a gate that **defers stemming while a real-time rip capture is running** (CPU/GPU
contention). The source is **per-song**: a digital song stems its own mp3, an analog song
stems its **per-song cut** (§14) — never the shared album side — so stems are always keyed by
`songId`. Separation runs **Demucs `htdemucs`** (v4, the one `POCKETDJ_DEMUCS_MODEL` knob;
4-stem only) producing **`vocals`/`drums`/`bass`/`other` as 256 kbps mp3**, preferring the
**native MPS** runtime on the Apple-Silicon iMac and falling back to a **Docker-CPU**
(`pocketdj-stems`) image. The four files upload to the **public** `rips/stems/<songId>/`
prefix and `applyStems` folds the additive `stems`/`stemModel`/`stemVersion`/`stemFormat`/
`stemmedAt`/`stemBytes` fields onto the manifest entry (§5) **only after all four upload**.
`GET /health` advertises the capability as a plain **`stems: true`** flag — no `RIP_PROTOCOL`
bump, since the fields are additive and old clients simply ignore them. Stemming is
**idempotent** (already-stemmed at the current version+model ⇒ skip).

### 15.1 The beat-grid indexer — a measured downbeat grid for Sync

**Why.** The catalog `bpm` and the per-rip analysis `bpm` are single numbers; **beat-matching**
(Ch. 4 §7.4) wants a *grid* — a real downbeat phase and a tempo measured on the **exact file**
that will play — so two decks can phase-align, not just tempo-match. So a separate analysis
pass computes a **librosa downbeat grid** and folds it into the manifest.

**`POST /backfill-beatgrids`** (background, idempotent, single-flight, resumable) walks the
corpus and runs `analyzeBeatgridForSong(songId)` — sourcing the **same per-song audio the
stemmer does** (digital → its mp3, analog → its cut) and calling the librosa analyzer
(`scripts/lib/audio-analyze.mjs`, `analyzeAudio(… withBeatgrid:true)`). `applyBeatgrid` writes
**`firstBeatMs`, `firstDownbeatMs`, `beatGridBpm`, `beatsPerBar`, `tempoConfidence`,
`tempoVar`, `steady`**, plus a **`beatgrid`** S3 key (a lazy per-beat sidecar
`rips/analysis/<id>.json`) and an **`analysisVersion`** stamp. That version is the **shared
bpm/key/beat-grid `ANALYSIS_VERSION`** (distinct from the stems' own `stemVersion`), so a
Demucs model change never forces a beat-grid re-run and vice-versa. The Mix engine reads the
grid at load via `BurnStore.beatGrid(forSong:)` → `manifest[id]`'s `beatGridBpm`/
`firstDownbeatMs`/`steady`, and **prefers `beatGridBpm` over the catalog `bpm`** when syncing
(Ch. 4 §7.4). The native `ManifestEntry` decodes all of these as optionals (Ch. 3 §4.3), so an
un-gridded song just falls back to the catalog tempo.

### 15.2 The SongDetail stem-audition panel — burn-then-play-in-sync

**Why.** Before committing stems to a live mix, the DJ wants to *hear* the isolated parts —
solo the vocal, mute the drums — right on the song's detail screen. The
**`StemAuditionPanel`** is that: a SongDetail-only panel that **burns the four stems locally
then plays them back perfectly in sync**, fully offline.

**Source of truth:**
[`apple/PocketDJ/Playback/StemPlayer.swift`](../../apple/PocketDJ/Playback/StemPlayer.swift)
(the 4-node sync engine),
[`apple/PocketDJ/Views/StemAuditionPanel.swift`](../../apple/PocketDJ/Views/StemAuditionPanel.swift)
(the panel; the `StemPlayer` is owned by `SongDetailView` so it survives panel re-renders).

```
 StemAuditionPanel.task(id: song.id):  phase=.burning → burns.burnStems(forSong:) → (urls, release)
   → player.load(songId:, localURLs:, release:) → phase=.ready          (LOCAL FILES ONLY — no stream)

 StemPlayer (@MainActor @Observable):  4× AVAudioPlayerNode → engine.mainMixerNode → output
   startSynced(from:): scheduleSegment each stem, start ALL at ONE shared AVAudioTime → sample-accurate
   lead node (prefers vocals) owns the end signal ; a generation counter voids stale completions
   solo/mute = node.volume 0|1 (glitch-free) ; per-stem rows + shared TimelineView scrubber + "Play All"
```

**Reading it.** On appear the panel sets `phase = .burning`, calls
**`BurnStore.burnStems(forSong:)`** (idempotent — returns existing local files, or burns the
four and returns them, **with the security scope held** via a `release` closure), then
`StemPlayer.load(songId:localURLs:release:)` and `phase = .ready`. **`StemPlayer`** runs four
`AVAudioPlayerNode`s into the engine main mixer; `startSynced` schedules every stem and starts
**all of them at one shared `AVAudioTime`**, so they're **sample-accurate**; a **lead node**
(preferring `vocals`) owns the end-of-track signal and a **generation counter** invalidates
stale schedule-completions after a seek/stop. **Solo/mute** is an instant, glitch-free
`node.volume` toggle (0/1). The panel renders per-stem solo/mute rows, a shared
`TimelineView` scrubber, and a centered **Play-All** master. Like the Mix stem decks it is
**offline-only** — it plays **local burned files**, never a stream — and `.onDisappear`
releases the held folder scope.

## Next

→ [Chapter 6 — Search & Discovery](./06-search-and-discovery.md)
