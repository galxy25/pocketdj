# Design — Stream / download any song (rip‑on‑demand)

**Status:** SHIPPED to prod 2026‑06‑19 — Phase 1 (analog) + Phase 2 (Apple Music
real‑time) + setlist Rip‑all/Play‑all/Burn + a durable filesystem queue. See
"Running it" and "What shipped" below.

## Running it

1. **Rip server** (on the iMac): `node scripts/rip-server.mjs`
   (env: `POCKETDJ_ANALOG_BASE` for analog recordings — default `~/Downloads`;
   `RIP_TOKEN` to require a bearer token; `RIP_AGENT=1` to run rips via a headless
   Claude agent instead of the direct worker; `POCKETDJ_LIBRARY_XML` — default
   `~/Downloads/Library.xml`).
2. **Expose it over HTTPS** so the deployed PWA can reach it (mixed‑content +
   tailnet): `tailscale serve --bg http://localhost:8787`
   → `https://<node>.<tailnet>.ts.net`.
3. **App** ▸ Settings ▸ Rip server → that URL (+ token if set) ▸ Test connection.
   Then ▶/⤓ on any song/album, or a set list's **Rip all / Play all / Burn**.
4. **Reindex the rip catalog** = the rip server reads the same `public/*.json`
   indexes; regenerate those (analog‑indexer / apple‑music‑indexer) + restart it.

## What shipped (vs. the design below)

- `scripts/rip-server.mjs` — the API (`/health`, `/status/:songId`, `POST /rip`,
  `GET /jobs/:id`), single‑flight queue, **durable filesystem queue**
  (`~/.pocketdj/rips/queue/<songId>.json`, re‑enqueued on restart, idempotent).
- `scripts/rip-one.mjs` — single‑song worker: drives the `rip` skill (real‑time
  Audio Hijack capture) → mp3 256 → upload, writing live phases to the status file.
  Run directly (default) or via a Claude agent (`RIP_AGENT=1`) that can add a
  missing track to the library + retry.
- App: `useRipsStore` (manifest, config, per‑song job polling, play‑through queue,
  rip‑all, burn), `RipButtons`, `MiniPlayer`, Settings ▸ Rip server, and the
  set list **Rip all / Play all / Burn**.
- **Background audio analysis** (`scripts/lib/audio-analyze.mjs`): after each rip,
  BPM + key + Camelot (Docker `pocketdj-audio`/librosa) + a **waveform PNG**
  (ffmpeg) → uploaded to `rips/waveforms/<id>.png`. BPM/key/Camelot are written into
  the manifest and **rolled into the catalog** client‑side (fill‑gaps only). The
  waveform is **lazy‑loaded** and rendered as a clickable **scrub bar** in the player.
  Runs for both API‑ and skill‑ripped songs (`scripts/analyze-rip.mjs --dir
  <_ripped>` bridges the skill's setlist output → upload + analyze + `POST /analysis`).
  Durable: un‑analyzed manifest entries are re‑queued on server restart.
- Verified end‑to‑end on a real device: an Apple Music track ripped → uploaded →
  streamed; analog fast path; durable‑queue resume.

## Goal

From any song or album row in the PWA browser, tap **▶ Play** (stream) or
**⤓ Download**. If we've ripped it before, it plays instantly from S3. If not, the
PWA asks the **iMac** (over Tailscale) to rip it on demand via the `rip` skill,
upload it to a public S3 rips bucket under a deterministic name, then the client
streams / downloads it.

## Principles

1. **Deterministic, content‑addressed cache.** Rip once → available forever; the
   client can check availability without asking the iMac.
2. **The iMac is only needed to *create* a rip.** Once it's in S3, playback works
   anywhere. The network dependency is just the rip action.
3. **Two rip speeds.** Analog / DRM‑free files are a fast extract (seconds);
   Apple Music subscription tracks need a **real‑time** capture (≈ song length).
   The UX makes this visible via polled status.

## Locked decisions (Phase 1)

| # | Decision |
|---|---|
| Flow | **Wait‑for‑rip‑then‑stream** (no live relay yet). |
| S3 | **Separate PUBLIC bucket** `pocketdj-rips-011183829623`, public‑read, streamed directly. Private + app‑credential fetch is a later phase. |
| Format | **MP3 @ 256 kbps.** |
| Analog | Base path from env var `POCKETDJ_ANALOG_BASE` (default `~/Downloads`). Rip the **whole album** file; client seeks to the track. |
| Keying | Apple Music → `rips/<songId>.mp3`; Analog → `rips/<albumId>.mp3` (album shared by its songs). Manifest maps `songId → key`. |

## Component architecture

```
 ┌─────────────── PWA (phone/laptop, CloudFront HTTPS) ───────────────┐
 │  Browser list → [▶ Play] [⤓ Download] per song/album               │
 │  useRipsStore (per-song job state)  ·  mini audio player           │
 │  Settings ▸ Rip server: base URL + token                           │
 └───────┬───────────────────────────────────────────┬───────────────┘
         │ 1. check rips/manifest.json (public)        │ 4. <audio src> stream
         │                                             │    / fetch→blob download
         │ 2. POST /rip {songId}  → jobId  (Tailscale  ▼
         │    HTTPS, only on cache miss)        ┌──────────────────┐
         │ 3. poll GET /jobs/:id  (~1s)         │ S3 public bucket │
         ▼                                      │  pocketdj-rips-… │
 ┌─────────────── iMac rip API (this machine) ─┴───────▲──────────┘
 │  Node HTTP server  ·  job queue (single-flight, conc 1)         │
 │  per job → status file ~/.pocketdj/rips/jobs/<id>.json          │
 │  per job → spawn headless Claude agent (filesystem access) ─────┘
 │     └─ runs `rip` skill:
 │        ├─ FAST (analog @ POCKETDJ_ANALOG_BASE / DRM-free): ffmpeg → mp3 256
 │        └─ SLOW (Apple Music): Music + Audio Hijack capture (1×) → mp3 256
 │     └─ upload rips/<key>.mp3 + update rips/manifest.json (profile levi)
 │  exposed via `tailscale serve https` (valid *.ts.net TLS cert)  │
 └─────────────────────────────────────────────────────────────────┘
```

## End‑to‑end flows

**A. Cache hit:** client sees `songId` in `rips/manifest.json` → resolves the public
URL → `<audio>` streams it (S3 REST supports range → seek/scrub). No iMac.

**B. Cache miss — fast (analog / DRM‑free):** `POST /rip` → agent resolves the album
recording at `POCKETDJ_ANALOG_BASE/<pointer.location>/<pointer.filename>` → ffmpeg
transcode whole album → mp3 256 → upload `rips/<albumId>.mp3` → manifest → ready.
**Seconds.** (Per decision: whole album; user seeks.)

**C. Cache miss — slow (Apple Music):** `POST /rip` → `searching` (find/add track in
Music) → `ripping` (Audio Hijack real‑time capture) → `uploading` → `ready`. Button
shows live phase + a `mm:ss / mm:ss` bar. **≈ song length.** Cached after first rip.

## Job state machine (poll‑based)

```
queued → searching → ripping → uploading → ready
                                         ↘ error (any phase)
```

| Phase | Meaning | Button label |
|---|---|---|
| `queued` | waiting behind another rip (conc 1) | `Queued…` |
| `searching` | S3 check → resolve source → add‑to‑library if needed → cue | `Searching…` |
| `ripping` | real‑time capture or ffmpeg extract | `Ripping… 1:23 / 3:45` |
| `uploading` | PUT object + manifest update | `Uploading…` |
| `ready` | in S3; URL resolvable | ▶ / ⤓ (auto‑acts on the click intent) |
| `error` | with message | `⚠ Retry` |

### Poll protocol

```
click ▶/⤓
  → POST /rip {songId}           → 200 { jobId, songId, phase }   (non-blocking, single-flight)
  → poll GET /jobs/:jobId (~1s)  → { phase, progress?, message?, url?, error? }
       until phase ∈ {ready, error}
  → ready: cache url in useRipsStore[songId]; play (or download)
```

- `POST /rip` never blocks; returns a `jobId` immediately. A duplicate request for the
  same song (or a second device) **joins** the running job (same `jobId`).
- `GET /jobs/:jobId` response:
  ```json
  { "jobId":"…", "songId":"sng_abc", "phase":"ripping",
    "progress": { "elapsedMs":83000, "totalMs":225000, "pct":37 },
    "message":"capturing via Audio Hijack", "url":null, "error":null }
  ```
  `progress` only in `ripping`; `url` only in `ready`.
- Cadence 1 s while active; client knows `totalMs` (index `lengthMs`) so it animates the
  bar between polls. Stop on `ready`/`error`.

### Phase reporting (agent → API, non‑blocking)

Decoupled via a **per‑job status file** so the poll endpoint reflects the spawned
agent without the API blocking on it:

```
API: create job → write ~/.pocketdj/rips/jobs/<jobId>.json {phase:"searching"}
     spawn agent with $JOB_ID + $STATUS_FILE
agent (rip skill) updates the file at each transition:
     searching → {phase:"searching"}
     capture start → {phase:"ripping", ripStartedAt, totalMs}
     upload → {phase:"uploading"}
     exit 0 with final JSON {ok, key, ext, durationMs}
GET /jobs/:id → reads file; on 'ripping' computes elapsedMs = now − ripStartedAt
               (capped at totalMs) → pct. So the progress bar is free.
```

### Resume after reload / second device

Polling is stateless. On mount, the client calls **`GET /status/:songId`** for songs it
cares about → active job returns `{ jobId, phase }` (resume polling); finished returns
`{ ready, url }`. Two devices watching one rip both poll the same `jobId`.

*(Chose polling over SSE/WebSocket: simpler, survives the agent process boundary via the
status file, reconnects for free, tiny cadence.)*

## iMac rip API

Node server, exposed by `tailscale serve https /` → `https://<imac>.<tailnet>.ts.net`.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | reachability + version (client gates buttons on this) |
| `GET` | `/status/:songId` | `{ ready, url?, job? }` |
| `POST` | `/rip` `{songId}` | start/join a job; idempotent single‑flight |
| `GET` | `/jobs/:jobId` | poll: phase + progress + url/error |

- **Job queue:** in‑memory; **concurrency 1** for real‑time rips (Music/Audio Hijack
  play one thing at a time); fast extracts may use a small pool. Single‑flight per
  `songId`/`albumId`.
- **Auth:** bearer token (entered in Settings) on top of the Tailscale boundary.
- **CORS:** allow app origins (`d2p4cubg6se03u…`, dev CloudFront, `localhost`).

## The Claude rip agent

Each rip job spawns a **headless Claude agent with filesystem access** that runs the
`rip` skill with the resolved song metadata:

```
rip songId=sng_abc source=apple-music persistentId=1F14… title=… artist=…   (or)
rip songId=sng_abc source=analog albumId=alb_… file=$POCKETDJ_ANALOG_BASE/…
   → FAST: ffmpeg transcode (analog whole album / DRM-free) → mp3 256
   → SLOW: drive Music + Audio Hijack capture → mp3 256
   → upload s3://pocketdj-rips-…/rips/<key>.mp3 (profile levi); update manifest
   → print final JSON {ok, key, ext, durationMs}; write phases to $STATUS_FILE
```

The agent is the right tool for the adaptive **slow** path (find/add the track in
Music, drive Audio Hijack, handle "not in library"). **Optimization:** the API runs a
plain script (no agent) for the deterministic **fast** analog/DRM‑free path; reserve
the agent for Apple Music captures.

## S3 layout & access (Phase 1 = public)

- **Bucket** `pocketdj-rips-011183829623` (us‑west‑2), **public‑read** on `rips/*`,
  **CORS** allowing the app origins (so the client can `fetch→blob` for downloads;
  plain `<audio src>` streaming needs no CORS but range works either way).
- **Keys:** `rips/<songId>.mp3` (Apple Music) · `rips/<albumId>.mp3` (analog).
- **Manifest:** `rips/manifest.json` (public) — `{ "<songId>": { key, ext:"mp3",
  bytes, durationMs, source, albumId?, rippedAt } }`. Client loads once to mark
  "instant" rows; API rewrites it after each rip.
- **Streaming:** `<audio src="https://pocketdj-rips-….s3.us-west-2.amazonaws.com/rips/<key>.mp3">`.
- **Download:** `fetch` the public URL → blob → save with a nice filename
  (`Artist – Title.mp3`).

> ⚠️ Public bucket = these (copyrighted, personal) rips are publicly fetchable by
> anyone with the URL. Accepted for now per decision; **Phase 4** moves to a private
> bucket with app‑credential presigned/CloudFront‑signed access.

## PWA client

- **Buttons:** every song row + album card gets **▶** and **⤓**. Album ▶ = play‑all
  queue; album ⤓ = download‑all. State per song in `useRipsStore[songId]`, so the
  clicked button shows its own phase while other rows stay idle.
- **Mini player** (bottom bar): play/pause, scrub, prev/next, now‑playing.
- **Settings ▸ Rip server** (mirrors the Online‑search panel): base URL + token +
  **Test connection** (`/health`). Buttons light up when the server is reachable
  **or** the song is already in S3.
- **States:** server offline → "Rip server offline" but cached songs still play;
  can't‑rip (not in Apple Music, no analog file) → error + "add to library" hint.

## Networking & security

- **Tailscale HTTPS** via `tailscale serve` gives the iMac a real cert at `*.ts.net`
  — required because the PWA is HTTPS and browsers block HTTPS→HTTP (mixed content).
- Off‑tailnet: can't *create* rips, but anything already public in S3 still plays.

## Phased build plan

- **Phase 1 — plumbing + analog fast path.** ✅ DONE. Public rips bucket + manifest;
  iMac API; analog ffmpeg fast path; Settings panel + ▶/⤓ + mini player; poll UX.
- **Phase 2 — Apple Music rips.** ✅ DONE. `rip` skill real‑time capture via
  `rip-one.mjs` (direct or `RIP_AGENT=1` Claude agent); searching/ripping/uploading.
- **Phase 3 — set list batch + durable queue.** ✅ DONE. Set list **Rip all /
  Play all** (rip‑ahead, auto‑advancing mini player) / **Burn** (zip download);
  durable filesystem queue (restart‑resumable, idempotent).
- **Phase 4 — private delivery.** ⏳ FUTURE. Private bucket + app‑credential
  (presigned or CloudFront‑signed) fetch; live‑relay progressive streaming.

---

# Near‑real‑time streaming (play while it rips)

> Goal: hitting **▶** on an un‑ripped song starts playback within **~1–5 s**, then
> keeps playing as the rip continues — instead of waiting for the entire
> capture → transcode → upload before any sound. The current model is *rip‑then‑play*;
> this adds *play‑while‑ripping*.

## Why this is mostly an Apple‑Music problem

- **Apple Music** capture is **inherently real‑time**: a 3‑minute song takes 3
  minutes to record (Audio Hijack plays it in Music and captures the output). Today
  the user waits 3 min + transcode + upload (~3.5 min) before the first note. With
  live streaming they hear it ~2–4 s after capture starts and **listen along, live**.
  This is the headline win.
- **Analog** is already *faster than real‑time* (a whole album ffmpeg‑transcodes in
  seconds). The only wait is the S3 upload of a ~60 MB album mp3. The same live
  endpoint removes that wait too, but the payoff is smaller.

So the design centers on **serving audio bytes as they are produced**, for both
sources, behind one client change.

## Core idea — tail‑stream a growing MP3 as a progressive HTTP response

MP3 is a flat stream of self‑contained frames with no trailing index, so a browser
`<audio>` element plays an MP3 **as it arrives** — this is exactly how internet radio
(Shoutcast/Icecast) plays in Safari/iOS today. We exploit that:

1. The capture writes a **growing `.mp3`** on the iMac:
   - **Apple Music:** Audio Hijack's Recorder **already records MP3** (verified:
     captured files probe as `format_name=mp3`), so its in‑progress recording file
     grows frame‑by‑frame during capture — directly tail‑streamable, **no reconfig
     needed**. *(m4a/ALAC would **not** be progressively streamable — the MP4 `moov`
     index is written at the end — so the recorder must stay on MP3/ADTS‑AAC; the
     server detects the extension and falls back to rip‑then‑play if it ever changes.)*
   - **Analog:** `ffmpeg` already writes mp3 256 progressively as it transcodes.
2. New rip‑server route **`GET /stream/<songId>.mp3`**: finds the in‑progress
   recording file for that song's active job and **tail‑streams** it —
   `Transfer‑Encoding: chunked`, no `Content‑Length`, no `Accept‑Ranges` (so the
   browser treats it as a live stream): read to current EOF, `flush`, wait for the
   file to grow (`fs.watch`/size‑poll), repeat, until the job's capture phase ends;
   then stream the final bytes and close the response.
3. **Initial buffer (the 1–5 s):** withhold the response until ~1.5–2 s of audio
   exists (≈ 48–64 KB at 256 kbps), giving the browser a jitter cushion before play.
   Tunable via `RIP_STREAM_PREROLL_BYTES`.
4. **Client:** on **▶**, `POST /rip` as today. As soon as the job reports a new phase
   **`streaming`** with a `streamUrl`, set `nowPlaying.url =
   https://<imac‑tailnet>/stream/<songId>.mp3` and play via the **existing native
   `<audio>`** element — *no `hls.js`, no new client dependency*. The phase chip shows
   "streaming" instead of blocking on "ripping…".
5. **Durable swap:** the rip finishes exactly as before — archive mp3 → S3 →
   `manifest.json` → background bpm/key/waveform analysis. The live stream is
   ephemeral. On **replay** (or any later play) the client uses the **seekable S3
   mp3**, which supports range requests, scrubbing, offline burn, and the waveform.
   So live‑stream = first listen; S3 = every listen after.

### Why progressive MP3 over the rip server (not HLS, not S3)

- **Latency:** the iMac and the phone are on the same **Tailnet**; serving bytes
  straight from the rip server is ~segment‑free and sub‑second. Routing live audio
  through S3 would add an upload round‑trip per chunk — the opposite of "near‑real‑time."
- **Simplicity:** native `<audio>` already plays progressive MP3 on desktop **and
  iOS** (radio‑stream precedent). HLS would add segmenting + a live `.m3u8` rewrite +
  `hls.js` in the client for a robustness we don't yet need.
- **Durability is already solved:** S3 + manifest + analysis stay the archive of
  record; the live path only has to get *first audio* out fast.

## Server changes (`rip-server.mjs` / `rip-one.mjs`)

- A job exposes its **in‑progress file path** + a `streamReady` flag once pre‑roll
  bytes exist. New phase **`streaming`** (between `ripping` and `uploading`) carries
  `streamUrl`. `jobView()` emits it; `/jobs/:id` already merges the worker's status
  file, so the worker just records `streamFile` + `streamReady` as it captures.
- **`GET /stream/<songId>.mp3`** — auth‑gated like the rest; tails the file with
  chunked encoding + pre‑roll; ends when capture completes or the client disconnects
  (clean up the read stream / watcher). Bounded so a stuck capture can't leak fds.
- **Apple Music:** `rip.mjs` / `rip-one.mjs` detect the new AH recording file *right
  after `AH.start()`* (diff `AH_REC_DIR`), publish its path as `streamFile`, and set
  `streamReady` once it crosses the pre‑roll size. AH already records MP3 (verified),
  so no session reconfig is needed — the `rip` SKILL just documents the requirement.
- **Analog:** stays **rip‑then‑play** in 5a — it's already faster‑than‑real‑time and
  the whole‑album file + per‑track seek make live streaming awkward (you'd have to
  start mid‑file at a VBR‑imprecise byte offset). The small upload wait is acceptable;
  a per‑track‑region live tee is deferred.

## Client changes (`useRipsStore` / `MiniPlayer`)

- `ensureUrl()` gains a fast path: stop blocking until `ready`; resolve as soon as the
  poll sees **`streaming`** + `streamUrl`, returning the live URL so play starts now.
  Keep polling in the background to capture the final S3 `url` for the manifest swap.
- `NowPlaying` gains `live?: boolean`. While `live`, the player hides the seek bar's
  forward region (can't seek past the buffered live edge) and shows a small **● LIVE**
  tag; on the durable swap it flips to the normal seekable bar + waveform.
- `MiniPlayer` needs no new element — progressive MP3 plays through the same
  `<audio>`. Add a tiny `onError`/stall fallback: if the live stream stalls, fall back
  to polling for the S3 `url` and reload (the rip is still completing server‑side).

## Edge cases & risks

- **Connection drop mid‑song:** a chunked live response can't resume at an offset
  until the S3 mp3 exists. Mitigation: on stall, the client polls for the (likely
  now‑ready) S3 url and seamlessly reloads. Acceptable for "first listen."
- **iOS Safari:** progressive/endless MP3 is supported (radio streams), but iOS is
  picky about range requests — the `/stream` endpoint must answer the initial
  `Range: bytes=0-` with **`200`** (whole live stream), not `206`. Verify on device.
- **Pre‑roll vs latency:** larger pre‑roll = smoother start but more lead; expose
  `RIP_STREAM_PREROLL_BYTES` and tune to land in the 1–5 s target.
- **AH format:** the tail approach **requires** an MP3/ADTS recorder. If the user
  keeps AH on m4a, fall back to *rip‑then‑play* (today's behaviour) for that song —
  detected by extension, no hard failure.
- **DRM unchanged:** still a real‑time line‑capture; nothing here touches FairPlay.

## Live HLS — the shipped path (was "Phase B")

Progressive MP3 (5a) worked on desktop but was **silent on iOS Safari**: iOS won't
reliably play an endless, length‑less chunked MP3 via `<audio>` (the finished S3 mp3
played fine, the live stream produced no sound). HLS is Apple's own format and plays
natively on iOS, so the live path moved to **live HLS**:

- **Worker:** once AH's growing MP3 appears, `tail -c +1 -f <mp3> | ffmpeg -i pipe:0
  -c:a aac -b:a 128k -hls_time 2 -hls_playlist_type event …` writes 2 s AAC/TS
  segments + a rolling `index.m3u8` to `<tmp>/live/<songId>/`. `tail -f` follows the
  file as AH records; on capture end the worker kills `tail`, ffmpeg sees EOF and
  finalizes the playlist (`#EXT-X-ENDLIST`). `streamReady` flips on the first segment.
- **Server:** `GET /hls/<songId>/<index.m3u8|seg_N.ts>` (same `?token=` auth as
  `/stream`). The m3u8's segment URIs are rewritten to carry `?token=` so a native
  `<audio>`'s segment fetches authenticate (it can't add an auth header). `jobView`'s
  `streamUrl` → `/hls/<id>/index.m3u8`.
- **Client:** if `<audio>.canPlayType('application/vnd.apple.mpegurl')` (iOS/Safari) →
  native `<audio src=m3u8>`; otherwise lazy‑load **hls.js** (a separate chunk Safari/iOS
  never download) and attach. `canPlayType` can lie (some Chromium claim support but
  can't play) → on a source error, fall back to hls.js. `● LIVE` player state; the
  background poll still swaps the manifest to the durable S3 mp3 for the next play.

The 5a progressive `/stream` endpoint is kept (harmless) but the client uses HLS.

## Phase plan

- **Phase 5a — progressive live stream.** ✅ DONE (desktop). `/stream` tail‑endpoint +
  `streaming` phase + pre‑roll; AH growing‑MP3 watcher; client `allowLive` fast path +
  `● LIVE`. iOS‑silent → superseded by 5b for the live path.
- **Phase 5b — live HLS.** ✅ DONE. `tail|ffmpeg` event‑HLS producer; `/hls` serving
  with token‑rewritten segment URIs; client native‑HLS + lazy `hls.js` fallback.
  iOS plays natively. (Off‑Tailnet via S3/CloudFront stays a Phase 4 follow‑up.)

## Open items

- Per‑track analog **timestamps** are deferred → analog plays the whole album and the
  user seeks (per decision). If timestamps land later, the manifest gains `startMs`
  and the player can auto‑seek.
- Apple Music DRM: even "downloaded" subscription files are FairPlay‑protected, so the
  real‑time Audio Hijack capture is required regardless of local download.
- Full‑album Apple Music rips are sequential real‑time captures (could be long) — warn
  on album play‑all.
