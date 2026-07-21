# Jukebox Hero — Android Phase 1 implementation contract (DJ side)

Extracted from the iOS app + broker source on 2026-07-21. Every claim cites
`file:line` in this worktree. The broker (`scripts/jukebox-server.mjs`) is reused
**unchanged** (docs/ARCHITECTURE-ANDROID.md:50-52, 116); Android is a new host
("DJ") client speaking the same HTTP API the iOS `JukeboxClient` speaks.

Design doc: `docs/design/jukebox-hero.md`. iOS reference implementation:
`apple/PocketDJ/Jukebox/{JukeboxClient,JukeboxModels,JukeboxStore}.swift`,
`apple/PocketDJ/Views/JukeboxView.swift`, `apple/PocketDJ/Views/SettingsView.swift:582-624`.

---

## 1. Roles (who does what)

- **Broker** (`scripts/jukebox-server.mjs`, node, port 8788, launchd on the iMac):
  owns session lifecycle + the durable request queue, and is the only party with
  AWS creds — it renders the guest page and writes `state.json` to the web S3
  bucket (jukebox-server.mjs:2-11). It does **no matching and no ripping**
  (jukebox-server.mjs:4-5).
- **Guests** only ever GET static S3 objects behind CloudFront
  (`jukebox/<id>/index.html` + `state.json`, polled ~4 s) and POST requests to the
  broker (jukebox-server.mjs:8-10; template usage scripts/jukebox-site/template.html:117-118,306,330-332).
- **The app is the DJ**: it POSTs player-state snapshots, polls new guest
  requests, matches them against the catalog, and applies decisions to its own
  play queue (JukeboxStore.swift:4-13). The Android app implements only this role.

There is **no "mark played" endpoint**: the session's played history is derived
**server-side** from now-playing transitions in the `/state` POSTs — when a
snapshot replaces one track with a different one (or with nothing), the outgoing
track is appended to the session's played log (jukebox-server.mjs:190-211,272).
Posting honest snapshots **is** how the DJ marks things played. Same title+artist
is a position tick, not a transition — except a hard rewind (prev position
> 30 000 ms and next < 10 000 ms), which logs a back-to-back replay
(jukebox-server.mjs:200-208). Server keeps the last 100 entries, publishes the
newest 30 in `state.json` (jukebox-server.mjs:67-68,220).

## 2. Broker HTTP contract (verified against jukebox-server.mjs)

### 2.1 Base URL + path prefix

The DJ configures a single **base URL** in Settings (may be blank = feature
unconfigured; the iOS default is blank, SettingsStore.swift:561-568). The
canonical deployment is a Tailscale Funnel path mount
`https://levis-imac.tail2e2bdf.ts.net:8443/jukebox` (jukebox-server.mjs:39-43,
docs/design/jukebox-hero.md:151-158) — but the client must work with **any**
base, funneled or direct.

Client URL construction (mirror `JukeboxClient`): trim whitespace and trailing
`/` from the base (JukeboxClient.swift:39-41), then append paths that **always
carry a leading `/jukebox` segment** for session routes:

- create: `{base}/jukebox` (JukeboxClient.swift:81-87)
- session ops: `{base}/jukebox/{jukeboxId}/…` (JukeboxClient.swift:96-140)
- health: `{base}/health` (JukeboxClient.swift:70-72)

This works both direct and behind Funnel because the server strips **one**
leading `/jukebox` segment before dispatch (`/jukebox` → `/`, `/jukebox/…` →
`/…`, jukebox-server.mjs:421-427). Do not double-strip or special-case the base.

### 2.2 Auth — two credentials + identity headers

1. **Server-level token** (`JUKEBOX_TOKEN`, optional): `Authorization: Bearer
   <token>` on **create only**; when the server runs without a token, create is
   open (jukebox-server.mjs:35,413,433-437; JukeboxClient.swift:10-11).
2. **Per-session `hostKey`**: returned by create; bearer for every other host
   route (state/requests/decision/config/end). The server also accepts
   `?hostKey=` as a query param, but the app uses the bearer header
   (jukebox-server.mjs:414-415,455-456; JukeboxClient.swift:96-140). **Never show
   the hostKey to guests** (JukeboxModels.swift:40-41). Format today: 32 hex
   chars (`randomBytes(16).toString('hex')`, jukebox-server.mjs:125) — treat as
   an opaque string.
3. **Identity headers** on every call, additive to the bearer
   (DeviceIdentity.swift:51-66; applied in JukeboxClient.swift:51-52):
   - `X-PocketDJ-Device`: a stable per-install random UUID, minted once and
     persisted (DeviceIdentity.swift:19-48). Android: mint `UUID.randomUUID()`
     on first access, persist in prefs/DataStore, always send.
   - `X-PocketDJ-Profile`: the profile id; **omitted when empty**
     (DeviceIdentity.swift:62-66). Android P1 has no profiles (no CloudKit,
     ARCHITECTURE-ANDROID.md:48-49) → omit this header.
   The current server ignores both (forward-compat; DeviceIdentity.swift:54-56).

### 2.3 Endpoints

All request/response bodies are JSON. CORS is wildcard; OPTIONS answered 204
(jukebox-server.mjs:398-406,419).

| # | Route (as the client builds it) | Auth | Body | 2xx response |
|---|---|---|---|---|
| 1 | `GET {base}/health` | none (send server token as bearer like iOS does, harmless) | — | `{ ok:true, service:"jukebox", version:2, host, bucket, sessions, auth }` (jukebox-server.mjs:429-431; VERSION=2 at :31) |
| 2 | `POST {base}/jukebox` | server token | `{ name, timeless, requiresToken }` (JukeboxClient.swift:82-86) | `{ jukeboxId, hostKey, name, url, timeless, expiresAt }` (jukebox-server.mjs:247). `url` = the guest page `${siteBase}/jukebox/${id}/`. `expiresAt` epoch **ms**, `null` when timeless. NOTE: `requiresToken` is sent as intent; the server **ignores it today** and is NOT echoed back (JukeboxClient.swift:78-81, JukeboxModels.swift:56-62) |
| 3 | `POST {base}/jukebox/{id}/state` | hostKey | `JukeboxStatePayload` (see §3.3) | `{ ok:true }` (jukebox-server.mjs:269-277) |
| 4 | `GET {base}/jukebox/{id}/requests?since={seq}` | hostKey | — | `{ requests:[{ id, seq, title, artist, clientId, createdAt, status }], seq }` — every request with `seq > since`, ascending (jukebox-server.mjs:305-310) |
| 5 | `POST {base}/jukebox/{id}/requests/{reqId}/decision` | hostKey | `{ action: "denied"\|"next"\|"end"\|"random" }` (+ optional `matchedTitle`, `matchedArtist` the server stores; iOS does not send them, JukeboxClient.swift:133-140, jukebox-server.mjs:321-324) | `{ ok:true, requestId, status }` where status = `"denied"` for denied, else `"queued"` (jukebox-server.mjs:312-330) |
| 6 | `POST {base}/jukebox/{id}/config` | hostKey | `{ timeless }` | `{ timeless, expiresAt }` (jukebox-server.mjs:252-259) — Android P1 does **not** call this (see §6) |
| 7 | `POST {base}/jukebox/{id}/end` | hostKey | — | `{ ok:true, ended:true }` (jukebox-server.mjs:261-267) |

`POST {base}/jukebox/{id}/request` (guest, public, rate-limited) exists
(jukebox-server.mjs:279-303,448-453) but the DJ app never calls it.

### 2.4 Error codes (must be handled, not just displayed)

- **401** — bad server token (create) or bad hostKey (session routes)
  (jukebox-server.mjs:435,456).
- **404** — unknown/deleted session id, unknown request id, or unroutable path
  (jukebox-server.mjs:443,449,456,467,314).
- **410** — session ended or expired: **fold the local session** (clear
  persisted state, return UI to "Start a jukebox"). iOS folds on **404 or 410**
  from any loop call (JukeboxStore.swift:251-261; server side
  jukebox-server.mjs:450,457-458). `ensureExpiry` lazily flips a just-expired
  session to ended, so 410 can appear at any moment (jukebox-server.mjs:337-347).
- **400** — bad decision action / missing title (jukebox-server.mjs:283,316).
- **429** — guest rate limiting only; never for host routes.

Anything non-2xx: surface as a transient error string, **keep the loop
running** (JukeboxClient.swift:60-68 throws `http(code)`; JukeboxStore.swift:42-44,262-264).

### 2.5 Server-side behaviors the client relies on

- State publishes to S3 are **debounced ≥1 s** (trailing) for `/state`; a
  decision or end publishes **immediately** so guests see status flips promptly
  (jukebox-server.mjs:66,225-236,327,264).
- `decideRequest` **bumps the request's `seq`** (jukebox-server.mjs:320), so the
  host's next `?since=` poll re-delivers requests it already decided — with
  status `"denied"`/`"queued"`. The client must de-duplicate (see §4.2).
- Request `status` values the server actually writes: `pending`, `denied`,
  `queued` (jukebox-server.mjs:293,317). The design doc also lists `played`
  (docs/design/jukebox-hero.md:67, JukeboxRequest comment JukeboxModels.swift:85)
  but **no code sets it in v2** — decode status as a plain String and tolerate
  unknown values.
- Sessions survive broker restarts (reloaded from disk, jukebox-server.mjs:142-171);
  non-timeless sessions auto-end at 24 h and are deleted at 7 days by a 10-min
  sweeper (jukebox-server.mjs:50-52,357-380).
- Session ids match `[a-z2-7]{4,32}` (base32, 8 chars today); request ids match
  `rq_[a-f0-9]+` (jukebox-server.mjs:441,464,293).
- Title/artist are server-sanitized: control chars stripped, ≤120 chars
  (jukebox-server.mjs:64,76).

## 3. Wire types (Kotlin, kotlinx.serialization)

Mirror `JukeboxModels.swift`. **ADDITIVE-OPTIONAL iron law applies**: every field
that can be absent gets a default so a later addition never breaks decode of a
persisted doc; unknown JSON keys must be ignored (`Json { ignoreUnknownKeys = true }`).

### 3.1 Session (returned by create; persisted locally)

`JukeboxSessionInfo` (JukeboxModels.swift:38-75):

```kotlin
@Serializable
data class JukeboxSessionInfo(
    val jukeboxId: String,
    val hostKey: String,          // host-only credential — never render, never log
    val name: String,
    val url: String,              // guest page URL — the QR payload, verbatim
    val requiresToken: Boolean? = null, // local intent only; server neither mints nor enforces yet (JukeboxModels.swift:56-62)
    val timeless: Boolean? = null,      // optional: older/absent decodes as off (JukeboxModels.swift:63,72)
    val expiresAt: Double? = null,      // epoch ms; null on a timeless session (JukeboxModels.swift:73-74)
)
```

### 3.2 Request

`JukeboxRequest` (JukeboxModels.swift:79-86); the host poll also carries
`clientId` (jukebox-server.mjs:308) which iOS ignores — ignore it too:

```kotlin
@Serializable
data class JukeboxRequest(
    val id: String,
    val seq: Int,
    val title: String,
    val artist: String,           // may be ""
    val createdAt: Double,        // epoch ms
    val status: String,           // "pending" | "queued" | "denied" (+ tolerate unknown)
)
```

### 3.3 State snapshot (host → broker)

`JukeboxStatePayload` (JukeboxModels.swift:106-146):

```kotlin
@Serializable
data class JukeboxStatePayload(
    val hear: Boolean = false,
    val nowPlaying: NowPlaying? = null,
    val upNext: List<Track> = emptyList(),
) {
    @Serializable
    data class NowPlaying(
        val title: String,
        val artist: String,
        val lengthMs: Int? = null,
        val positionMs: Int? = null, // position at snapshot time; guest page interpolates
        val streamUrl: String? = null, // hear mode only — public https rips-bucket mp3, else null
    )
    @Serializable data class Track(val title: String, val artist: String)
}
```

Server-side sanitation of this payload: non-https `streamUrl` is dropped, upNext
is capped at 50 (jukebox-server.mjs:174-189). Post positions honestly — the
played-history derivation (§1) depends on them.

### 3.4 Decisions

`JukeboxDecisionAction` (JukeboxModels.swift:90-102) — wire strings and
host-facing labels:

| wire | label | meaning |
|---|---|---|
| `denied` | Deny | refuse; guest sees "denied" |
| `next` | Play Next | insert directly after the current track |
| `end` | Play Last | append to the queue tail |
| `random` | Surprise Slot | uniform random slot in the upcoming tail |

All three placements report `queued` to guests (JukeboxModels.swift:89-90).

## 4. DJ session engine (the Android `JukeboxStore` equivalent)

App-scoped singleton (survives navigation), session persisted so relaunch
re-adopts a running party (JukeboxStore.swift:15-17,118-126).

### 4.1 Lifecycle

- **Start** (JukeboxStore.swift:132-155): guard no session + not already
  starting; `POST /jukebox` with `name` (user text, or default name — iOS uses
  `"<DJ name>'s Jukebox"` falling back to `"PocketDJ Jukebox"`,
  JukeboxView.swift:136-139), `timeless:false`, `requiresToken` from the
  Settings default. On success: persist session (stamping `requiresToken` intent
  locally since the server doesn't echo it, JukeboxStore.swift:141-143), reset
  `hear=false`, `seq=0`, empty inbox + decided-set, start the loop. On error:
  show the message, stay on the create screen.
- **Resume** (JukeboxStore.swift:118-126): on app start, if a persisted session
  decodes, adopt it and start the loop. iOS persistence keys:
  `pdj.jukebox.session.v1` (JSON-encoded session) + `pdj.jukebox.hear.v1` in
  UserDefaults (JukeboxStore.swift:91-92). Android: same two values in
  Preferences DataStore; decode leniently per §3.1.
- **End** (JukeboxStore.swift:160-173): cancel the loop, `POST /end` (30 s
  timeout), then clear the local session **even if the POST failed** — an
  unreachable broker must not trap the host in a dead party. Confirm before
  ending (iOS uses a confirmation dialog, JukeboxView.swift:158-168).
- **Server-side death**: any loop call answering **404 or 410** folds the local
  session (cancel loop, clear persistence, empty inbox) and surfaces
  "This jukebox has ended." (JukeboxStore.swift:251-261).

### 4.2 The loop (state up, requests down)

One coroutine while live, tick every **4 s** (JukeboxStore.swift:214-222). Each
tick (JukeboxStore.swift:225-265):

1. Compose the snapshot from the playback layer (§5.2). POST it only **on
   change** (compare to the last successfully-posted payload) **or when >15 s**
   since the last post — a heartbeat so guests' pages can trust `updatedAt`
   (JukeboxStore.swift:228-241).
2. `GET /requests?since={seq}`; set `seq = max(seq, page.seq)`; for each
   returned request with `status == "pending"`, skip if its id is in the local
   **decided set** or already in the inbox, else append to the inbox and kick a
   match (JukeboxStore.swift:242-250). The decided set exists because decisions
   bump `seq` server-side (§2.5) — without it a poll racing a decision would
   re-inbox a handled request (JukeboxStore.swift:72-74).
3. Transport errors set a `lastError` string shown as a subtle
   "reconnecting"-style hint; the loop **never stops on error**
   (JukeboxStore.swift:42-44,262-264). Clear it on the next success
   (JukeboxStore.swift:237).

Flipping hear mode triggers an immediate tick so guests see the flip promptly
(JukeboxStore.swift:34-40).

### 4.3 Decisions

- **Deny**: always available (JukeboxView.swift:361,376-381).
- **Placements** (`next`/`end`/`random`): enabled only when a playable match
  exists (JukeboxView.swift:420-430).
- On any decision: add id to the decided set, remove from inbox **immediately**,
  then POST the decision **fire-and-forget** — the local queue edit is the
  user-visible truth; the server status flip is best-effort cosmetics
  (JukeboxStore.swift:335-337,437-442).
- Accept placement semantics against the play queue
  (JukeboxStore.swift:358-373):
  - queue running: `next` → insert right after the current item; `end` →
    append; `random` → uniform random slot within the upcoming tail.
  - **nothing playing: the accepted request STARTS playback** with a one-item
    queue (JukeboxStore.swift:361; UI copy "Nothing playing — the first accepted
    request starts the music.", JukeboxView.swift:306).

### 4.4 Matching — Android P1 cut

iOS matches in four stages: normalized-exact → folded-contains fuzzy scoring →
on-device Foundation-Models pick → Apple Music catalog search
(JukeboxStore.swift:9-10, docs/design/jukebox-hero.md:171-179). Android P1 has
**no Foundation Models and no MusicKit** (ARCHITECTURE-ANDROID.md:46-49), so the
cut is **catalog-only**:

1. normalize (casefold, strip punctuation/diacritics) title+artist; exact match
   against the cached catalog;
2. else folded-`contains` over catalog title/artist keys → top-scored candidate.
3. No match → the request shows "No match found" and Deny is the only enabled
   action (mirrors iOS `.none`, JukeboxView.swift:407-409,425-430).

Match is computed async per request; the inbox row shows "Matching…" until it
lands (JukeboxStore.swift:24-28,314-323; JukeboxView.swift:394-410). A matched
song is **playable on Android only if a public rip/burn exists** (see §5.1) —
a catalog match with no rip must render as unplayable (Deny-only), never crash
into a playback attempt.

## 5. Playback integration (Android P1)

### 5.1 What can actually play

No MusicKit on Android: playback exists only where a **public rip** exists
(ARCHITECTURE-ANDROID.md:46-48,101-104). Public rip URL = `{ripsBase}/{manifest
entry key}` where `ripsBase = https://pocketdj-rips-011183829623.s3.us-west-2.amazonaws.com`
and the key comes from the rips manifest (`rips/manifest.json`, objects
`rips/<songId>.mp3`) (Config.swift:21-22; RipsStore.swift:292-295). Accepted
requests enqueue that URL into the Media3 queue.

### 5.2 Snapshot composition

iOS composes by "who owns the audio": Mix → sequencer → single play
(JukeboxStore.swift:271-301). Android P1 has one Media3 queue, so one arm:

- playing: `nowPlaying = { title, artist, lengthMs (media duration), positionMs
  (current position), streamUrl (§5.3) }`, `upNext` = remaining queue items'
  title/artist (cap irrelevant; server truncates at 50).
- idle: `nowPlaying = null`, `upNext = []` (JukeboxStore.swift:300).
- `positionMs` is snapshot-time truth (pause freezes it → that change triggers a
  post, JukeboxStore.swift:229-231).

### 5.3 Hear mode (View + Hear)

- Default **OFF** = view-only request line; every new session starts OFF
  (JukeboxStore.swift:31-34,145).
- When ON, include `streamUrl` = the current track's **public https rips-bucket
  mp3** — and nothing else: never a local file path, never any other URL
  (JukeboxStore.swift:305-312). Tracks with no public rip send `streamUrl:null`
  and stay view-only even in hear mode (JukeboxModels.swift:113-117). This gate
  is **client-side** — the broker only checks https (JukeboxModels.swift:129-132,
  jukebox-server.mjs:176-183) — so the Android client must enforce it too.
- The `hear` flag rides every snapshot (JukeboxModels.swift:141-143); flip →
  immediate tick (§4.2).

## 6. UI contract (Compose, dark theme, accent #6EA8FF)

Two states in the Jukebox destination (JukeboxView.swift:42-52):

**Create view** (no session; JukeboxView.swift:56-131): name field with the
default-name placeholder; "Require access token" toggle **seeded from the
Settings default each time the view appears** (JukeboxView.swift:39,129-130);
Start button with in-flight spinner + disabled state; error label. Do **not**
port the "Timeless" toggle — it is marked for removal on iOS
(JukeboxView.swift:77-87) and Android always creates `timeless:false`; therefore
`POST /config` (§2.3 #6) is not called in P1.

**Live view** (JukeboxView.swift:148-346):
1. **QR section**: session name; the QR code on a **white rounded card with
   generous padding — white card + quiet zone are load-bearing for phone
   cameras against the dark background** (JukeboxView.swift:189-192,454-455);
   caption "Scan to see what's playing and request a song"; Share + Copy-link
   actions for `session.url`; transient error hint under the card
   (JukeboxView.swift:193-212).
2. **Session section**: View + Hear toggle (with the view-only/hear captions,
   JukeboxView.swift:233-251); "Require access token" toggle (local-intent only,
   §3.1; JukeboxView.swift:263-277); expiry readout — with `expiresAt` present:
   "Ends <relative time>; cleaned up 7 days after start.", else the generic
   24 h/7 d line (JukeboxView.swift:283-289, minus the timeless branch).
3. **On air section**: current track + "N up next", or "Nothing playing — the
   first accepted request starts the music." (JukeboxView.swift:291-315).
4. **Requests section**: count header; empty-state line; one row per inbox item:
   what the guest typed, the match line (Matching… spinner / matched
   title—artist / "No match found"), and Deny + Play Next + Play Last +
   Surprise Slot buttons, placements disabled without a playable match
   (JukeboxView.swift:317-333,362-430).
5. **End section**: destructive End Jukebox with confirmation; the confirmation
   copy notes guests' pages will show ended and local playback keeps going
   (JukeboxView.swift:158-168,335-346).

**Settings ▸ Jukebox Hero** (SettingsView.swift:582-619; SettingsStore.swift:111-122):
- "Jukebox server URL" text field (default **blank**, SettingsStore.swift:561-568).
- "Token (optional)" text field (the server-level create bearer).
- "Require access tokens by default" toggle, default **true**
  (SettingsStore.swift:254,569).
- "Test connection" button → `GET /health`; show ok + version, or the error.
- Persist additively-optional (`jukeboxServerURL`/`jukeboxToken` nullable with
  `?? ""` fallback, `jukeboxTokensRequiredByDefault ?? true`,
  SettingsStore.swift:252-254,439-441).
- With a blank URL, Start must fail gracefully with a "check Settings" style
  error (JukeboxClient.swift:25-26 uses "Jukebox server URL is invalid — check
  Settings.").

### 6.1 QR code — generate locally

The QR payload is **exactly `session.url`, verbatim** — no additions
(JukeboxView.swift:191). iOS uses CoreImage's generator with error-correction
level **M**, integer-scaled so modules stay sharp squares
(JukeboxView.swift:460-468). Android: use **ZXing core, pinned
`com.google.zxing:core:3.5.3`** (pure-Java, no Google Play services, works
offline): `QRCodeWriter().encode(url, BarcodeFormat.QR_CODE, size, size,
mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M))` → render the
`BitMatrix` to an `ImageBitmap` with 1 matrix cell → n×n integer pixels, no
filtering/interpolation, dark modules `#000000` on `#FFFFFF`, drawn on a white
rounded card (ZXing's default 4-module quiet zone + the card padding mirror the
iOS 14 pt padding, JukeboxView.swift:445-455). Add the dependency to
`android/gradle/libs.versions.toml` (`zxing = "3.5.3"`).

## 7. Networking specifics

- Timeouts: **12 s** default per call; **30 s** for create (two S3 uploads) and
  end — short so an asleep/unreachable broker fails fast instead of hanging the
  UI (JukeboxClient.swift:4-6,44,85,108). OkHttp: per-call timeout override.
- JSON body posts carry `Content-Type: application/json`
  (JukeboxClient.swift:53-56).
- Decode 2xx bodies leniently; treat undecodable 2xx as an error
  (JukeboxClient.swift:60-68).
- Health response shape for the Settings test: `{ ok, service, version }` — the
  client decodes just those three, all optional (JukeboxClient.swift:33-37).
  Current broker version is **2** (jukebox-server.mjs:29-31); version exists so
  the app can detect capability bumps — display it, don't gate on it.

## 8. Offline / failure matrix (must-implement behaviors)

| Condition | Behavior | iOS cite |
|---|---|---|
| Blank server URL | Jukebox screen still opens; Start errors with "check Settings" | JukeboxClient.swift:25-26,45 |
| Create fails (offline, 401, timeout) | Stay on create view, show error, button re-enabled | JukeboxStore.swift:152-154 |
| Loop call fails transiently | Show reconnect hint, keep session + loop, retry next 4 s tick | JukeboxStore.swift:42-44,262-264 |
| Loop call → 404/410 | Fold session: cancel loop, clear persistence + inbox, "This jukebox has ended." | JukeboxStore.swift:251-261 |
| End POST fails | Clear local session anyway (never trap the host) | JukeboxStore.swift:160-173 |
| Decision POST fails | Ignore (fire-and-forget); queue edit already applied | JukeboxStore.swift:437-442 |
| App relaunch with live session persisted | Re-adopt session, resume loop | JukeboxStore.swift:118-126 |
| Snapshot unchanged | No POST until the 15 s heartbeat | JukeboxStore.swift:229-241 |

## 9. Known gaps in the reused broker (do not "fix" client-side; do not overstate in UI)

These are explicitly marked `#TOUPDATE` in the iOS source; Android inherits them:

- `requiresToken` is **intent only** — the server neither mints a guest token
  into `url` nor rejects tokenless guest requests; the guest page is public to
  anyone with the link (JukeboxModels.swift:47-62; jukebox-server.mjs:247,448).
  Keep the toggle + persisted intent (so the plumbing is ready), but Android UI
  copy must not claim the link is gated — avoid porting the iOS create-view
  sentence "The code carries this session's token…" (JukeboxView.swift:63-69).
- There is **no listener cap** — only guest request rate limits
  (jukebox-server.mjs:59-65; JukeboxView.swift:112-118). Avoid the iOS footer
  claim "only so many guests can be on at once".
- Hear-mode audio is the flat public `rips/<songId>.mp3` namespace — no
  per-session URL, outlives the session (JukeboxModels.swift:119-132).
- Request status `played` is documented but never set by broker v2 (§2.5).
