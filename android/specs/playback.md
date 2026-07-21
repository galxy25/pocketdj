# PocketDJ Android — Playback + Rips contract (Phase 1)

**Audience:** an engineer building the Android side who has never seen the iOS app.
Every claim cites the iOS/server source of truth (`file:line` relative to the repo
root). Where Android Phase 1 deliberately cuts scope, the cut is called out as
**Phase-1 cut** with the later phase noted.

Sources of truth:

- `apple/PocketDJ/Support/Config.swift` — base URLs
- `apple/PocketDJ/State/RipsStore.swift` — manifest + URL resolution + rip client
- `apple/PocketDJ/Playback/PlaybackCoordinator.swift`, `RipServerPlaybackProvider.swift`, `PlayerEngine.swift` — how ▶ resolves and plays
- `scripts/rip-server.mjs` — the server endpoints (protocol version 2, `scripts/rip-server.mjs:206`)
- `apple/PocketDJ/Support/DeviceIdentity.swift` — identity headers

---

## 1. Base URLs

| Thing | Value | Source |
|---|---|---|
| Catalog CloudFront (prod) | `https://d2p4cubg6se03u.cloudfront.net` | `Config.swift:17` |
| Catalog CloudFront (dev) | `https://djictbz9w796r.cloudfront.net` | `Config.swift:16` |
| Public rips bucket (`ripsBase`) | `https://pocketdj-rips-011183829623.s3.us-west-2.amazonaws.com` | `Config.swift:22`; server-side mirror `scripts/rip-server.mjs:69,150-151` |
| Rip server | **NO shipped default.** User-entered in Settings; empty ⇒ `hasServer == false` and every server feature shows a "no server configured" state | `Config.swift:24-33`, `RipsStore.swift:211-213` |
| Rip server default port (LAN/tailnet) | `8787` (`RIP_PORT`) | `scripts/rip-server.mjs:48` |
| Rip server public posture | Tailscale Funnel HTTPS port `10000` (the user pastes the full Funnel URL into Settings; the client never derives it) | `scripts/setup-rip-funnel.sh:8-11,26` |

Client-side URL hygiene: trim whitespace and **one** trailing slash off the stored
server URL before concatenating paths (`RipsStore.swift:211`, `RipsStore.swift:1586-1589`).

Android mapping: store `ripServerUrl` + `ripToken` in DataStore (Settings screen),
both defaulting to `""`.

---

## 2. The rips manifest (the map from songId → audio)

### 2.1 Fetch

```
GET https://pocketdj-rips-011183829623.s3.us-west-2.amazonaws.com/rips/manifest.json
```

- URL construction: `ripsBase + "rips/manifest.json"` (`RipsStore.swift:259`).
- Plain public S3 GET — **no auth, works with the rip server offline**
  (`RipsStore.swift:12-15`).
- iOS fetches with cache-busting (`.reloadIgnoringLocalCacheData`,
  `RipsStore.swift:266`) and on failure **keeps the previous in-memory manifest**
  (`RipsStore.swift:272`). Android: OkHttp `Cache-Control: no-cache` + keep last
  good copy on disk (offline-first, same doctrine as the catalog cache).
- Refresh at app launch and after any rip job completes (`RipsStore.swift:479,493,513`).

### 2.2 Shape

Top level is a **JSON object keyed by songId** — `[String: ManifestEntry]`
(`RipsStore.swift:270`). Entry fields the client consumes (`RipsStore.swift:90-141`;
written by the server at `scripts/rip-server.mjs:854-857` (analog) and
`scripts/rip-server.mjs:1089-1092` (digital)):

```jsonc
{
  "<songId>": {
    "key": "rips/<albumId or songId>.mp3",  // REQUIRED — S3 object key, consume verbatim
    "ext": "mp3",
    "source": "analog" | "digital",
    "albumId": "…",                          // server writes it; client ignores
    "startMs": 123456,                        // ANALOG only: song's offset inside the shared ALBUM mp3; null for digital
    "durationMs": 234567,                     // song length; null possible
    "bpm": 120.1, "musicalKey": "…", "camelot": "8A",   // optional analysis
    "waveform": "rips/…png",                  // optional, key relative to ripsBase
    "analyzed": true,
    "rippedAt": 1750000000000,                // epoch-ms; optional (older entries)
    "cutKey": "rips/<songId>.cut.mp3",        // ANALOG only, burn-export; NOT for playback
    // beat-grid scalars (firstBeatMs, firstDownbeatMs, beatGridBpm, beatsPerBar,
    // tempoConfidence, tempoVar, steady, beatgrid, analysisVersion),
    // stems {vocals,drums,bass,other}, stemVersion/stemFormat/…,
    // lyrics (sidecar key), lyricsModel, lyricsVersion — ALL OPTIONAL
  }
}
```

**Iron law (ported):** decode leniently. Every field except `key` must be
optional-with-default, and **unknown fields must be ignored** (`RipsStore.swift:88-89`);
the server adds fields over time (stems, lyrics, beat grids all arrived later).
kotlinx.serialization: `ignoreUnknownKeys = true`, all fields nullable except `key`.

### 2.3 Resolving a playable URL from a manifest entry

```
playableUrl = ripsBase + "/" + entry.key
```

(`RipsStore.swift:292-295`; server equivalent `scripts/rip-server.mjs:150-151`.)
No auth on this GET — the `rips/*` prefix is public-read (`RipsStore.swift:25-29`).

Two key shapes exist:

- **Digital** song: `key = "rips/<songId>.mp3"`, `startMs = null` — a per-song file,
  play from 0 (`scripts/rip-server.mjs:1089-1092`).
- **Analog** (vinyl) song: `key = "rips/<albumId>.mp3"` — **one album-length mp3
  shared by every song on the album**, and each song's manifest entry carries its
  own `startMs` offset into that file (`scripts/rip-server.mjs:843,850-857`).
  Playback must (a) seek to `startMs` once ready, and (b) **stop/advance at
  `startMs + durationMs`**, because the natural end-of-file only fires at the end
  of the whole album (`PlayerEngine.swift:55-63`, `RipsStore.swift:160-169`).

**Android/Media3 mapping (analog):** use `MediaItem.ClippingConfiguration`
(`setStartPositionMs(startMs)` / `setEndPositionMs(startMs + durationMs)`) — this
gives seek-to-start and the end boundary in one shot, and makes ExoPlayer's
auto-advance to the next queue item correct for album up-next. When `durationMs`
is null, clip start only and rely on natural end.

Optional extras resolved the same way (all `ripsBase + key`, all public,
Phase-1-optional): `waveform` image (`RipsStore.swift:310-313`), beat-grid sidecar
`rips/analysis/<songId>.json` (`RipsStore.swift:341-344`), stems
`rips/stems/<songId>/…` (`RipsStore.swift:326-332`), lyrics sidecar
`rips/lyrics/<songId>.json` (`RipsStore.swift:379-382`).

---

## 3. Playing a song by id — the resolution ladder

iOS order (`PlaybackCoordinator.swift:89-100`):

1. **Apple Music streaming** (MusicKit) — for songs from the "Apple Music (Local)"
   source, when authorized.
2. **Rip server path** — the universal terminal fallback
   (`RipServerPlaybackProvider.swift:50-65` → `RipsStore.play` / `ensureURL`).

(iOS also plays **burned** local files outside the coordinator entirely —
`BurnStore.localURLForPlayback`, `apple/PocketDJ/State/BurnStore.swift:326` —
checked before any network. **Phase-1 cut:** no burns/offline on Android yet;
arrives with Playlists/offline in a later phase.)

**Android Phase 1 ladder** (no MusicKit — locked decision 6,
`docs/ARCHITECTURE-ANDROID.md:45-52`):

```
fun resolve(songId): PlayAction
  1. manifest[songId] != null       → PLAY  ripsBase + entry.key  (+ clipping for analog)
  2. no entry, ripServerUrl != ""   → TRIGGER rip (POST /rip), then either
        a. play the live HLS stream the job exposes (streamUrl), or
        b. show "Preparing…" and poll /jobs/<id> until ready → play the S3 mp3
  3. no entry, no server            → METADATA-ONLY (no ▶, or a disabled ▶ with
                                      "Configure import server in Settings")
```

Rule 3 is the **Apple-Music-only track** case: on iOS those stream via MusicKit;
on Android a track with no public rip is **browsable metadata only**
(`docs/ARCHITECTURE-ANDROID.md:46-48,101-107`). iOS's equivalent error string:
"No import server configured (Settings ▸ Import server)." (`RipsStore.swift:436`).

**Do NOT auto-fire rip requests for every AM-only track browsed.** iOS fires the
fire-and-forget rip only when a song *starts playing* via Apple Music
(`PlaybackCoordinator.swift:147-150`, `RipsStore.swift:675-703`) — a path Android
doesn't have. On Android, `/rip` fires only on an explicit user ▶ (rule 2).

**Studio-id fence (defense-in-depth, mirror it):** ids prefixed `smp_`, `lp_`,
`ptn_`, `tk_` are device-local Studio artifacts and must **never** be sent to
`/rip` — the server 400s them (`scripts/rip-server.mjs:2107-2110`), and the iOS
client refuses client-side first (`RipsStore.swift:247-257,455-456`). Phase 1 has
no Studio, but collection id arrays can carry these ids; filter them.

---

## 4. Rip server HTTP API (Phase-1 subset)

All endpoints live at the user-configured base URL. Protocol notes:

### 4.1 Auth — three parts on every request (`RipsStore.swift:1576-1580`)

1. `Authorization: Bearer <token>` — **omitted entirely when the token is empty**
   (`RipsStore.swift:1577`). Server side: empty `RIP_TOKEN` ⇒ auth off, everything
   passes (`scripts/rip-server.mjs:1906-1910`); wrong/missing token ⇒ `401 {"error":"unauthorized"}`
   (`scripts/rip-server.mjs:1977`).
2. `X-PocketDJ-Profile: <profileId>` — omitted when empty (`DeviceIdentity.swift:58-64`).
   Android Phase 1 has no profile sync ⇒ omit.
3. `X-PocketDJ-Device: <installId>` — **always sent**; a random UUID minted once per
   install and persisted (`DeviceIdentity.swift:19-31,65`). Android: mint a
   `UUID.randomUUID()` on first launch, persist in DataStore.

**HLS exception:** segment/playlist GETs authenticate via `?token=<token>` query
parameter instead of the header (players can't add headers to segment fetches) —
`RipsStore.swift:297-307` (client builder), `scripts/rip-server.mjs:1968-1975`
(server accepts header OR query), `scripts/rip-server.mjs:782-786` (the m3u8's
segment URIs come back already rewritten with `?token=`). Percent-encode the token
(`RipsStore.swift:302-303`). Media3 note: ExoPlayer follows the m3u8's rewritten
segment URIs as-is, so passing the tokened playlist URL is sufficient.

Client timeout doctrine: **12 s** on `/rip` POST and `/search`/`/album-tracks`
GETs so an unreachable server fails fast instead of hanging playback UI
(`RipsStore.swift:462-467,810-812`).

### 4.2 `GET /health` — reachability + capability check

Response 200 (`scripts/rip-server.mjs:1964-1967`):

```json
{ "ok": true, "host": "…", "version": 2, "hls": true, "stems": true,
  "analogBase": "…", "bucket": "pocketdj-rips-011183829623",
  "catalog": { "songs": 12345, "albums": 678 }, "cached": 9012,
  "auth": true, "public": true, "rateLimit": false }
```

Use for the Settings "test connection" affordance. No auth required beyond the
global gate (tokenless servers answer without a token).

### 4.3 `POST /rip` — trigger a rip (or join/short-circuit one)

Request (`content-type: application/json`):

```json
{ "songId": "…" }
```

Optional fields (`scripts/rip-server.mjs:2104,2111-2113`; client
`RipsStore.swift:470,743-747`):

- `ripFromCloud: true` — iOS sends only when the Settings toggle is on
  (`RipsStore.swift:225`). **Phase-1 cut: don't send.**
- `title`, `artist`, `appleMusicId`, `lengthMs` — the ad-hoc descriptor for a song
  not in any indexed catalog (Discover/recognizer add; songId shape
  `amrec_<storeId>`, `scripts/rip-server.mjs:505`). **Phase-1 cut:** not needed
  for plain catalog playback.

Responses (`scripts/rip-server.mjs:2103-2117`):

| Status | Body | Meaning |
|---|---|---|
| 200 | `{"jobId": null, "songId": "…", "phase": "ready", "url": "https://…s3…/rips/….mp3"}` | already ripped — play `url` |
| 200 | job view (below) | queued, or joined an in-flight job |
| 400 | `{"error": "studio ids are device-local (not rippable)"}` | studio id — never retry |
| 404 | `{"error": "unknown songId"}` | not in the server's catalog — a MISS, show as unplayable |
| 401 | `{"error": "unauthorized"}` | bad/missing token — point at Settings |

**Job view** (`scripts/rip-server.mjs:474-490`; client decode `RipsStore.swift:59-69`):

```jsonc
{
  "jobId": "…", "songId": "…",
  "phase": "queued" | "searching" | "ripping" | "streaming" | "uploading" | "ready" | "error",
  "message": "…" | null,
  "url": "https://…s3…/rips/….mp3" | null,        // set when phase == "ready"
  "error": "…" | null,
  "streamUrl": "/hls/<songId>/index.m3u8",         // PRESENT once live streaming is available
  "progress": { "elapsedMs": 1, "totalMs": 2, "pct": 50 } | { "indeterminate": true }  // optional
}
```

Decode leniently — every field except `phase` optional (`RipsStore.swift:59-69`).
Rips are **real-time captures**: `totalMs` ≈ song length, so a rip takes about as
long as the song plays (`scripts/rip-server.mjs:481-483`).

### 4.4 `GET /jobs/<jobId>` — poll a rip

Percent-encode the id in the path (`RipsStore.swift:523`). 200 → job view;
404 `{"error":"no such job"}` (`scripts/rip-server.mjs:1993-2001`).

iOS polling contract (`RipsStore.swift:486-520`):

- Foreground wait: poll **every 1 s, up to 1800 tries** (~30 min); resolve on
  `phase == "ready" && url != null` → refresh manifest → play `url`; resolve
  early the moment `streamUrl` appears (live playback) if live is acceptable.
- After handing back a live URL: keep a background poll **every 2 s, up to 1800
  tries** (~1 h) so the manifest swaps to the durable mp3.
- **Do NOT stop polling on `phase == "error"`** in the background poll — the
  server auto-heals and re-queues failed jobs (error → queued,
  `RipsStore.swift:514-518`). The foreground wait DOES throw on error
  (`RipsStore.swift:498`).

### 4.5 `GET /hls/<songId>/index.m3u8` — live stream of an in-progress rip

- Reached via the job view's `streamUrl` (relative path): full URL =
  `serverUrl + streamUrl + "?token=" + token` (token omitted when empty) —
  `RipsStore.swift:297-307,482`.
- Content types: `application/vnd.apple.mpegurl` playlist, `video/mp2t` segments
  (`scripts/rip-server.mjs:785,789`). Media3 plays this with the HLS module
  (`media3-exoplayer-hls`).
- A live HLS stream is **unseekable** and has no static duration — iOS marks it
  `live` (detected by `"/hls/"` in the URL, `RipsStore.swift:552`) and drops any
  seek/cue (`RipsStore.swift:574-578`). Detect the same way; disable the scrubber.
- **Phase-1 option:** live HLS is nice-to-have. Acceptable Phase-1 minimum: show
  "Preparing… n%" from the job's `progress` and start playback only when the
  durable mp3 is ready. If shipped, use it only when the user explicitly played an
  un-ripped song.

### 4.6 `GET /status/<songId>` — one-shot rip state (optional convenience)

200 → `{"ready": true, "url": "…", "entry": {…}}` or
`{"ready": false, "job": <job view | null>}` (`scripts/rip-server.mjs:1983-1990`).
iOS doesn't use it (it holds the manifest instead); handy for spot checks.

### 4.7 Phase-1 explicitly NOT used

`/rip-collection` (batch, `scripts/rip-server.mjs:2125-2139`), `/stemify`,
`/search` + `/album-tracks` (Discover — needs the server; can slot into Phase 1's
Browser later), `/rip-cancel`, all admin endpoints
(`scripts/rip-server.mjs:1945-1949`). Rate limiting exists server-side but is
default-off (`scripts/rip-server.mjs:60-62`); handle a 429 as a plain error.

---

## 5. Player behavior contract (what Media3 must reproduce)

From `PlayerEngine.swift` (iOS AVPlayer wrapper) — the observable behavior, not
the implementation:

1. **One player, mp3 + HLS** — same engine plays durable mp3 and live HLS
   (`PlayerEngine.swift:11-17`). Media3: one `ExoPlayer` with progressive + HLS
   modules.
2. **Analog seek-on-ready** — seek to `startMs` once the item is ready, never for
   live (`PlayerEngine.swift:14-17,55-56`). Media3: `ClippingConfiguration`
   (§2.3) supersedes manual seek.
3. **End boundary** — a track inside a shared album mp3 must signal "ended" at
   `startMs + durationMs`, exactly once (one-shot latch; natural end and boundary
   race, first wins — `PlayerEngine.swift:57-67`). Media3: clipping end position
   makes `MEDIA_ITEM_TRANSITION`/`STATE_ENDED` fire at the right spot.
4. **Lock-screen / notification transport** — play/pause/seek + metadata
   (`PlayerEngine.swift:485` MARK). Android: `MediaSessionService` +
   `MediaSession` wired to the ExoPlayer; the media notification comes free.
   This is locked decision 4 (`docs/ARCHITECTURE-ANDROID.md:37-38`).
5. **Position ticks must not recompose the world** — iOS deliberately keeps the
   ~4 Hz position clock out of Observation (`PlayerEngine.swift:18-32`). Compose
   analogue: don't put position in a hot `StateFlow` collected by the whole
   screen; poll `player.currentPosition` in the scrubber composable only.
6. **Play counts** — iOS fires an `onPlay(songId)` hook on every now-playing
   transition to a different song (`RipsStore.swift:186-188,560-562`). Phase 1
   feeds History with the same signal.

### Queue (Phase-1 cut)

**Single-track queue + simple up-next within an album**: tapping ▶ on a song
plays that song; if it belongs to an album in view, load the album's playable
songs (manifest hits only — metadata-only tracks are skipped) as the ExoPlayer
playlist from that index, each with its own clipping window. No setlists, no
cross-album queues, no shuffle — those ride Phase 2 (Playlists,
`docs/ARCHITECTURE-ANDROID.md:101-107`). Note for the analog case: consecutive
songs of one album share one URL; ExoPlayer treats clipped items of the same URI
gaplessly enough for Phase 1.

### Burns / offline / downloads (Phase-1 cut)

iOS resolves burned local files **before** any network and supports
download-to-Documents (`BurnStore.swift:326-366`, `RipsStore.swift:584-604`).
Android Phase 1: **none of this** — streaming only. Offline burns arrive with a
later phase (`docs/ARCHITECTURE-ANDROID.md:101-107`). Design seam: keep the
resolution ladder (§3) behind one function so a local-file rung slots in at
position 0 later.

---

## 6. Error surface (user-visible states)

Mirror the iOS states (`RipsStore.swift:423-444`):

| Condition | State |
|---|---|
| No manifest entry + no server configured | metadata-only row; "No import server configured (Settings)" if the user insists on ▶ |
| `/rip` non-2xx | "Rip failed (\<status>)" |
| 200 but no `jobId` and not ready | "Rip did not start" (use server `error` if present) |
| job `phase == "error"` (foreground wait) | show server `error` |
| poll exhausted | "Rip timed out" |
| 401/403 anywhere | point at the Settings token field |
| Manifest fetch failure | silent — keep cached copy |
