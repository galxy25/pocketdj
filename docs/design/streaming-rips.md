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

## Open items

- Per‑track analog **timestamps** are deferred → analog plays the whole album and the
  user seeks (per decision). If timestamps land later, the manifest gains `startMs`
  and the player can auto‑seek.
- Apple Music DRM: even "downloaded" subscription files are FairPlay‑protected, so the
  real‑time Audio Hijack capture is required regardless of local download.
- Full‑album Apple Music rips are sequential real‑time captures (could be long) — warn
  on album play‑all.
