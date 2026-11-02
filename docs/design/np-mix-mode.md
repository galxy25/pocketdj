# Now Playing Mix Mode (design, 2026-11-02)

Status: DESIGN ONLY. No code has been written. Branch: `feat/np-mix-mode` (sub-branches per phase,
`feat/np-mix-mode-p1` …).
Platforms: iOS/iPadOS, macOS, visionOS (they share `NowPlayingPanel`). tvOS is out of scope for v1
(§1.1). Android follows the parity program later.

## 0. Levi's ask, restated as requirements

> "ability to enable mix mode from now playing, this should result in buffering locally the current
> and upcoming songs locally (with downloaded assets expiring after a settings value that defaults to
> 48 hours unless those assets are downloaded as part of an explicit mix or download action before
> the expiration window) so that you can use stems and effects / the full range of mini-mix controls
> from any playback session, not just for audio you have already downloaded or via an active mix tab"

| # | Requirement | Where |
|---|---|---|
| R1 | A **Mix Mode** toggle on Now Playing | §1 |
| R2 | Mix Mode **buffers the current + upcoming songs locally** (audio + stems) | §2 |
| R3 | Buffered assets are **temporary**: they expire after a Settings value, **default 48 h** | §3.1–3.4 |
| R4 | An **explicit Mix or Download action** before expiry makes the asset permanent | §3.3 |
| R5 | Stems, effects and the whole mini-mix panel work in **any playback session** (playlist, pocket, queue, Jukebox, game, Pocket Wheel run, CarPlay-started), not only for downloaded audio or the Mix tab | §1.3, §4 |
| R6 | Standing rules: zero dead air, one audio owner / one card writer, already-downloaded media never becomes temporary, the storage manager never evicts what is playing | §3.5, §4 |

### 0.1 What already exists (and is reused, not duplicated)

This feature is mostly a generalisation of two shipped pieces: **F4** (the Now Playing mix
mini-panel) and **Stem Lock** (which already prefetches the next songs + stems).

| Piece | File | What it gives us |
|---|---|---|
| F4 mini-panel | `Views/NowPlayingMixPanel.swift` | Tempo / pitch / gain / FX / stems / Stem Lock UI, bound to `NowPlayingDSP`. Hidden today unless the track is a local file. |
| `NowPlayingDSP` | `Playback/NowPlayingDSP.swift` | Single-deck fork of the Mix deck chain (`player` + 4 stem nodes → inputMixer → TimePitch → comp → EQ → reverb → flanger → limiter). Zero-dead-air stem handover, streaming stems, interruption/route-change handling. **Requires a complete local file today.** |
| AVPlayer → DSP swap | `SetlistPlayer.engageMix(atSeconds:play:)` | Swap-on-touch at the current position; card stays single-writer via `PlayerEngine.beginExternalNowPlaying`. `handleDSPEnded` advances; `endMixEngagement` tears down. |
| Eligibility gate | `SetlistPlayer.currentTrackMixable` / `mixAvailable(mixActive:)` | Keyed off the ACTUAL playing URL being a file URL; AM / live / stream ⇒ not mixable. |
| Stem Lock | `Playback/StemLock.swift`, `SetlistPlayer.applyStemLockOnTrackStart`, `replanStemLock` | Session-scoped state persisted in `PlaybackSessionStore.Snapshot.stemLock`; pure `StemLockPrefetcher.plan(current:upcoming:carry:network:window:)`; one-at-a-time worker with `PlaybackRunway` per step; `StemLockNetworkMonitor` (unmetered / expensive / constrained / offline); fire-and-forget `RipsStore.stemify` (owner only). |
| Growing-file streaming | `Mix/MixStreamLoader.swift`, `MixEngine.loadStreaming` / `pumpStream` / `streamHolding` | Byte-by-byte rip download into Caches/mixstream; a finished stream is ADOPTED as a normal burn (`BurnStore.adoptStreamedFile`). Stem sets with per-engine claims (`mixStemOwner`, `nowPlayingStemOwner`). `canStream` offline/cooldown gate. |
| Burn ledger | `State/BurnStore.swift` | `BurnItem` ledger (per device, NOT cloud-synced), stems as `stem-<id>-<part>.mp3` files with no ledger row, `burnStemPart`, `burnStems`, `burn(_:automatic:)`, `burnWhenRipped`, `startRipAndBurn*`, `planEviction`, `removeBurns`, `removeStems(forSongs:protecting:)`. |
| Storage manager | `State/StorageManager.swift`, `Views/StorageView.swift` | Soft cap (nil = never auto-manage), `prune()` chunked async, `protectedSongIds` (decks + now playing + current row), BG task `com.levi.pocketdj.storage-prune`. |
| Playback rip window | `Playback/PlaybackRipWindow.swift` | Playback-originated rips only for the playing row + next 10; out-of-window rips cancelled; same-host deferral on the rip-server Mac (`RipServerPlaybackProvider.requestAsyncRip`). |
| Provider order | `PlaybackCoordinator.providers(for:)` | AM-sourced rows stream Apple Music FIRST even when ripped; rip provider is the fallback. |
| Durable sessions | `State/PlaybackSessionStore.swift` | Optional-field snapshot additions need no schema bump (the `stemLock` precedent). The snapshot IS cloud-synced (`cloudSync.register("playback-session")`). |
| AM near-end pre-arm | `SetlistPlayer.handleAppleMusicNearEnd`, `PlayerEngine.prearmHandoffSession` | Mixable session pre-arm so a locked phone can take audio back from MusicKit (the '!int' lesson). |

The hard truth F4 recorded still holds: only a **local file** can be routed through
`AVAudioEngine`. Apple Music (`ApplicationMusicPlayer`, out of process, DRM) can never be DSP'd.
So Mix Mode's whole job is **to make the current and upcoming rows local files** and then reuse
F4 + Stem Lock unchanged where possible.

---

## 1. UX

### 1.1 Where the toggle lives

| Platform | Location | Notes |
|---|---|---|
| iPhone | Now Playing deck, the Mix panel header (`NowPlayingMixPanel.header`). A **Mix Mode** capsule switch (`np-mix-mode`, icon `waveform.badge.plus`) sits at the right end of the header row. Also in the Now Playing ⋯ menu and the mini-player's context menu ("Mix Mode", checkmark). | The panel header is now **always shown** while a session runs (today it hides on non-mixable tracks). Collapsed it is one line: chevron · "Mix" · status chip · switch. |
| iPad | Same header, same place in the deck column. | |
| macOS | Same header, plus a menu command **Controls ▸ Mix Mode** (⌥⌘M) next to the existing transport commands. | |
| visionOS | Same header (the window reuses `NowPlayingPanel`). | |
| tvOS | **Not in v1.** The TV Now Playing tab is its own deck (`TVRootView`, not `NowPlayingPanel`), it has no mix panel at all, and the TV storage cap defaults to 5 GB. | Open question Q10. |
| CarPlay | No toggle (system templates). The state carries: a session with Mix Mode on keeps buffering when started or continued in the car. The Up Next list's row detail can show "Buffering…" (the `MixBufferingBadge` text pattern) in phase 5. | |

Turning Mix Mode ON auto-expands the panel once (it writes `nowPlayingMixExpanded = true`).

### 1.2 States (the status chip in the panel header)

`SetlistPlayer.mixModeIndicator: NPMixMode.Indicator` drives one chip, the same way
`stemLockIndicator` drives the Stem Lock row:

| Indicator | Chip text | When |
|---|---|---|
| `.off` | (no chip) | Mix Mode off. The panel behaves exactly as F4 today. |
| `.ready` | "Ready" (accent dot) | The current track is a local file (pinned burn, temporary buffer, studio/profile item). All controls live. |
| `.engaged` | "Mixing" (filled accent dot, today's engaged dot) | The DSP owns the audio. |
| `.buffering(fraction)` | "Buffering 42%" | The current track's local copy is downloading (it plays meanwhile from its stream). Controls are visible but disabled, with the progress in the chip. Phase 3 removes most of this state (the DSP plays the growing file). |
| `.stemsLoading` | "Loading stems…" | Today's existing label, unchanged. |
| `.ripping` | "Ripping — mixable next play" | Owner only: an Apple-Music-only row is being ripped; this play stays on the AM stream. |
| `.unavailable(reason)` | "Apple Music only", "Live capture", "Offline", "Download failed" | Nothing local can exist for this play. The row explains why; controls hidden (F4's "hide, don't grey" rule stays for the truly impossible case). |
| `.suspended` | "Paused — Mix tab is live" | A Mix-tab session is playing (one DSP surface at a time). |

Below the controls, a one-line **buffer strip** shows the next N rows as dots
(● local · ◐ buffering · ○ queued · ⨯ unavailable), `np-mix-buffer-strip`. In phase 5 the same dot
appears on the Up Next rows.

### 1.3 Controls per session type

| Current row | What the panel shows |
|---|---|
| Pinned burn / studio / profile item | Today's F4 panel (tempo, pitch, gain, FX grid, stems + Stem Lock). With Mix Mode on, its stems are prefetched so the Stems toggle is instant. |
| Ripped song (digital or vinyl), not on device | Phase 2: "Buffering n%" while the rip downloads (the song plays from the presigned AVPlayer stream meanwhile); when the file lands, playback moves to the local file at the same position automatically (same bytes, §4.2) and the controls go live. Phase 3: the row STARTS in the DSP on the growing file, so controls are live from the first second. |
| Apple-Music-sourced song that IS ripped | With Mix Mode on the session prefers the rip over the AM stream (§2.4), so it behaves like the row above. A row that already started on AM (Mix Mode turned on mid-song) shows "Ready — tap a control to switch to the local copy" once the local file lands (§4.3). |
| Apple-Music-only song (not ripped) | Owner: `.ripping` ("mixable next play"); this play stays on AM, no controls. Non-owner (hybrid/public user): `.unavailable("Apple Music only")`. |
| Live capture (stream-through-rip HLS), `am:` Jukebox catalog-only id | `.unavailable`. |

### 1.4 Turning Mix Mode on mid-song

- Current track already local: nothing audible happens. The panel's controls go live; the first
  touch engages the DSP exactly like F4 (swap-on-touch).
- Current track streaming from a presigned rip URL (AVPlayer): the buffer lane fetches the same
  object first; when it is complete, an **automatic hand-off** moves playback onto the local file
  at the AVPlayer's position (`handOffCurrentToLocal()`, §4.2). Same bytes, so the cut is
  position-exact; a 30 ms volume dip hides the reload. Controls then go live, and the first touch
  engages the DSP as above. (With the Stem Lock carrying stems, the hand-off engages the DSP
  directly through `engageMix(atSeconds:play:)`.)
- Current track on Apple Music: no automatic hand-off. When a local copy exists, the panel offers
  it; the first control touch cuts over at MusicKit's position (§4.3, open question Q1).

### 1.5 Turning Mix Mode off

- Buffering stops (the lane cancels pending steps; an in-flight step is cancelled if it is a
  speculative one, see §2.6).
- The current track **keeps whatever it is playing** until its end: an engaged DSP keeps its
  controls (no audible jump mid-song); the next track plays the plain path. This is what F4 does
  today when the user simply stops touching controls.
- Buffered files are NOT deleted. They stay temporary and expire on schedule (§3).
- The Stem Lock is independent and keeps working on local tracks, as today.

---

## 2. Buffering pipeline

### 2.1 One lane, generalised from Stem Lock

Do not add a second prefetcher. `StemLockPrefetcher` becomes **`NowPlayingPrefetcher`** (file
renamed `Playback/NowPlayingPrefetch.swift`, `typealias StemLockPrefetcher = NowPlayingPrefetcher`
for one release so tests and call sites move gradually). Its pure planner gains the Mix Mode
inputs; its worker, cooldowns, `PlaybackRunway` per step, `onStepFinished` and the
`StemLockNetworkMonitor` stay as they are.

```swift
// Playback/NowPlayingPrefetch.swift
struct NowPlayingPrefetchInput: Equatable {
    var current: Track?                 // the playing row (nil when held / not running)
    var upcoming: [Track]               // queue[index+1 ..< index+1+window]
    var stemLock: StemLockState         // unchanged meaning
    var mixMode: NPMixModeState         // NEW
    var network: NowPlayingPrefetcher.Network
    var window: Int                     // settings.npMixBufferAhead (default 3)
    var isCatalogOwner: Bool
}

extension NowPlayingPrefetcher {
    enum Step: Hashable {
        case song(id: String, title: String, artist: String)   // existing: MixStreamLoader whole song
        case stem(songId: String, part: String)               // existing: BurnStore.burnStemPart
        case rip(songId: String)                              // NEW: RipsStore.requestRipIfNeeded(playback: true)
    }
    struct Track: Equatable {                                 // existing fields +
        var source: Source                                    // NEW
        enum Source { case local, ripped, appleMusicOnly, catalogOnly, live, studioOrProfile }
    }
    static func plan(_ input: NowPlayingPrefetchInput) -> Plan    // supersedes plan(current:upcoming:carry:network:window:)
}
```

`SetlistPlayer.replanStemLock()` becomes `replanPrefetch()`, triggered by the same events
(track start, queue edit via `queue.didSet`, lock change, step finished) plus Mix Mode on/off and
a network-class change. `Track.source` is computed in `stemLockTrack(_:)` (renamed
`prefetchTrack(_:)`) from what is already there: `hasDeviceFile`, `MixStreamLoader.isRipped`,
`coordinator.streamsAppleMusicFirst`, `AppleMusicCatalog.storeID(fromSongID:)`.

### 2.2 Order (Mix Mode on)

Rips go out first because they take real time on the server; downloads follow in play order.

| # | Step | Why |
|---|---|---|
| 0 | `.rip` for the first **2** Apple-Music-only rows in the window (owner only, through the playback rip window) | A server rip is a real-time capture with concurrency 1, so only the next song or two can be ready in time. More would only queue captures nobody hears; `PlaybackRipWindow` cancels them if the playhead moves on. |
| 1 | `.song` for the CURRENT row if it is `ripped` and not local | Lets the current track hand off mid-song (§1.4). |
| 2 | Missing stem parts of the CURRENT row (enabled parts first when the Stem Lock carries a partial set; else all four, priority vocals → drums → other → bass) | The Stems toggle is instant on the playing track. |
| 3 | `.song` for the next row | The boundary plays a local file. |
| 4 | Next row's stems (same part priority) | |
| 5 | Rows 2…window: song, then stems, row by row | |
| 6 | Muted parts last (existing Stem Lock rule) | |
| — | `RipsStore.stemify` for ripped rows in the window with no stems anywhere (owner only, deduped per song id — the cloud stem fleet already dedups) | Fire-and-forget; playback never waits. |

With Mix Mode OFF the planner returns exactly today's Stem Lock plan (a regression test pins that).

### 2.3 Network and disk policy

| Network class | Window | Stems |
|---|---|---|
| Unmetered (Wi-Fi / Ethernet) | current + `npMixBufferAhead` (default 3) | All parts for every row in the window |
| Expensive (cellular) | current + next row | Current row: only when the user turns Stems on or the Stem Lock carries them. Next row: only the Stem Lock's enabled parts. |
| Constrained (Low Data Mode) | current row only | Only on demand (the toggle streams them, as today) |
| Offline | nothing (`MixStreamLoader.canStream` is already false) | — |

Settings (new, `SettingsStore`, all optional-decoded so old settings files load):
- `npMixBufferAhead: Int?` (nil ⇒ 3, picker 1/3/5/10).
- `npMixCellular: NPMixCellularPolicy?` (nil ⇒ `.nextSong`; also `.off`, `.full`).
- `npMixBufferTTLHours: Double?` (nil ⇒ 48; see §3.2).
- `npMixBufferCapGB: Double?` (nil ⇒ 2; see §3.4).

Disk guard: before each step the worker checks free space (`volumeAvailableCapacityForImportantUsage`)
≥ 1 GB and the temporary footprint below `npMixBufferCapGB`; otherwise it first evicts the
temporary assets that expire soonest and are not protected (§3.5), and skips the step if that is
not enough. Indicator for that row: `.unavailable("Storage full")`.

Device playback mode (`PlaybackMode.device`): the lane never downloads (same rule Stem Lock has),
but temporary assets already on the device play like any burn.

### 2.4 Sources

| Row | How it becomes local | Notes |
|---|---|---|
| Pinned burn, studio, profile | Already local | Stems: `burnStemPart` / profile stems |
| Ripped digital (bucket manifest) | `MixStreamLoader.open` → `adoptStreamedFile` | Adopted as a **temporary** burn (§3.3) |
| Ripped vinyl with a per-song cut | `MixStreamLoader.open` (cut stream) | Not adopted (existing rule); played via the `stemLockStreamedFile` seam, renamed `prefetchedCutFile`. The cut lives in Caches/mixstream and is tracked by the same temporary hold (§3.1) |
| Ripped vinyl without a cut | Album side stream, adopted | Shared side file: the hold is per song but the file is deleted only when no pinned or protected item references it (the existing `removeBurns` shared-analog rule) |
| AM-sourced, ripped | As "ripped digital". **With Mix Mode on, `PlaybackCoordinator.providers(for:preferLocalAudio: true)` puts the rip provider first for a row whose rip URL is cached or whose local copy is complete** | Only when the local copy is complete or the presign is cached, so it never trades an instant AM start for a slow presign (the dead-air rule). Otherwise AM plays and §4.3 applies |
| AM-only, owner | `.rip` step (server capture), then `.song` once the manifest flips | Same-host deferral: on the Mac that runs the rip server, rips are skipped while Apple Music plays (existing 10-14 rule), so those rows stay AM-only there |
| AM-only, non-owner | Never | Non-owners never enqueue server work (integrity audit rule) |
| Live HLS, `am:` catalog-only ids | Never | |
| Stems | `BurnStore.burnStemPart` (whole part file); the on-air streaming path (`MixStreamLoader.openStems` with `nowPlayingStemOwner`) stays for an on-demand toggle | Streamed stem sets adopted by `adoptStreamedStems` get the same temporary hold |

### 2.5 Concurrency with other lanes

- `MixStreamLoader.maxConcurrent` still caps song streams. `pinnedIds` gains the Now Playing
  current row and the next row (today it pins only Mix decks' streams), so the Mix tab's lane can't
  evict the current buffer.
- The Mix tab's `CollectionMixDownloader` wins: when a Mix session is live, Mix Mode is suspended
  (§4.5) and its lane pauses.
- The background burn lane: `yieldBackgroundDownload` already cancels a queued background burn of
  a song that starts streaming; the adopted file arrives with an explicit-origin flag in that case
  (§3.3), because the background burn was explicit.

### 2.6 Failures

- A step failure uses the existing per-step `failureCooldown` (120 s); the row's indicator turns
  `.unavailable("Download failed")` only when it becomes the current row and still has no file. The
  row plays through its normal path (AM / presigned), so a failure never costs audio.
- A row whose rip fails or never lands in time plays on AM. It stays rip-requested (heard ≥ 30 s ⇒
  the playback rip window keeps it), so it is mixable on a later play.
- Mix Mode never reorders the queue by default. An opt-in "Mixable songs first" (Q8) would reuse the
  stall-hop reorder (`hopToOnDeviceRow`'s "defer, never drop") for rows that are not local yet.
- `DiagLog` lane `[npmix]` (also on the `nowplaying` NPLog trace): mode on/off, per-track decision
  (`→ local`, `→ buffering`, `→ AM (ripping)`, `→ unavailable(reason)`), `plan net=… a → b → …`,
  each step `ok|FAILED ms=`, hand-offs with position + gap, holds created / pinned / swept.

---

## 3. Asset lifecycle: temporary vs pinned

### 3.1 Model

Today every file in the burn folder is permanent and stems have no ledger row. Add a **per-song
temporary hold** to the burn ledger. No hold = pinned. That default is what guarantees that
nothing already downloaded ever turns temporary, and that old ledgers decode unchanged.

```swift
// State/BurnStore.swift
struct TemporaryHold: Codable, Equatable {
    var songId: String              // the AUDIO id (variant-aware, as the files are named)
    var audio: Bool                 // the audio file (+ sidecar + cut) was created by the buffer lane
    var stemParts: [String]         // stem parts created by the buffer lane
    var cutFile: String?            // a Caches/mixstream analog cut played via prefetchedCutFile
    var createdAtMs: Double
    var expiresAtMs: Double
}

struct Document: Codable {
    // existing fields …
    var temporaryHolds: [TemporaryHold]? = nil   // ADDITIVE-OPTIONAL (no burnSchemaVersion bump)
}

enum AssetOrigin { case explicit(String), buffer }   // explicit("download"), explicit("mix"), …
```

A hold only lists the assets **the buffer lane created**. If the audio was already a pinned burn
and Mix Mode only fetched its stems, the hold carries `audio: false, stemParts: [...]`, and expiry
deletes only those stems.

### 3.2 The expiry window

- `SettingsStore.npMixBufferTTLHours: Double?`, nil ⇒ **48**. Picker in Settings ▸ Storage ▸
  "Mix Mode buffer": 6 h / 12 h / 24 h / 48 h / 3 days / 7 days / "Keep (treat as downloads)".
- `expiresAtMs = createdAtMs + TTL`, fixed when the asset lands (the literal reading of the spec;
  Q3 asks whether a replay should extend it). A TTL change applies to holds created afterwards.
  "Keep" makes new buffer assets pinned at creation.

### 3.3 Creation and promotion

Creation: the buffer lane is the ONLY producer of holds.
- `MixStreamLoader.open(_:title:artist:origin:)` gains an `origin` (default `.explicit("mix")`, so
  every existing caller stays explicit). The Now Playing lane passes `.buffer`. A stream joined by
  an explicit opener (a Mix deck opens the same song) upgrades the stream's origin to explicit:
  **explicit wins**.
- `BurnStore.adoptStreamedFile(…, origin:)` and `adoptStreamedStems(…, origin:)`: with `.buffer`,
  and only when no `.ready` item existed, write a hold for what was created.
- `BurnStore.burnStemPart(forSong:part:origin:)`: same rule for each part (a part already on disk
  is never added to a hold).

Promotion (pin) = drop the hold, keep the files. One funnel:

```swift
func pin(songIds: some Sequence<String>, reason: String)   // no-op for ids without a hold
```

Every **explicit Mix or Download action** calls it, including when the file is already there (the
freshness check in `burn` skips existing files, so the pin has to run before that skip):

| Explicit action | Call site |
|---|---|
| ⤓ Download (song / album / collection), Rip + Burn, recognizer add | `BurnStore.burn(_:automatic:)`, `startRipAndBurn`, `startRipAndBurnAlbum`, `burnWhenRipped` / `drainPendingAfterRip` |
| Mix tab: load onto a deck (manual or Auto-DJ) | `MixEngine.load(songId:…)` and `loadStreaming` (pin on load) |
| Mix tab download lane | `CollectionMixDownloader` (goes through `burn(…, automatic: true)`, already covered) |
| Mix streaming adoption by a Mix deck | `MixStreamLoader` origin `.explicit("mix")` |
| Explicit stem burn (Song Detail stems, Studio stem import, Demux) | `BurnStore.burnStems`, Tracks stem-import picker |
| Settings ▸ Storage ▸ "Keep all buffered" | `pin(songIds: holds.map(\.songId))` |

**Not** explicit (no promotion): Now Playing playback itself, Mix Mode / F4 control touches, Stem
Lock carry, CarPlay plays, Jukebox requests. Q5 asks whether Stem Lock's existing prefetches
(permanent today) should become temporary too; recommended yes.

An explicit action AFTER expiry just downloads again through its normal path; nothing special.

### 3.4 Footprint cap

48 h of heavy Mix Mode listening can reach several GB (≈ 8 MB song + 4 × 8 MB stems ≈ 40 MB per
song). So temporary assets get their own cap, `npMixBufferCapGB` (nil ⇒ **2 GB**), enforced by the
worker before each step and by the sweep: over the cap, the holds that expire soonest go first,
never protected ones.

### 3.5 Expiry sweep

```swift
// State/StorageManager.swift
func sweepTemporary(now: Double = Date().timeIntervalSince1970 * 1000,
                    reason: String) async -> SweepResult
```

- **Triggers:** launch (deferred, after first frame), scenePhase `.active`, every 60 min while in
  the foreground, the existing BG task `com.levi.pocketdj.storage-prune` (the sweep is NOT gated on
  the soft cap: the TTL is on by default), Mix Mode off (cap check only), and the worker's disk guard.
- **Protected set** = today's `protectedSongIds` (Mix decks, `rips.nowPlaying`, current row base +
  resolve id) ∪ the Now Playing window (current + next `npMixBufferAhead` rows, both ids) ∪ the held
  restored session's window (a relaunch must not sweep the songs it is about to play) ∪
  `MixStreamLoader` live streams and claimed stem sets ∪ `MixEngine.autoUpcomingSongIds` (first N).
  An expired but protected hold is skipped and re-checked on the next sweep, so in practice it lives
  until nothing uses it.
- **Deletion:** only what the hold lists. Audio goes through `removeBurns(songIds:)` semantics
  (shared-analog-aware, skip unreachable user folders, never drop a ledger row whose files can't be
  deleted); stem parts through a new `removeStemParts(_:forSong:)`; cut files in Caches directly.
- **Main-thread discipline (the 10-23 crash loop lesson):** stamp `lastTemporarySweepAt` first,
  plan with ONE scan, delete in chunks of 25 with `Task.yield`, re-read the protected set per chunk,
  single-flight with `isPruning`. `[storage] sweep start/done n= freed=` diag lines.
- **Soft-cap prune interplay:** `beginPrune`'s eviction order becomes: unprotected temporary holds
  (soonest expiry first), THEN the existing least-recently-played pinned burns.

### 3.6 Interaction with the rest

- **Sync:** the burn ledger is per device and is not cloud-synced, so holds are per device too. The
  playback-session snapshot IS synced; it carries only the Mix Mode flag (§4.6). Another device that
  restores the session starts its own buffer on its first ▶.
- **Downloaded counts / badges:** a temporary burn is a real file, so collection "N downloaded"
  counts, device mode and offline play all see it. The UI marks it: the download glyph shows a
  clock badge ("Buffered · expires in 31 h") in song rows and the Song Detail storage line. Tapping
  Download on a buffered song is an explicit action: it pins it.
- **Storage view:** a new "Mix Mode buffer" section: footprint, song count, next expiry, TTL picker,
  cap picker, "Keep all" (pin), "Clear now" (sweep ignoring expiry, still honouring the protected
  set). Delete-by-artist / by-collection / all keep deleting temporary files too (they are media).
- **Play stats / history:** unchanged. Plays in Mix Mode count like any play.
- **Rip server:** a Mix Mode rip is a normal server rip and stays in the bucket. Only device copies
  are temporary.

---

## 4. Playback ownership

### 4.1 Single deck, not Auto-DJ

Mix Mode stays on the **single-deck `NowPlayingDSP`** under `SetlistPlayer`. It does NOT turn the
session into a Mix-tab Auto-DJ session:

- `SetlistPlayer` owns the queue model every surface uses (Up Next edits, Pocket Wheel runs,
  Jukebox, history attribution, the skip tracker, CarPlay, App Intents, durable sessions). The Mix
  tab's auto queue is a different model; converting between them per toggle would fork every
  surface.
- F4 + Stem Lock already prove the hand-off, the end-of-track generation discipline and the single
  card writer on this path.
- Crossfades between songs are what the Mix tab is for. Phase 5 adds an explicit **"Open in Mix"**
  that hands the current + upcoming rows to Auto-DJ as an explicit mix (which pins them).

### 4.2 When the DSP owns the audio

`NPMixModeState` (Codable, session field like `stemLock`):

```swift
struct NPMixModeState: Codable, Equatable {
    var enabled = false
}
```

- **Default: engage on touch** (Q2). With Mix Mode on, a local current track still plays through
  the AVPlayer until the first control touch (F4's swap-on-touch, same bytes), so a Mix Mode user who
  never touches a control gets today's proven playback path and no AVAudioEngine battery cost. What
  Mix Mode adds is that the touch is *possible* (the file is local) and stems are instant (on disk).
- The Stem Lock keeps engaging at track start (`applyStemLockOnTrackStart`) when it carries stems.
- **Mid-song hand-off to a freshly buffered file** (`SetlistPlayer.handOffCurrentToLocal()`, from
  `onStepFinished(.song(current), ok)`): only when the current track is on the presigned AVPlayer
  stream of the same rip. It reloads the AVPlayer onto the local file at the same position (plain
  playback, not the DSP; a 30 ms volume dip covers it), so `currentTrackMixable` turns true and
  the next touch engages. Under the Stem Lock with stems on it engages the DSP directly instead
  (`engageMix(atSeconds:play:)`).
- `currentTrackMixable` gains the temporary-burn case for free (a hold doesn't change
  `hasDeviceFile`), and the `prefetchedCutFile` case it already has for Stem Lock.
- The **end-of-track** path is unchanged: `handleDSPEnded` → `endMixEngagement` → `advanceToNext`;
  the next track loads into the AVPlayer and (Stem Lock) re-engages in the same turn. Phase 5 can add
  a DSP-native boundary (`NowPlayingDSP.preloadNext`) if the dead-air meter shows a gap there.

### 4.3 Apple Music → local

- A row that **starts** with Mix Mode on and has a local copy (or a cached rip presign) plays from the
  rip, never from AM (§2.4). That is the main path and has no mid-song problem.
- A row that is **already on AM** (Mix Mode turned on mid-song, or the rip landed mid-song):
  - No automatic hand-off. MusicKit's `playbackTime` is laggy (the provider already smooths it), the
    capture's lead-in offset against the AM rendition is unmeasured, and a hard cut nobody asked for
    is worse than finishing the song on AM.
  - When a local copy exists, the panel shows "Ready — tap a control to switch to the local copy".
    The first touch performs `handOffFromAppleMusic()`: read the smoothed AM position, add the measured
    `amHandoffLeadMs` (phase 0 spike), open the DSP paused at that position, `prearmHandoffSession`
    (mixable) if the app is not active, stop MusicKit (`coordinator.stopAppleMusicIfActive()`), start
    the DSP, take the card back via `beginExternalNowPlaying`, `promoteSessionIfMixable`. Expect a
    short audible seam (≤ ~0.3 s once calibrated). Q1 asks whether Levi wants it automatic instead.
  - macOS: MusicKit publishes its own Control Center entry; after the hand-off our `PlayerEngine`
    reclaims the card (the existing non-AM path).

### 4.4 Lock screen, CarPlay, remote commands

- One card writer, unchanged: the DSP never touches `MPNowPlayingInfoCenter`; `PlayerEngine`'s
  external-source path publishes position / rate / play / pause closures (the F4 mechanism).
  Remote ⏭ / ⏮ / play-pause drive `SetlistPlayer` as today.
- CarPlay: no new template. Mix Mode keeps buffering in the car (cellular policy applies). Because
  engagement is on touch, CarPlay playback is the plain path unless the Stem Lock carries stems.
- Interruptions and route changes: `NowPlayingDSP` already handles them. A **media-services reset**
  is not handled by `NowPlayingDSP` (known limitation). Mix Mode increases exposure, so phase 2 adds:
  on `mediaServicesWereReset` while engaged, `endMixEngagement` and reload the AVPlayer at the DSP's
  `playAnchor` position.

### 4.5 The Mix tab

- One DSP surface at a time (F4 decision 3). When a Mix-tab session goes live, the existing
  `observeMixSessionForEngagement` tears down the Now Playing engagement. Mix Mode itself stays ON
  but **suspended** (`.suspended` chip): the prefetch lane cancels its pending steps and the sweep
  keeps its window protected. When the Mix session stops, the next replan resumes it.
- Buffered temporary files are ordinary on-device files to the Mix tab: crates show them as
  downloaded, and loading one onto a deck pins it (§3.3).

### 4.6 Durable session restore

- `PlaybackSessionStore.Snapshot.npMixMode: NPMixModeState?`: optional, no schema bump (the
  `stemLock` precedent). Written by `persistSession` on toggle.
- Lifetime (Q4): recommended **session-scoped like the Stem Lock** (a fresh `play(...)` clears it),
  plus a Settings default `npMixModeDefaultOn: Bool?` (nil ⇒ false) that new sessions inherit, so a
  listener who always wants it can leave it on.
- Restore is HELD, as today: no buffering until the first ▶ (`resumeFromHold` → `replanPrefetch`).
  The sweep protects the held session's window meanwhile (§3.5).
- Cross-device: the synced snapshot carries the flag; the other device's buffer starts on its own
  first ▶ there.

---

## 5. Phased implementation plan

Each phase is shippable on its own, merged behind green unit tests, and verified per the standing
rules (verify at the committed tip, the XcodeGen test-count trap: check the COUNT moved).

### Phase 0: spike (1 day, nothing ships)
- Measure the AM rendition vs. rip lead-in offset on ~20 ripped songs (owner device: AM
  `playbackTime` at first audio vs. the rip's first non-silent frame + the capture log), giving
  `amHandoffLeadMs` and its spread. If the spread is > 300 ms, §4.3's hand-off is dropped and
  AM rows switch only at the boundary.
- Confirm `NowPlayingDSP` can host the Mix deck's growing-file scheduling without topology changes
  (read-through of `MixEngine.loadStreaming` / `pumpStream`).

### Phase 1: temporary holds + sweep (no new playback behaviour)
- `BurnStore`: `TemporaryHold`, `Document.temporaryHolds`, `pin(songIds:reason:)`, origin params on
  `adoptStreamedFile` / `adoptStreamedStems` / `burnStemPart`, `removeStemParts`, `isTemporary`,
  `temporaryExpiry`.
- `MixStreamLoader.open(…, origin:)` with explicit-wins joining.
- Pin hooks at every explicit call site in §3.3.
- `StorageManager.sweepTemporary`, triggers, protected-set extension, temp-first soft-cap order.
- Settings: `npMixBufferTTLHours`, `npMixBufferCapGB`; Storage view section; buffered badge.
- Producer in this phase: the Stem Lock prefetch becomes `.buffer` (if Q5 = yes). That way phase 1
  is useful and testable on its own.
- Tests (`TemporaryHoldTests`, `StorageSweepTests`): a hold is only created for assets that did not
  exist; a pinned burn never gains a hold; each explicit path pins (table-driven over the call sites);
  an explicit join upgrades a buffer stream; the sweep deletes only listed parts; protected expired
  holds survive; a shared analog side survives while referenced; an unreachable user folder keeps
  its row; the cap evicts soonest-expiring first; a v-old ledger decodes; a 2 000-hold sweep doesn't
  block main (chunking).

### Phase 2: Mix Mode toggle + buffering complete files
- `NPMixModeState`, `SetlistPlayer.mixMode`, `setMixMode(_:)`, `mixModeIndicator`, snapshot field,
  `npMixModeDefaultOn`.
- `NowPlayingPrefetcher` rename + `plan(_ input:)` (steps 1–6, no `.rip` yet), network policy,
  disk guard, `npMixBufferAhead`, `npMixCellular`.
- `handOffCurrentToLocal()` (presigned AVPlayer → local file at position; the Stem Lock path engages
  the DSP), media-services-reset hand-back, `pinnedIds` extension, Mix-tab suspension.
- UI: always-visible panel header with the switch + chip, buffer strip, ⋯-menu / mini-player
  context item, macOS ⌥⌘M.
- Tests: planner pure tests (Mix Mode off == today's Stem Lock plan, byte-for-byte; network classes ×
  sources; window and cap); `SetlistPlayer` tests with fakes (the `StemLockTests` pattern): toggle on
  mid-song, hand-off on land at the right position (startMs-aware), toggle off keeps the engaged
  track, new session clears, restore is held and resumes buffering on ▶, Mix session suspends and
  resumes, the end-of-track generation is untouched by a hand-off; XCUITest with `PDJ_HOLD_PLAYBACK`
  for the switch + chip.
- Device verify: Wi-Fi + cellular drive, `DeadAirMeter` on hand-offs, one lock-screen card.

### Phase 3: the DSP plays the growing file
- Extract the Mix deck's growing-file scheduling (segment-to-frontier appends, `streamHolding`,
  pump on byte growth, truncation on a dead stream) into a shared helper next to `StemSync`
  (`GrowingFileSchedule`), used by both `MixEngine` and `NowPlayingDSP`. Shared, not copied, like
  `StemSync`.
- With Mix Mode on, a ripped row that isn't local STARTS in the DSP on its `MixStreamLoader`
  stream (no presigned AVPlayer download of the same bytes). Underrun ⇒ hold + "Buffering…",
  with the existing stall rules (resolve-stall hop / start watchdog) as the backstop.
- `currentTrackMixable` accepts an open buffer-lane stream; `.buffering` mostly disappears.
- Update `mix-audio-graph.md` ("the full song is always a COMPLETE local file here" stops being true).
- Tests: `NowPlayingDSP` growing-file tests via `MixStreamLoader.injectStreamForTesting` +
  `captureForTesting` (sample-resolution dead air: > 2 ms of silence fails), underrun hold/resume,
  stems handover onto a partial main (`mainTruncated` semantics), seek past the frontier.

### Phase 4: Apple Music rows
- `.rip` steps (owner only, first 2 AM-only rows, through `playbackRipGate`; same-host deferral
  respected), `.ripping` indicator.
- `PlaybackCoordinator.providers(for:preferLocalAudio:)`: rip-first when the local copy is complete
  or the presign is cached.
- `handOffFromAppleMusic()` swap-on-touch (calibrated by phase 0), locked-phone pre-arm.
- `stemify` requests for ripped window rows without stems.
- Tests: provider order with/without Mix Mode (an un-ripped or un-cached row stays AM-first, so no
  dead-air regression); the rip window cancels out-of-window Mix Mode rips; non-owner never sends
  `.rip`; hand-off position math with injected AM time; the AM provider's end monitor is released
  (no stray end advances after the hand-off, cf. `releaseMusicKit`).
- Device verify: AM → local seam by ear, locked phone, CarPlay.

### Phase 5: polish and parity
- Up Next buffer dots; CarPlay "Buffering…" row detail; "Open in Mix" (hand off to Auto-DJ as an
  explicit mix, pins the rows); optional DSP-native boundary (`preloadNext`) if the dead-air meter
  shows a gap; optional opt-in "Mixable songs first" (Q8); optional EQ3 strip on `NowPlayingDSP`
  (the one GRAPH change in this plan, see `mix-audio-graph.md` → "Planned").

---

## 6. Test strategy (summary)

- **Pure planners first** (`NowPlayingPrefetcher.plan`, sweep planning, hold creation rules): table
  tests, no I/O. Mix Mode off must equal today's Stem Lock plan.
- **Hermetic stores:** `BurnStore.appBurnsDirOverride`, `SessionFolders.appRootOverride`, an injected
  clock for TTLs, `MixStreamLoader.injectStreamForTesting` / `failStreamForTesting`.
- **Sequencer:** fakes for coordinator / player / DSP as in `StemLockTests` and the F4 regression
  suite; every async test waits on the asserted condition, no fixed sleeps.
- **Audio:** `NowPlayingDSP.captureForTesting` at sample resolution for hand-offs and growing-file
  appends.
- **UI:** XCUITest for the switch, chip and Storage section under fixtures; macOS UI never in parallel
  with iOS-simulator UI tests.
- **On device (not headless-testable):** session activation on a locked phone, lock-screen / CarPlay
  card continuity, AM → local seam, cellular policy, real buffer latencies. `[npmix]` + `DeadAirMeter`
  lines in the S3 diag logs are the evidence.

## 7. Risks

| Risk | Mitigation |
|---|---|
| **App Review 5.2.3**: "Apple Music playback → POST /rip" becomes a user-visible feature (`PlaybackCoordinator` already carries #TOUPDATE notes on this) | Rips stay owner-only and window-limited; the UI never says "rip Apple Music" to a public user (non-owners only see "Apple Music only"); phase 4 can ship behind an owner gate if review risk is judged high. Q7. |
| Dead air at hand-offs / boundaries | Engage on touch by default; same-bytes hand-offs only automatically; prefer-local only when instant; DeadAirMeter per phase; phase 3 tests at sample resolution. |
| Storage growth (40 MB per song with stems) | 2 GB temp cap, soonest-expiry eviction, disk guard, Storage view controls. |
| Cellular data | Next-song-only default, no speculative stems on cellular, Low Data ⇒ current only. |
| Sweep deleting something in use | Protected set includes window, decks, live streams, held-session window; the per-chunk re-read; deletion limited to listed parts; never on an unreachable folder. |
| Main-thread stalls (the 10-23 crash loop) | One-scan planning, stamp first, chunked async, single-flight. |
| Battery (AVAudioEngine + TimePitch always on) | Engage on touch; the DSP idles its engine on disengage (existing). |
| Rip server load (real-time captures) | ≤ 2 outstanding Mix Mode rips; the playback rip window cancels the rest; the existing cascade breaker. |
| Same-Mac capture interrupting AM (10-14 cascade) | Existing same-host deferral; no new rip path. |
| AM position imprecision | Phase 0 calibration; swap-on-touch only; drop the hand-off if the spread is too wide. |

## 8. Open questions for Levi (each with the recommended default)

1. **AM current track mid-song:** switch to the local copy automatically, only on the first control
   touch, or only at the next song? **Default: on the first control touch** (a short seam you chose);
   otherwise the song finishes on Apple Music.
2. **When the DSP takes over a local track:** at every track start, or on the first touch (as F4 does)?
   **Default: on touch** (the Stem Lock still engages at start). Less battery, no change to playback
   you don't touch.
3. **Expiry clock:** fixed 48 h from download, or does replaying in Mix Mode restart it? **Default:
   fixed from download**, but never deleted while it is playing or queued in the window.
4. **Mix Mode lifetime:** per session like the Stem Lock, or sticky? **Default: per session, plus a
   Settings "Start new sessions in Mix Mode" (off).**
5. **Stem Lock's prefetches** (permanent today): should they become temporary too? **Default: yes**
   (they are speculative; any explicit Download / Mix pins them).
6. **Buffer cap:** **default 2 GB** for temporary assets, soonest-expiring evicted first. Window
   **3 songs on Wi-Fi with stems; next song only on cellular; current only on Low Data.**
7. **Apple-Music-only rows:** rip the next 2 for Mix Mode (owner only), and keep public users at
   "Apple Music only"? **Default: yes to both.** Phase 4 can stay owner-gated if review risk is a concern.
8. **"Mixable songs first":** let Mix Mode reorder the queue so local rows play before rows still
   ripping? **Default: off** (never reorder without asking); offer it as an opt-in in phase 5.
9. **Control carry:** should tempo / pitch / FX carry across tracks the way Stem Lock carries stems?
   **Default: no** (per-track reset, as F4). A later "Mix Lock" if you want it.
10. **tvOS:** **Default: not in v1** (no TV mix panel exists, 5 GB TV cap).
11. **"Keep" as a TTL option** (buffer becomes a normal download): **Default: offer it** in the picker.
