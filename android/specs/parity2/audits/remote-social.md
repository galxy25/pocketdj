# Parity2 audit — remote-social (Remote tab, SharePlay, Backseat, Mix Together, Jukebox Hero, sharing, profile sync)

Audited 2026-11-23 against `main` (iOS `apple/PocketDJ`, Android `android/app/src/main/java/com/levi/pocketdj`,
abbreviated `A/` below). Read-only audit; no builds run.

## TL;DR

* **The whole Remote surface is missing on Android.** iOS 1.0.5 (merged 2026-11-07, `692343db`, `7d9b708a`,
  re-review fixes `2b0e9d07`/`98484d49`/`4c941a7e`, panel merge `f9259495`/`fb4dd652`) added a ~5,000-line
  Remote layer (`apple/PocketDJ/Remote/*`, 2,500 lines of tests in `apple/Tests/Unit/RemoteSessionTests.swift`
  + `MixSyncTests.swift`). Android has no `remote` package, no Hero | Remote switch, no Mix Together.
* **There is no cross-platform transport on iOS today.** `RemoteTransport` (protocol,
  `Remote/RemoteTransport.swift`) has exactly two implementations: `GroupSessionTransport` (SharePlay,
  `Remote/GroupSessionTransport.swift`) and the in-memory `LoopbackTransport` (tests and the screenshot seed).
  GroupActivities runs only on Apple devices, and sessions are routed through Apple's FaceTime/Messages
  infrastructure. **An Android device cannot join an iOS SharePlay session (platform-impossible).**
* **What Android can have is the same capability over its own transport.** Port the transport-agnostic layers
  verbatim: wire, send queue, shared clock, queue model, controller, resolver, MixSync. Run them over
  1. **Google Nearby Connections** (`play-services-nearby`; the app already depends on
     `play-services-location`). This is the primary choice. It needs no server, so it works for every Play
     user (the jukebox server URL defaults to blank: `A/data/config/Endpoints.kt:64`). It works with no
     Wi-Fi or cell coverage (Backseat in a car), and its latency is low enough for Mix Together's 40 ms
     drift floor.
  2. Optionally, a **broker relay** added to `scripts/jukebox-server.mjs`. This allows sessions over the
     internet for users who configured a jukebox server. It is also the only route to iOS↔Android
     sessions, and that route needs a future iOS `BrokerTransport` behind the same protocol. Keep the
     Android wire byte-identical to iOS so that later iOS change works without touching Android.
* **Jukebox Hero is essentially at parity.** Request line, View+Hear, inbox, AM match, played history, guest
  join, Tune-In radio, joined strip, sessions picker and MwF are all done. Remaining gaps:
  - the **Timeless** toggle (create and live flip);
  - the **Mix broadcast antenna** button;
  - the Jukebox panel's **Hero | Remote** switch;
  - Android Auto showing the session **QR** (partial).
* **Sharing**: song, album, History-row and Jukebox shares are present. Missing: the **Now Playing Share**
  action and the **History multi-select Share** (`ShareText.forSongs` exists but nothing calls it).
* **Profile sync**: the Android↔Android S3 engine is built, but **dormant in the shipped app**. The live
  endpoints doc `https://app.pocket-dj.com/config/endpoints.json` (fetched 2026-11-23) has no
  `profileSyncBase`; only the repo copy `config/endpoints.green.json` has it. Q119 deferred enabling it for
  1.0. Registry gaps: `pocket-palette` and `profile-source`. iOS↔Android profile sync is out of scope,
  because iOS syncs through CloudKit.

---

## 1. iOS architecture to port (read before implementing)

### 1.1 Files

| iOS file | Lines | Role |
|---|---|---|
| `Remote/RemoteWire.swift` | 231 | Envelope `{v, kind, payload}`, kinds, bodies (`RemoteRow`, `RemotePlaybackState`, `RemoteCommand`, `RemoteHeartbeat`, `RemoteStateRequest`, `RemoteHello`, `RemoteAvailability`, `RemotePing`/`RemotePong`), `RemoteSessionMode` (`listenTogether`/`backseat`), `RemoteDeviceRole` (`speaker`/`controller`) |
| `Remote/RemoteTransport.swift` | 321 | `RemoteTransport` protocol, `LoopbackHub`/`LoopbackTransport`, `RemoteSendQueue` (two lanes) |
| `Remote/GroupSessionTransport.swift` | 161 | SharePlay activity + transport (Apple-only; **do not port**; replace with Nearby/Broker) |
| `Remote/SharedClock.swift` | 89 | NTP-style offset to the HOST clock, best-of-8 lowest-RTT |
| `Remote/RemoteQueueModel.swift` | 206 | Host-authoritative pure queue model (`apply(command, now)` → revision bump) |
| `Remote/RemotePlaybackTarget.swift` | 346 | Protocol the reconciler drives + `SetlistPlayerRemoteTarget` + `InMemoryRemoteTarget` |
| `Remote/RemoteSongResolver.swift` | 216 | Cross-device song resolution ladder (rights boundary) |
| `Remote/RemoteSessionController.swift` | 1219 | Election, hand-over, heartbeat, state requests, reconcile, local-change diffing, controller gate, pausedHere, host refill, showcase seed |
| `Remote/RemoteView.swift` | 538 | Remote tab UI |
| `Remote/TVRemoteView.swift` | 75 | tvOS (n/a on Android) |
| `Remote/MixSync.swift` | 1405 | Multiplayer 2-deck Mix ("Mix Together") |
| `Remote/MixSyncModels.swift` | 308 | `mix.*` kinds, `MixSyncAnchor`, `MixSyncEvent`, `MixSyncModel` |
| `Remote/MixSyncViews.swift` | 123 | Mix Together section (ownership Claim/Release, held/paused, unavailable notes) |
| `Views/JukeboxHubView.swift` | 73 | Hero \| Remote segmented switch (`jukeboxPanelMode` key) |
| `PocketDJApp.swift:1544-1572` | — | Wiring: controller gate on the sequencer, DJ Mode suspension, MixSync wiring |
| `Playback/SetlistPlayer.swift:460-480, 5535-5600` | — | `TransitionCause`, `transitionSeq`, `userPlayIntentSeq`, `applyingRemote`, `remoteControllerGate`, `RemoteRedirect` |

Design docs: `docs/design/mix-audio-graph.md` § Multiplayer Mix, and `docs/design/remote-audio-relay.md`.
The relay is **PARKED** and not built on iOS, so it is not a parity item. Memory:
`remote-tab-shareplay-program.md`.

### 1.2 Wire format: MUST stay byte-compatible with iOS

The Android codec must decode and encode exactly what Swift's `JSONEncoder` and `JSONDecoder` produce. That
way a future iOS broker transport, or a debug bridge, interoperates with no Android change.

* Envelope: `{"v":1,"kind":"<string>","payload":"<base64>"}`. `payload` is **standard base64** of the
  body's JSON, which is Swift's default `Data` strategy. `kind` is an open string. **An unknown kind, or
  `v` > 1, is ignored, never fatal.** A body that fails to decode is dropped.
* `RemoteCommand` uses Swift's synthesized enum Codable with associated values, so every case is a
  single-key object:
  - `{"play":{"rows":[…],"startIndex":0}}`, `{"playNow":{"rows":[…]}}`
  - `{"playPause":{}}`, `{"skipNext":{}}`, `{"skipPrevious":{}}`
  - `{"setPlaying":{"_0":true}}`, `{"setRepeat":{"_0":"all"}}`, `{"setShuffle":{"_0":false}}`
    (unlabeled associated value ⇒ `_0`)
  - `{"seek":{"ms":1234}}`, `{"jumpTo":{"rid":"…"}}`, `{"enqueueNext":{"rows":[…]}}`,
    `{"append":{"rows":[…]}}`, `{"remove":{"rid":"…"}}`
  - `{"move":{"rid":"…","toUpcomingOffset":2}}`, `{"reorder":{"rids":[…]}}`, `{"advanced":{"fromRid":"…"}}`

  This needs a hand-written kotlinx `KSerializer`. Pin it with golden-JSON tests captured from Swift; add
  a Swift test that prints them if needed. An unknown case key means the message is dropped.
* `RemoteRow` = `{rid, row}`. `row` is the durable-session `PlaybackSessionStore.Row`: `songId`, `title`,
  `artist`, `lengthMs?`, `repeatCount?`, `variant?`, `editionLocked?`, `plan?`, `appleMusicId?`,
  `djPlaced?`, `djUserNext?`. **Android `SessionRow` (`A/playback/durable/SessionSnapshot.kt:27`) lacks
  `appleMusicId`.** Add it as an optional, additive field. Without it a peer that doesn't have the songId
  can't fall back to the Apple Music id. Unknown fields must be ignored (`ignoreUnknownKeys`), and unknown
  `plan`/`dj*` must round-trip or be dropped harmlessly.
* `RemotePlaybackState`:
  - `{revision, hostId, mode, snapshot, rowIds, windowStart, totalCount, anchorSharedTime, sessionActive?}`
  - `snapshot` is the durable `Snapshot` (`schemaVersion, sessionId, source{kind,id?,name?,originKind?,originId?}, queue, index, positionMs, isPlaying, repeatMode?, shuffleEnabled?, stemLock?, npMixMode?, fxLock?, djMode?, updatedAt`).
  - `snapshot.index` is **relative to the window**, and `rowIds[i]` is the rid of `queue[i]`.
  - Times are epoch-ms **Doubles** on the host clock.
* `RepeatMode` raw values are `off|all|one`. `RemoteHello.caps` is an optional array, and `"mix"` marks a
  deck-owner-capable build.
* Mix kinds: `mix.snapshot`, `mix.event`, `mix.request`, `mix.ready`, `mix.beat`, `mix.reject`,
  `mix.handover`. `MixSyncEvent` and `MixSyncAnchor` field names are in `MixSyncModels.swift:61-115`.
  Deck raw values come from `MixEngine.Deck`, so check the casing against Android `mix.model.Deck.label`.

### 1.3 Hard-won invariants the port must keep (from code + the three review rounds)

Transport and send queue (`RemoteSendQueue`):
- There are two lanes: RELIABLE (state, commands, hellos, mix events) and UNRELIABLE (pings, heartbeats,
  beats). Each delivers strictly in send order, through one worker per lane. Never send one coroutine per
  message: a later state overtook an earlier one that way.
- Reliable sends retry with delays [0.25 s, 1.0 s]. An unreliable send is never retried and never waits
  behind a reliable retry.
- `state` and `heartbeat` are **coalesced per recipient**: the newest replaces the undelivered one.
- Caps: reliable 256, unreliable 32. Past a cap, drop a coalescible message first, otherwise the oldest.
- A message to a participant that isn't resolvable yet is **buffered** (32 per peer, 16 peers max). The
  buffer flushes when the roster changes and is dropped when that peer departs.
- Messages never loop back to the sender.

Election and host:
- The host owns the authoritative `RemoteQueueModel`.
- When the host leaves, the **lowest remaining participant id** takes over from the last state it saw.
- When two hosts collide, `shouldYield` decides symmetrically: an ACTIVE session beats an empty one, then
  the newer revision wins, then the lower id. **An empty self-elected host must never wipe a real
  session.**
- A joiner that hasn't heard from a host re-hellos (`electionTimeoutMs` 8 s). It self-hosts only when
  alone.

State flow:
- The full state goes out on a revision change, to a joiner, and on request.
- A heartbeat goes out every 2 s with revision and position. Receivers apply structure only from a
  **newer revision**. A missed revision triggers a `stateRequest`, retried at 2 s doubling up to 16 s.
- The wire state is **size-capped at 60,000 bytes**: halve the window until it fits. The window is 20
  rows behind and 200 ahead, with `minWindowAhead` 10.
- When the upcoming tail drops below 100 rows, the host refills 200 rows from its own local set. The
  host's own long queue is never truncated.

Reconcile (speaker, 0.5 s tick):
- Use the cheapest move: a tail-segment edit, `jumpToUpcoming(uid, atMs)`, or a fresh
  `play(startIndex, atMs, startPaused)`.
- Drift threshold is 750 ms (2,000 ms when the position clock is coarse, as with Apple Music). Correct
  only after 2 consecutive strikes, with a 5 s cooldown, and **never while buffering**.
- A position change past the threshold that arrives with a NEW revision is a session seek: apply it at
  once.
- A position jump of more than 3 s between ticks is a user scrub. The landing of our own seek is not a
  scrub.
- A ▶/⏸ that didn't take is re-issued after 2 s.
- A local edit holds reconcile for 3 s or until a newer state arrives (`pendingHoldMs`).

Local-change diffing:
- **Only the listener's own actions become commands.** Use the player's `TransitionCause`:

  | Cause | What it means for the session |
  |---|---|
  | `user` | The listener's own action: send it as a command |
  | `naturalEnd` | Report `.advanced(fromRid)` only if the session is also within 10 s of that row's end. Otherwise hold silent until the session moves |
  | `autoSkip` | Mark the row unplayable HERE |
  | `stallHop` | Mark the row unplayable HERE |
  | `unplayable` | Mark the row unplayable HERE |
  | `remote` | Never echo |

- A local stop never pauses everyone.
- `advanced(fromRid)` applies only while `fromRid` is still current, so N speakers advance the set once.
- If no speaker reports the end, the host advances on its own `hostAdvanceSlackMs` (8 s) after the end.

Rows and resolution:
- Rows are addressed by **rid** (a host-assigned instance id), never by songId or index, because a song
  can repeat in a set. `ridByUid` is rebuilt when it grows large.
- A cached resolution must always produce a NEW queue-item uid. A duplicate uid breaks uid-keyed edits.

Resolver ladder (rights boundary):
1. Own songId.
2. The Apple Music id maps to a catalog song.
3. `am:<id>` through the user's own AM, if usable.
4. Exact normalized title+artist key.
5. The fuzzy matcher. It is expensive, so run it only for the current row plus the next 3.
6. Otherwise the row is unavailable.

Never put a rip URL, a presigned link or a token on the wire. Outbound rows are stamped with the
appleMusicId.

Roles and audio ownership:
- **A CONTROLLER plays nothing.**
  - The sequencer is held silent and re-asserted every tick (`silenceForController` cancels any start in
    flight).
  - Every local transport (panel, widget, lock screen/media session, Android Auto, Assistant, Browse ▶)
    goes through `remoteControllerGate` and is forwarded as a command. `localStart` (a cascade retry or
    stray reclaim) is refused and NOT forwarded.
  - The Mix decks are silenced too (`registerControllerSilencer`).
- **One audio owner**: a speaker reconciles the SAME app-scoped sequencer the Now Playing UI drives. There
  is never a second player.

System pauses:
- A SYSTEM pause on a speaker (call, route loss, headphones or Auto unplugged) sets `pausedHere`. The app
  NEVER resumes out of the phone speaker on its own. Only the listener's ▶ or **Rejoin** resumes, and it
  resumes at the session position. Nothing is sent.

Session lifecycle:
- Leaving a session keeps local playback playing.
- Withdraw a pending start if the invite UI is cancelled. Otherwise the next session to arrive is
  wrongly taken as ours to host.
- **DJ Mode is suspended while a Remote session is attached** (`setlistPlayer.remoteSessionActive`).
- **Auto-DJ is refused while mixing together** (`MixSync.autoDJBlockedReason` = "Auto DJ is off while you
  mix together."). The Assistant and intents say why.
- The durable Mix session is not written while a Mix Together session is live, so the user's own saved
  mix survives.

Mix Together:
- The host orders everything. A participant's gesture is a proposal. The host validates ownership,
  assigns a sequence number and rebroadcasts. Every device applies events in host order.
- **No echo.** A gesture applies locally at once, and its echo is skipped. A sender's own un-echoed
  proposal on a control shadows another sender's older value. Proposals expire after 2 s and trigger a
  snapshot request.
- Continuous controls coalesce at 50 ms, seeks at 250 ms, with a trailing send of the final value.
- Starts are anchored `startLeadMs` 300 ms into the future (min 60, max 2,000). An owner proposes a play
  only once its deck can sound. The host waits up to 4 s for the owner's ready report.
- Drift:
  - Threshold: a 40 ms floor plus both clocks' uncertainty plus a 20 ms margin.
  - Act only after 2 strikes.
  - Below 250 ms, correct with a ≤1% rate nudge. At or above 250 ms, re-seek.
  - Cooldown 4 s.
  - Ignore beats staler than 1.5 s.
  - **Looping decks compare PHASE inside the loop window.**
- Gaps and snapshots: a sequence gap older than 1.5 s triggers a snapshot request. Snapshot retries back
  off 3/6/12/24/48 s, then stop.
- `mix.handover`: a live mix is never ended by an empty or older host.
- System causes stay local: the deck is "held" until the system resumes it, and engine-internal stops are
  ignored.
- Cue/PFL, the meter, recording and the session log stay LOCAL. A remote DJ's gestures are not recorded
  as yours.
- Ownership: the host gets Deck A, and the first `caps:["mix"]` joiner gets Deck B. Claim and Release
  are proposals. Every tick reconciles a deck's whole board, setting unlisted controls back to default.

---

## 2. Android state (verified)

* `grep -ri "listenTogether|backseat|shareplay|RemoteSession|MixTogether|mixSync"` over `A/` finds
  nothing relevant. There is no Remote code.
* Navigation: `A/navigation/PocketDjDestination.kt:29` has `Jukebox("jukebox", …, "Jukebox Hero")`, under
  `moreTabs` (line 45, per Q7). `A/screens/jukebox/JukeboxScreen.kt` is Hero only, with no switch.
* Sequencer seams: `A/playback/sequencer/SetlistSequencer.kt` has `AdvanceCause {USER, AUTO,
  UNPLAYABLE_HERE}` (`AdvanceCause.kt:11`). It has `play(items, …, startIndex)` with no
  `startPaused`/`atMs`, `jumpToUpcoming(uid)` with no `atMs` (l.1091), `playNow`, and `appendToQueue`. It
  has **no** `replaceUpcoming`, `insertUpcoming(before)`, `queueGeneration`, `transitionSeq` with a full
  cause set (naturalEnd/stallHop/remote), `userPlayIntentSeq`, `applyingRemote`, or controller gate.
* Mix engine: `A/mix/engine/MixEngine.kt` + `MixRecordingHooks.kt` (an `emit(...)` recorder hook — the
  natural place for a `gestureTap`), `AutoQueueSeams.kt`, `MixTick.kt`. It has no `applyingRemote` guard,
  no `syncPlay(atLocalMs)` API, no `syncNudgeRate`, and no `syncSetLoop(exact window)`.
* Jukebox: `A/data/jukebox/*` (15 files, ~2.5k lines) and `A/screens/jukebox/*` (5 files). They cover:
  - create, QR (`JukeboxQr.kt`), Share/Copy link, View + Hear, Require access token;
  - On air, the request inbox with Matching… and No match found, the played list, End;
  - join by link, the sessions picker (adopt), the joined strip;
  - the guest join screen with requests, Recently played and Tune In (`JukeboxTuneIn.kt`,
    `TuneInSeekMath`);
  - the AM catalog match (`JukeboxAppleMusicMatch.kt`) and Mix inserts (`MixJukeboxSource.kt`).

  **No `timeless` toggle.** `JukeboxModels.kt:27` notes "Android P1 always creates timeless:false". There
  is no create toggle, no `/config` flip, and no Mix broadcast button (`grep -i broadcast A/screens/mix` is
  empty).
* Sharing: `A/data/share/ShareText.kt` (`forSong`, `forAlbum`, `forSongs`, `forTitleArtist`, `send`) is
  used by the Song detail, Album detail, History row (`HistoryScreen.kt:463`), Jukebox, MwF and CSV.
  **`A/screens/nowplaying/*` has no share**, and **`forSongs` has no caller** (Q16).
* Profile sync: `A/data/sync/*` (CloudSyncService, S3CloudDocDatabase, Enrollment, LinkCode,
  ProfileRecovery with the Q120 "deleted on another device" state), `A/screens/settings/LinkDeviceScreen.kt`
  (QR display via zxing, code entry), and `SyncEntry` registrations across graphs. Doc keys are registered
  for profile, collections, favorites, play-stats, play-history, collection-activity, timeline-cues,
  mix-sessions, mix-decks, playback-session, discover-adds, imported-songs, studio-cues, game-scores,
  puzzle-decisions, rec-feedback, foryou-feed, rec-key, settings-credentials and diag-key.
  * Missing vs iOS `PocketDJApp.swift:1916-2018`:
    - `pocket-palette` (`Services/PocketWheel/PocketPaletteStore.swift`, file
      `pocketdj-pocket-palette.json`). The store doesn't exist on Android yet; it belongs to the wheel
      area.
    - `profile-source` (`pocketdj-profile-source.json`). The store exists (`A/data/profile/ProfileSourceStore.kt:135`)
      but isn't registered.
    - `edits`. There is no Android edits store at all; that's the browse area.
    - `apple-music-library`. It's an iOS MusicKit library mirror: n/a.
  * The live endpoints doc has **no `profileSyncBase`**, so sync shows as not configured in the shipped
    app (Q119: "android profile sync not needed for first release … don't enable anything just for it").
* Music with Friends: present (GM-10, `A/data/games/friends/*`, `A/screens/games/MwF*`). It polls, with
  no FCM (Q4).
* Android Auto: `A/auto/AutoMixTab.kt:76,284` lists jukebox sessions (Timeless/Live), but shows no QR
  image (Q83).

---

## 3. Gap inventory

Legend for **Feasibility**: direct = port as-is; equivalent = same capability on a different
platform mechanism; platform-impossible; out-of-scope.

### R1. Jukebox panel Hero | Remote switch — MISSING (direct, ~130 lines, high)
- **iOS:** `Views/JukeboxHubView.swift`.
  - A segmented switch is pinned as a top bar, persisted under the key `jukeboxPanelMode`, with values
    `"Jukebox Hero"` and `"Remote"`.
  - A session going active flips the panel to Remote.
  - Deep entries land on Remote: ⌘R, `lastSection "Remote"`, `PDJ_START_SECTION=Remote`.
- **Android:** create `A/screens/jukebox/JukeboxHubScreen.kt`. Put a `SingleChoiceSegmentedButtonRow` in
  the top app bar slot so the child list scrolls under it and doesn't slice rows. Hold the mode in a
  DataStore `PrefKey.string("jukeboxPanelMode")` with the same raw values. Route the `Jukebox` destination
  to the hub, which hosts `JukeboxScreen` or `RemoteScreen`.
  - `RemoteSessionController.isActive` going `true` flips the mode to Remote.
  - Add a deep link `pocketdj://remote` (and a `pocketdj://remote/join/<code>` invite) in `DeepLinkParser`
    and `DeepLinkDispatcher`, plus `LastSectionStore` handling.
  - Consider retitling the More entry "Jukebox" with the subtitle "Jukebox Hero · Remote".

### R2. Remote wire + transport abstraction + send queue + loopback — MISSING (direct, ~750 lines + ~500 test lines, high, prerequisite)
- **iOS:** `RemoteWire.swift`, `RemoteTransport.swift` (protocol + `LoopbackHub` + `RemoteSendQueue`).
- **Android:** create the new package `A/remote/`:
  - `RemoteWire.kt`: kotlinx-serialization models and the custom `RemoteCommandSerializer` (§1.2).
  - `RemoteTransport.kt`: an interface with `localParticipantId`, `inbound: Flow<RemoteInbound>`,
    `participants: StateFlow<Set<String>>`, `send(env, to, reliable)` and `leave()`.
  - `LoopbackHub.kt`: latency and drop injection.
  - `RemoteSendQueue.kt`: two single-consumer lanes, each a `Channel` with its own worker coroutine on
    Main, with the caps, coalescing and per-peer buffering in §1.3.

  Golden tests go in `A/../test/.../remote/RemoteWireGoldenTest.kt`, using JSON captured from Swift.
  `SessionRow` gains `appleMusicId: String? = null`. That is additive, and the durable-session schema
  stays at version 1.

### R3. Nearby Connections transport (Android↔Android, offline) — MISSING (equivalent, ~550 lines, high)
- **iOS:** `GroupSessionTransport.swift` + `RemoteView` start flow (FaceTime, the Messages share sheet,
  nearby).
- **Why "equivalent":** SharePlay/GroupActivities is Apple-only. Android's closest same-capability
  mechanism for "devices together, maybe no internet" is Google Nearby Connections.
- **Android:**
  - Create `A/remote/NearbyRemoteTransport.kt` over
    `com.google.android.gms:play-services-nearby`, with strategy `P2P_STAR`. The host advertises and
    joiners discover.
  - Service id `com.levi.pocketdj.remote`. The endpoint name is the device name plus the session token
    hash.
  - Each envelope is one `Payload.fromBytes`.
  - The star topology means the host relays participant→participant traffic. `RemoteRecipient.all` from
    a participant goes to the host, which fans it out. Keep "never echo to sender".
  - Participant ids: a per-session random UUID string sent in the first frame. Never use the Nearby
    endpoint id; the election compares ids, so they must be comparable across devices.
  - Reliability: Nearby BYTES payloads are reliable and ordered per endpoint. The unreliable lane maps to
    the same path, but keep the queue's coalescing so pings never back up.
  - Payload limit ~32 KB per BYTES payload: the state cap (60,000) must be lowered for this transport.
    Make `maxStateBytes` a property of the transport; the window-halving loop already handles it. Or
    chunk the payload.
  - Invite: the host shows a QR plus a 6-character code, encoding `pocketdj://remote/join/<token>`. The
    joiner scans with the system camera (App Links) or types the code. The Join list also shows
    discovered nearby hosts with a confirm prompt. Authenticate with the token in the connection request
    and reject on a mismatch. Use Nearby's auth digits as a visual check.
  - Manifest permissions:
    - `BLUETOOTH_SCAN` (neverForLocation), `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`;
    - `NEARBY_WIFI_DEVICES` (neverForLocation), `ACCESS_WIFI_STATE`, `CHANGE_WIFI_STATE`.

    Location is already granted elsewhere. Request at start or join with a rationale sheet (Levi: request
    every permission needed).
  - A foreground-service type is needed while a speaker session runs in the background. Playback already
    holds `FOREGROUND_SERVICE_MEDIA_PLAYBACK`. A controller with no playback needs `connectedDevice`, or a
    keep-alive inside the media service. Verify on device.
- **Limit:** a nearby-only transport means Listen Together across distance is not possible on this
  transport. See R4.

### R4. Internet broker transport (and the iOS↔Android bridge) — MISSING (equivalent, ~400 Android + ~300 server lines, medium)
- **iOS:** none. iOS has no non-SharePlay transport.
- **Android:**
  - Server: add `/remote` routes to `scripts/jukebox-server.mjs`, beside `/mwf`:
    - `POST /remote` → `{roomId, joinCode, hostSecret}`
    - `POST /remote/{id}/join` → `{participantId, secret}`
    - `POST /remote/{id}/send {to:'all'|pid, reliable, env}`
    - `GET /remote/{id}/poll?since=seq` (25 s long-poll) → `{events:[{seq,from,to,env}], roster:[pid…]}`
    - `POST /remote/{id}/leave`
  - Server behaviour: in-memory ring buffer, TTL sweep, per-room caps, and the same per-IP sliding-window
    limit as requests. Long-poll is used because Tailscale Funnel, Lambda/API Gateway and URLSession all
    handle plain HTTP, and the fin memory notes URLSession can't talk to API Gateway WebSockets.
  - Client: `A/remote/BrokerRemoteTransport.kt` (OkHttp) talks to the user's configured
    `jukeboxServerUrl`. The option is hidden when blank.
  - Clock: SharedClock's min-RTT filter absorbs long-poll latency for Listen Together (750 ms threshold).
    For Mix Together the uncertainty-scaled drift threshold widens automatically, so warn "best on the
    same Wi-Fi".
  - Cross-platform: if iOS later adds a `BrokerTransport: RemoteTransport` with the same routes, iOS and
    Android join the same session with **no Android change**, because the wire is identical. Record that
    as a follow-up. It is not a parity requirement.
- **Feasibility:** equivalent. It is optional for the release, and its value is medium, because most
  Play users have no jukebox server.

### R5. SharedClock — MISSING (direct, ~110 lines, high)
- **iOS:** `SharedClock.swift`.
- **Android:** `A/remote/SharedClock.kt`.
  - Use `System.currentTimeMillis()` as `localNow`, injectable.
  - Use `elapsedRealtime` deltas inside an exchange if wanted, but the offset must be to the host's
    epoch-ms, because anchors are epoch-ms Doubles on the wire.
  - Keep 8 samples, pick the best by lowest RTT, and `reset` on host change. `isSynced=false` means no
    drift corrections.

### R6. Host queue model — MISSING (direct, ~280 lines, high)
- **iOS:** `RemoteQueueModel.swift`.
- **Android:** `A/remote/RemoteQueueModel.kt`, a pure data class with
  `apply(command, now, shuffler): Boolean`.
  - Shuffle keeps `canonicalUpcoming` for unshuffle.
  - `play` resets shuffle.
  - `advanced(fromRid)` only applies while `fromRid` is current.
  - Window constants are 20 behind and 200 ahead.
  - Port the model tests from `RemoteSessionTests.swift` one to one.

### R7. RemoteSessionController (Listen Together + Backseat engine) — MISSING (direct, ~1,300 lines + ~900 test lines, high)
- **iOS:** `RemoteSessionController.swift`.
- **Android:** `A/remote/RemoteSessionController.kt`. It is app-scoped and lives in a new
  `A/di/RemoteGraph.kt` registered through `FeatureModule`, never tied to a screen or Activity.
  - Port: `attach(transport, mode, asHost, seed)`, `leave`, `setLocalRole`, `send`, `rows(for:)`,
    `interceptLocalTransport`, `registerHandler/ActivityProbe/SessionObserver/ControllerSilencer`,
    `rejoinHere`, `shareInviteEnded`, `handle`, `shouldYield`, the election, `seedHostModel`, `broadcast`
    with size-capping, heartbeat, `refillFromLocalSource`, `tick` (0.5 s on Main), `reconcileLocal`,
    tail edit, `bindRids`, local change → command diffing, and the unplayable-here set.
  - Keep every constant and invariant in §1.3.
  - Status messages go to UI state. Diag goes through `A/diag` with the tag `remote`.
  - Device name: Profile "PocketDJ name" + `Build.MODEL` ("Levi's Pixel 9"), matching
    `RemoteDevice.name(owner:)`. `platform` = "android". `caps` = `["mix"]` once R11 lands.

### R8. Sequencer / player seams for Remote — MISSING (direct, ~450 lines, high, prerequisite of R7)
- **iOS:** `SetlistPlayer.swift:460-480, 5535-5600` (`TransitionCause`, `transitionSeq`,
  `lastUserTransitionSeq`, `userPlayIntentSeq`/`lastUserPlayIntent`, `applyingRemote`,
  `remoteControllerGate`, `RemoteRedirect`, `heldByRemote`), plus `RemotePlaybackTarget.swift`.
- **Android:**
  - In `A/playback/sequencer/SetlistSequencer.kt`:
    - Add `TransitionCause {USER, NATURAL_END, AUTO_SKIP, STALL_HOP, UNPLAYABLE, REMOTE}`, recorded at
      every current-row change. Map the existing `AdvanceCause`, and split AUTO into natural end versus
      dead-source/stall.
    - Add `transitionSeq`, `queueGeneration` (bumped on any queue mutation) and
      `noteListenerPlayIntent` (called only from user ▶/⏸ paths: the UI, the MediaSession
      `onPlay`/`onPause` from a controller, the widget, Auto and the Assistant; never from an
      interruption or a cascade).
    - Add `applyingRemote {}` and `play(items, startIndex, atMs, startPaused)`.
    - Add `jumpToUpcoming(uid, atMs)`: the start cue, because a seek after the jump hits the old
      backend.
    - Add `replaceUpcoming(firstCount, items)`, `insertUpcoming(items, beforeUid)`,
      `silenceForController()`, and `remoteControllerGate: ((RemoteRedirect) -> Boolean)?`.
  - Route MediaSession, the notification, widget commands (`A/widget`), Android Auto (`A/auto`), the
    Assistant (`A/assistant`) and Browse ▶ through the gate. `PlaybackController` is the funnel.
  - `isSystemPaused`: Android's AUDIO_BECOMING_NOISY, permanent focus loss, or a transient loss that
    didn't resume (PlaybackService listener-pause classification, parity doc line 288). Expose it as the
    `pausedHere` trigger.
  - `hasCoarsePosition` = the Apple Music backend is active (`A/playback/am`).
  - Then create `A/remote/SequencerRemoteTarget.kt` implementing the target interface.

### R9. RemoteSongResolver — MISSING (direct, ~230 lines, high)
- **iOS:** `RemoteSongResolver.swift`.
- **Android:** `A/remote/RemoteSongResolver.kt`, with seams for:
  - the catalog by id;
  - the catalog by appleMusicId (index song `appleMusicId`);
  - `am:<id>` when the Android Apple Music backend is usable (`A/playback/AppleMusicBackend.kt`);
  - the exact normalized title|artist key, reusing the jukebox matcher's normalizer;
  - the fuzzy match via `A/data/jukebox/JukeboxMatcher.kt`, for the current row plus 3 only.

  Production wiring uses `CatalogRepository` plus the burned, rip and profile-source resolvers. Outbound
  rows are stamped with `appleMusicId`.

### R10. Remote screen UI — MISSING (direct, ~800 lines, high)
- **iOS:** `RemoteView.swift`.
- **Android:** `A/screens/remote/RemoteScreen.kt` (+ `RemoteComponents.kt`).
  - **Start:** "Listen Together" ("Everyone plays the same music in sync — anyone in the session can
    change it.") and "Backseat" ("Your device becomes the remote. A passenger's phone on the car stereo
    plays the music."). Each shows the invite QR and code, or a Join action (scan, enter a code, or pick
    a discovered nearby host). The footer explains that each device plays from its own library or Apple
    Music.
  - **When active:**
    - a status message;
    - a paused-here card ("Paused on this device — tap ▶ to rejoin" + Rejoin);
    - the Session section: a "This device" picker (Speaker / Remote control) and Leave Session;
    - the Mix Together section (R11);
    - Participants: a peer row with a speaker/controller icon, Host and role badges, and "N songs can't
      play here";
    - Now playing: title, artist, a scrubber with drag-to-seek, and the ⏮ ▶/⏸ ⏭ transport, all sent as
      commands, never to the local player;
    - Repeat and Shuffle toggles;
    - Up Next: per-row Play Now, Play Next and Remove, drag-reorder sent as `reorder`, and an
      "Unavailable on …" note;
    - Add: catalog search capped like iOS `RemoteView.search`, with Play Now, Play Next and Add to Queue.
  - Test tags mirror the iOS ids (`remote-view`, `remote-playpause`, `remote-prev`, `remote-next`,
    `remote-peer-<id>`).

### R11. Mix Together (multiplayer 2-deck Mix) — MISSING (direct, ~2,300 lines + ~1,200 test lines, medium)
- **iOS:** `MixSync.swift`, `MixSyncModels.swift`, `MixSyncViews.swift`, `RemoteView.mixTogetherSection`,
  and `MixEngine` seams (`gestureTap`, `applyingRemote`, `syncPlay(atHostTime)`, `syncSetControls`,
  `syncSetLoop`, `syncNudgeRate`, `syncSeedEvents`, `setAutoDJBlocked`, `syncSessionActive`,
  `syncSilenceForController`).
- **Android:**
  - Create `A/remote/mix/MixSync.kt`, `MixSyncModels.kt` and `A/screens/remote/MixTogetherSection.kt`.
  - Add a `MixSyncEngine` interface implemented by `A/mix/engine/MixEngine.kt`:
    - A gesture tap with a cause (user / system / engine). Emit it beside `MixRecordingHooks.emit`; the
      hook already sees every kind.
    - A remote-apply depth guard: no tap, and no session-log record.
    - A scheduled start at a local wall-clock instant via the engine's shared render clock (the D-section
      "shared render clock for scheduled starts"), fired early by the AudioTrack output latency
      (`AudioTrack.getTimestamp`).
    - A ≤1% rate nudge on top of tempo.
    - An exact-window loop set.
    - Whole-board control diff/reset.
    - Seed events.
    - An `AutoDj` block with a reason.
    - A suspend for `MixDeckSessionStore`/durable-session persistence while active.
    - Silence-for-controller.
  - Deck load resolution reuses the R9 ladder against burned and streamable files. The `mix.ready`
    states are ready, loading, unavailable and empty.
  - UI: "Mixing together" + per-deck owner with Claim/Release, "Paused on this device" + Rejoin, and
    "'X' isn't available on this device — this deck stays silent here" / "Silent on …".
  - Mix screen entry (`A/screens/mix/MixScreen.kt`) shows a live "Mixing together" banner.
- **Caveats:** Android Mix already only loads mp3 PcmSources (Q116). The 40 ms sync target needs
  device verification. The emulator phase-align residual was 4-13 ms (Q107).
- **Feasibility:** direct. Value is medium because it needs 2+ Android devices.

### R12. Cross-feature suspensions while a session is live — MISSING (direct, ~80 lines, medium)
- **iOS:**
  - `PocketDJApp.swift:1560-1562`: `setlistPlayer.remoteSessionActive` suspends DJ Mode.
  - `Intents/IntentServices.swift:131,622`: an Auto-DJ start is refused while mixing together.
  - `MixSync.autoDJBlockedReason`.
- **Android:**
  - Expose `RemoteSessionController.isActive` as a `StateFlow`.
  - The DJ Mode port (other area) must check it before an early fade-start or a re-order.
  - `AutoDj.start` refuses with the iOS copy when `MixSync.active`.
  - `A/assistant` and App Actions handlers and the Auto Mix tab surface the same refusal.

### R13. Backseat controller covering every Android transport surface — MISSING (direct, folded into R8, high)
- **iOS:** `interceptLocalTransport` forwards panel, widget, lock screen, AirPods, CarPlay, Siri and
  Browse ▶ to the session.
- **Android:** the gate must also cover:
  - the MediaSession, including Bluetooth/headset buttons and the Android Auto session;
  - the Glance widget's command receiver;
  - the media notification;
  - Assistant voice commands;
  - quick play from Browse, Collections and History (`ShellActions`).

  Silence: `silenceForController` holds the sequencer AND the Mix decks AND the NP DSP host
  (`A/mix/nowplaying/NowPlayingDspHost.kt`), re-asserted every tick. Without the DSP host, a DSP-owned
  track keeps sounding on the controller.

### R14. Remote showcase seed for store screenshots — MISSING (direct, ~90 lines, low)
- **iOS:** `RemoteSessionController.seedShowcaseIfRequested` (`PDJ_SEED_REMOTE=showcase`): a loopback hub
  plus an in-memory "Car" speaker playing the showcase set, 1:37 into track 1.
- **Android:** a DEBUG-only launch extra `pdj.seedRemote=showcase` (follow the Q82 debug-extra pattern)
  so Play screenshots can show the Remote half without two devices.

### J1. Jukebox Hero "Timeless" toggle — MISSING (direct, ~90 lines, medium)
- **iOS:**
  - `Views/JukeboxView.swift:131` "Timeless — never expires" on create, and l.301 on the live session.
  - `Jukebox/JukeboxClient.swift:83` `create(name:timeless:requiresToken:)`.
  - l.129 `configure(_:timeless:)` → `POST /jukebox/{id}/config {timeless}` returns
    `{timeless, expiresAt}`, merged locally.
- **Android:** `A/data/jukebox/JukeboxClient.kt` gets a `timeless` create param and `configure(timeless)`.
  `JukeboxUrls.config()` is new and must use the `/config` path with the hostKey auth used by the iOS
  client. `JukeboxRepository` gets `setTimeless`, merging `expiresAt`. `JukeboxScreen.kt` gets the create
  toggle and the live toggle.
  - Show the footer copy "Every session runs for 24 hours and cleans itself up after 7 days…".
  - Never render the hostKey.
  - The server already supports this (jukebox-server `rest === '/config'`).

### J2. Mix broadcast (antenna) button — MISSING (direct, ~100 lines, medium)
- **iOS:** `Mix/MixView.swift:369-412` `broadcastButton` (`mix-broadcast`).
  - With no session, it creates one and pushes the Jukebox route (Back returns to the decks).
  - When a session is live, it glows accent and the tap just opens the jukebox.
  - Snapshot precedence is mix > sequencer > single.
- **Android:** the data side exists (`MixJukeboxSource.kt`, `JukeboxRepository` `mixSource`; MIX-16).
  Add an antenna `IconButton` next to Record in `A/screens/mix/MixScreen.kt`. It calls
  `JukeboxRepository.create(defaultName)` when there is no session, then navigates to the jukebox via
  `NavRequestBus`/`ShellNavigation`, landing on the Hero half.

### J3. Android Auto jukebox QR — PARTIAL (equivalent, ~80 lines, low)
- **iOS:** `CarPlay/CarPlayScene.swift:241-340`: Mix tab → Jukebox → sessions → a QR image row at max size
  plus the URL text.
- **Android:** `A/auto/AutoMixTab.kt` lists sessions but shows no image (Q83). Render the zxing QR bitmap
  (`JukeboxQr.kt`) as the session `MediaItem`'s artwork, a `content://` URI from a FileProvider, so the
  Auto now-playing/browse tile shows the code. Verify on a DHU, since some head units downscale artwork.

### J4. Jukebox Hero core / history / radio / dedup / guest join / Tune-In / MwF — PRESENT
- Present in `A/data/jukebox/*` and `A/screens/jukebox/*` (create, QR, share, View+Hear, inbox, AM match,
  played list, End, sessions picker, joined strip, guest Tune-In with `TuneInSeekMath`).
- Played-history dedup is server-side only (memory `jukebox-played-history-dedup.md`); Android renders
  `played` verbatim, which is correct.
- MwF is GM-10, and the FCM push alternative was declined (Q4).
- Record only. The Remote work must not regress `JukeboxRepository` mix seams: requests insert via the
  Mix's `autoQueueInsert`, never before `autoNextToLoad`.

### S1. Now Playing Share — MISSING (direct, ~45 lines, medium)
- **iOS:** `Views/NowPlayingPanel.swift:650-692`. It uses `ShareText.forSong(song)` when the catalog
  knows the id, otherwise `forTitleArtist`.
- **Android:** add a Share action to the Now Playing overflow/long-press in `A/screens/nowplaying/`,
  using `ShareText.send(context, text)`. Hide it when nothing is playing.

### S2. History multi-select Share — MISSING (direct, ~60 lines, low)
- **iOS:** `Views/HistoryView.swift:765` `ShareText.forSongs(selectedSongs)` in the select-mode toolbar.
- **Android:** `ShareText.forSongs` exists with no caller (Q16). Add Share to the History (and Browse)
  multi-select bar.

### P1. Profile sync Android↔Android go-live — PARTIAL (direct, ~20 lines + an infra publish, medium; needs Levi's OK)
- **iOS:** CloudKit `CloudSyncService` across iOS devices (`Services/CloudSync/*`).
- **Android:** the engine, S3 backend, link-a-device (code + QR display) and the Q120 deleted-profile
  state are all built, but the live endpoints doc lacks `profileSyncBase` and the `profileSyncEnroll`
  capability. Q119 deferred this for 1.0.
  - Approach: Levi decides. If yes, publish `config/endpoints.green.json` (`CONFIG_ONLY=1
    scripts/deploy.sh prod`). The token being world-readable is guarded by MAX_PROFILES.
  - Add a camera QR **scanner** to `LinkDeviceScreen.kt` (deferred in SVC-9). Use the CameraX + zxing
    or ML Kit barcode scanner, plus the `CAMERA` permission.
  - Register `pocketdj://link`.
  - Make Delete account call `deleteProfile()` (Q54).
  - Verify the two-device link and pull.

### P2. Sync registry gaps — PARTIAL (direct, ~30 lines, low)
- **iOS:** `PocketDJApp.swift:1947,1957` registers `profile-source` and `pocket-palette`.
- **Android:**
  - Register `SyncEntry("profile-source", ProfileSourceStore.FILE_NAME, onPulled = reload)` in
    `A/di/StudioGraph.kt`.
  - Register `pocket-palette` once the wheel area ports `PocketPaletteStore` (`pocketdj-pocket-palette.json`,
    keep the iOS shape).
  - `edits` waits on a browse-area edits store.
  - `apple-music-library` stays iOS-only: it mirrors the MusicKit library.
  - Each new key must also be added to the account-deletion `cloudDocKeys` list.

### P3. iOS↔Android profile sync — OUT OF SCOPE
iOS profiles sync through CloudKit (private DB `iCloud.com.levi.pocketdj`), and Android cannot reach
CloudKit with a user's iCloud identity. Cross-platform sync would need iOS to adopt the S3
`pocketdj-profile-sync` backend. That is an iOS change, not an Android parity item. Doc shapes are already
identical (D7), so it remains possible later.

### X1. Join an iOS SharePlay session from Android — PLATFORM-IMPOSSIBLE
GroupActivities/`GroupSession` is an Apple framework. Sessions are created and routed by FaceTime, Messages
and Apple nearby-sharing through Apple's servers, and there is no public protocol or non-Apple client. The
only cross-platform route is R4 plus a future iOS `BrokerTransport`.

### X2. Remote audio relay (host streams audio to peers) — OUT OF SCOPE
`docs/design/remote-audio-relay.md` is PARKED on iOS (2026-11-08), and nothing is built there.

### X3. 4-deck band-jam Mix Together — OUT OF SCOPE
Not built on iOS. Levi: "4 deck refactor comes as a separate release".

### X4. tvOS Remote view — OUT OF SCOPE
`TVRemoteView.swift` covers Apple TV as a speaker. Android ships as a phone/tablet app. If Google TV is
ever targeted, the R7 speaker role ports directly.

---

## 4. Suggested package order

1. R2 + R5 + R6 (pure, JVM-testable, golden JSON).
2. R8 (sequencer seams; touches playback, so a careful review is needed).
3. R9 + R7 + R13 + R12, then R10 + R1.
4. R3 (Nearby; device-verify on two phones, one on the car stereo).
5. R11 (Mix Together; device-verify).
6. J1, J2, S1, S2, R14, J3 (small and independent).
7. R4 (optional broker) and P1/P2 (gated on Levi).

Verification notes:
- Port `RemoteSessionTests.swift` (1,139 lines) and `MixSyncTests.swift` (1,372 lines) as JVM tests over
  `LoopbackHub` with latency and drop injection. They encode the review-round regressions: system pauses,
  held Mix decks, send-queue ordering, saved-mix survival, election races, unavailable-row loops and
  duplicate advance.
- Nearby needs two physical devices. The emulator can't advertise or discover.
