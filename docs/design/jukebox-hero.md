# Jukebox Hero — crowd-requested radio, DJ'd by PocketDJ

**Status:** building (feat/jukebox-hero)

The party trick: the PocketDJ user opens the **Jukebox Hero** tab (⌘J), starts a
jukebox, and gets a QR code. Guests scan it and land on a tiny static site showing
the currently-playing song and the up-next queue, plus a text box: type a title +
artist, hit Enter, and the request lands in the host's app. The host sees the
request matched against the full PocketDJ catalog (on-device Foundation Models +
Apple Music catalog search) and can **deny**, **play next**, **play last**, or
drop it into a **random spot** in the queue. Playback uses the existing engines —
stream from Apple Music, or rip & stream through the rip server. Every guest is
listening to a radio station whose distribution is S3 and whose DJ is the app.

## Roles

```
 guests' phones                    iMac (later: Lambda)              host's PocketDJ app
┌────────────────┐   requests   ┌──────────────────────┐   poll    ┌────────────────────┐
│ static site    │ ───────────▶ │   jukebox-server     │ ◀──────── │ JukeboxStore       │
│ (S3+CloudFront)│              │  (session broker)    │  decide   │  · match (FM+AM)   │
│  · now playing │              │  · sessions          │ ────────▶ │  · queue edits     │
│  · up next     │              │  · request queue     │           │  · state snapshots │
│  · request box │              │  · S3 state writer   │ ◀──────── │                    │
└────────────────┘              └──────────────────────┘   state   └────────────────────┘
        ▲                                  │ renders page,                  │
        │  poll state.json (~4s)           │ writes state.json              │ SetlistPlayer /
        └──────────── S3 web bucket ◀──────┘                                ▼ PlaybackCoordinator
                                                                    Apple Music ▸ rip server
```

- **S3 is the distribution.** Guests only ever GET static objects (page +
  `state.json`); any number of listeners, zero load on the host.
- **jukebox-server is the session broker** — nothing more. It owns session
  lifecycle, the durable request queue, and is the AWS-credentialed S3 writer
  (the app has no AWS creds). It does **no ripping and no matching**.
- **The app is the DJ.** It matches requests, applies host decisions to the live
  SetlistPlayer queue, and plays through the existing provider chain
  (Apple Music first, rip-server stream/rip fallback — no new rip code).

## S3 layout (per-env web bucket, behind CloudFront for TLS)

```
jukebox/<id>/index.html   ← rendered by jukebox-server at create time (name baked in)
jukebox/<id>/state.json   ← no-cache; rewritten by jukebox-server on host snapshots
```

QR URL: `https://<cloudfront-domain>/jukebox/<id>/` (dev `djictbz9w796r…`, prod
`d2p4cubg6se03u…`). `scripts/deploy.sh` gains `--exclude "jukebox/*"` so PWA
deploys don't prune live jukeboxes.

`state.json` (written only by jukebox-server; host snapshot ⊕ request statuses):

```json
{
  "v": 1,
  "jukeboxId": "jb7k3q9d",
  "name": "Levi's Garage Party",
  "updatedAt": 1789600000000,
  "ended": false,
  "expiresAt": 1789686400000,
  "hear": false,
  "nowPlaying": { "title": "…", "artist": "…", "lengthMs": 214000, "positionMs": 63000,
                  "streamUrl": "https://pocketdj-rips-….s3….amazonaws.com/rips/<id>.mp3" },
  "upNext": [ { "title": "…", "artist": "…" } ],
  "played": [ { "title": "…", "artist": "…", "endedAt": 1789599786000 } ],
  "requests": [ { "id": "rq_…", "title": "…", "artist": "…", "status": "pending|queued|denied|played" } ]
}
```

Guests poll it every ~4 s. `positionMs` is snapshot-time; the page animates a
progress bar locally between polls.

`played` is the session's **previously-played history**, derived **server-side** from
now-playing transitions (a state POST replacing one track with a different one — or
with nothing — logs the outgoing track). Deriving on the broker covers every host
source (setlist deck, Auto-DJ mix, single rip plays) with zero wire-protocol change
and records what guests actually saw as Now Playing. The full log (last 100) persists
in `session.json` across restarts; `state.json` carries the newest 30. The guest page
shows a "Previously played" card with a reveal button (newest first, local end times).

### View-only vs View + Hear (the live radio)

A session is **view-only by default** — a crowd-sourced request line: guests see the
music and request, they don't hear it. The DJ can flip **View + Hear** on the live
session (a toggle in the tab): snapshots then carry the current track's **public S3
rip mp3** as `nowPlaying.streamUrl`, and the guest page shows a "📻 Tune in — live
radio" button (user-gesture-gated — mobile autoplay rules) that plays the track
position-synced (`positionMs + (now − updatedAt)`, re-seek on >3 s drift). The page
behaves like an internet-radio client, **no PocketDJ app needed**: tracks auto-advance
(src swaps ride the original tap gesture), an unexpectedly paused element self-heals
with a `play()` retry each poll, Media Session metadata puts the station — track,
artist, jukebox name — on the guest's lock screen with working play/pause, and a
mid-song join seeks to the live position once metadata loads. Audio streams straight
from the public rips bucket; the broker never proxies bytes. Only rips-bucket audio is
ever distributed — a DRM'd Apple Music stream never leaves the host; once its
stream-through-rip lands in the manifest, a later snapshot picks the URL up
automatically. Tracks with no public rip stay view-only even in hear mode (the radio
pauses with a hint and resumes on the next streamable track).

### Session lifecycle (server-owned)

Default sessions **expire 24 h** after creation (sweeper publishes a final
`ended: true` state; host endpoints answer **410**, and the app folds its local
session) and are **deleted at 7 days** (S3 `jukebox/<id>/` recursively removed +
server session dir purged; endpoints answer **404**). A session created with —
or later flipped to — **timeless** mode opts out of both. The sweeper runs every
10 minutes in jukebox-server; the app only displays expiry and offers the toggle
(`POST /jukebox/:id/config { timeless }`).

## jukebox-server (scripts/jukebox-server.mjs)

Sibling of `rip-server.mjs`: dependency-free `node:http`, port **8788**, launchd
KeepAlive (`com.pocketdj.jukeboxserver.plist`), logs to
`~/.pocketdj/jukebox-server.log`, wildcard CORS, optional `JUKEBOX_TOKEN` bearer
for host endpoints, S3 writes via the `aws` CLI (profile `levi`) serialized per
jukebox like the rip server's `saveChain`.

Durable session state under `~/.pocketdj/jukebox/<id>/` (`session.json`,
`requests/<reqId>.json`) — survives restarts; sessions reload on boot.

### Endpoints

| Route | Who | Body → Result |
|---|---|---|
| `GET /health` | anyone | `{ ok, service: "jukebox", version }` |
| `POST /jukebox` | host (token) | `{ name, timeless }` → `{ jukeboxId, hostKey, url, timeless, expiresAt }`; renders + uploads page, seeds state.json |
| `POST /jukebox/:id/config` | host key | `{ timeless }` → `{ timeless, expiresAt }` — flips the lifecycle mode |
| `POST /jukebox/:id/end` | host key | marks ended, publishes final state (`ended: true`) |
| `POST /jukebox/:id/state` | host key | player snapshot `{ nowPlaying, upNext }` → merged with request statuses, written to S3 (debounced ≥1 s) |
| `POST /jukebox/:id/request` | guest (public) | `{ title, artist, clientId }` → `{ requestId }`; rate-limited per clientId+IP (1/15 s, ≤5 pending), lengths capped |
| `GET /jukebox/:id/requests?since=<seq>` | host key | `{ requests: [...], seq }` — pending (and recently-decided) requests |
| `POST /jukebox/:id/requests/:reqId/decision` | host key | `{ action: "denied"\|"next"\|"end"\|"random", matchedTitle?, matchedArtist? }` |

Handlers are pure `(ctx, params, body) → {status, json}` functions over a small
storage interface (filesystem today) so the same module drops into a Lambda
handler behind an HTTP API Gateway later (model:
`scripts/lambda/deploy-search-proxy.sh`; note this account blocks public Lambda
Function URLs — HTTP API + CloudFront is the path, as with the search proxy).

### Public exposure (interim, iMac)

Guests are **not** on the Tailnet, so this service must be publicly reachable (the
first public mount on this machine — the rip server later followed on `:10000` for
the beta distribution). Interim answer: **Tailscale Funnel** path-mount on Funnel's
second HTTPS port — **8443, not 443**, because Funnel is per-PORT and this
machine's 443 already serves the Tailnet-only rip server `serve` mount at `/` (funneling 443
would expose the rip server to the public internet):

```
tailscale funnel --bg --https=8443 --set-path /jukebox http://127.0.0.1:8788
```

→ public base `https://levis-imac.tail2e2bdf.ts.net:8443/jukebox`
(`scripts/setup-jukebox-funnel.sh`). The rendered page bakes this base in
(`JUKEBOX_PUBLIC_BASE` env) for its POSTs; the app uses the same base
(Settings ▸ Jukebox Hero). The Lambda migration later just changes this one
base URL.

## Native app

- **RootView**: new `Section.jukebox = "Jukebox Hero"` (icon `radio`), detail arm,
  ⌘J shadow button in `navigationShortcuts`.
- **JukeboxStore** (`@Observable`, app-scoped in `PocketDJApp.init`): create/end
  session (persisted across launches); while live —
  - *snapshot loop*: observes SetlistPlayer (`currentSongId`, `upcoming`) + the
    coordinator/rips now-playing split (as `NowPlayingPanel.isPlayingNow` does),
    POSTs debounced snapshots + a ~15 s heartbeat;
  - *request poll loop*: GETs new requests every ~5 s, runs each through the
    matcher, surfaces them in the inbox.
- **JukeboxMatcher**: free-text title/artist →
  1. `ShazamCatalogMatch.norm`-exact match against the catalog;
  2. folded-`contains` over `AppModel.searchKeys` → scored top-N candidates;
  3. on-device FM pick (`@Generable` choice over a numbered candidate list, per
     the `FoundationModelPocketBrief` pattern, behind a protocol seam +
     availability gate; graceful fallback to top fuzzy candidate);
  4. no catalog hit → `AppleMusicProvider.search` (MusicCatalogSearchRequest) →
     Apple Music-only match (`am:<storeID>`), playable via the existing
     coordinator chain + stream-through-rip.
- **Decisions** → SetlistPlayer live-queue edits: `insertNextInQueue`,
  `appendToQueue`, and a new `insertRandomInQueue` (uniform slot in the upcoming
  tail); then POST the decision so guests see request status flip.
- **JukeboxView**: idle → name field + Start; live → QR code
  (`CIFilter.qrCodeGenerator`, first use in the app) + shareable URL, now-playing
  + up-next (NowPlayingPanel patterns), request inbox with per-request match line
  and Deny / Play Next / Play Last / Surprise Slot actions, End Jukebox.
- **Settings ▸ Jukebox**: server base URL (default the Funnel base) + token,
  health check — mirroring the rip-server rows.

## Broadcast — the Mix tie-in (live DJ'ing with a digital request line)

The full feature set: a physical party, the DJ on the Mix tab, the crowd on the QR
code. **The setlist is the shared concept.**

- The Mix toolbar gets a **Broadcast** button (antenna, next to Record): one tap
  creates a jukebox session (if none is live) and pushes the Jukebox view onto the
  Mix stack — Back returns to the decks. The antenna glows while broadcasting.
- **Guests see the mix**: the state snapshot is composed by who OWNS the audio —
  a running/auto Mix first (the on-air deck's track + the auto queue's tail as
  "up next"), then the app-scoped SetlistPlayer, then a standalone single play.
- **Requests feed the Auto-DJ**: while auto-mixing, an accepted request is inserted
  into the auto queue (`MixEngine.autoQueueInsert`) — never before `autoNextToLoad`,
  so tracks already loaded/preloaded on a deck are never displaced. **In-mix actions
  always take precedence** over the jukebox: manual deck loads, skips, and pauses
  behave exactly as without a broadcast.
- **Burn gate**: a Mix deck can only load a BURNED file, so accepting an unburned
  request during a broadcast kicks the existing rip+burn pipeline
  (`BurnStore.startRipAndBurn`; Apple-Music-only matches under their `amrec_` id)
  and parks a pending insert that lands the moment the file exists (15 min cap;
  if the mix ended meanwhile, a running sequencer inherits the request).
- **Hear mode during a broadcast** streams the *unmixed* track from S3 (same rule
  as always: public rips only). A future **live radio mode** — streaming the actual
  broadcast mix output, or replaying recorded mix sessions — is the planned
  follow-up, not v1.

## Later: Lambda migration (out of scope for v1)

`scripts/lambda/deploy-jukebox.sh` mirroring `deploy-search-proxy.sh`: same
handler module + a DynamoDB/S3 storage adapter, HTTP API Gateway, CloudFront
`/jukebox-api/*` behavior for TLS + same-origin POSTs from the guest page.
