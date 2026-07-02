# PocketDJ — Architecture Book

This is the **inside-out, systems-engineering** view of PocketDJ — the complement to
[`STORYBOOK.md`](./STORYBOOK.md), which tells the **outside-in, customer/product**
story screen-by-screen. Where the storybook asks *"what does the DJ see and do?"*,
this book asks *"what are the moving parts, who owns what, and how does a byte get from
a vinyl rip on the iMac to a planet orbiting an album on a phone?"*

This top-level document is the **map**: it frames the product goal, shows how the
architectural pillars fit together to achieve it, and links to a **chapter document
per pillar** that holds the full context (entities, data flows, schemas, diagrams,
worked examples). Read this page, then dive into whichever chapter you need.

---

## The goal — what the whole system is for

> **PocketDJ — Portable, Personal, Musical Performance Playlists Producer:** let
> anyone, anywhere, **instantly create, play, and mix playlists from diverse musical
> sources.**

Unpack that and you get the design pressures the architecture answers:

- **Portable / anywhere** → offline-first, no server the user runs; everything the
  client touches is a static, public, cacheable artifact. → **Ch. 7**
- **Personal** → *your* crate — digitized vinyl, your Apple Music library — enriched
  and owned on-device, editable in place. → **Ch. 2, 3, 7**
- **Diverse musical sources** → multiple ingest pipelines normalize into **one
  catalog shape** with stable, collision-free ids — and, on the native app,
  a **streaming-account source** (Apple Music) and a **ShazamKit**
  recognizer beside the file catalogs. → **Ch. 2, 3, 7**
- **Performance Playlists Producer** → compose the shape of a night (pockets →
  playlists → setlists) and **realize** it into a concrete, ordered set. → **Ch. 4**
- **Play & mix** → make the metadata catalog actually audible from a phone
  (rip-on-demand, live streaming) and find the right record fast (search). → **Ch. 5, 6**

And the one sentence that captures the whole shape:

> **One iMac is the entire backend toolchain (ingest, enrichment, rip server,
> deployer); AWS S3 + CloudFront is a dumb, public-read content host; every client —
> the web PWA and the native SwiftUI apps — is a thin, offline-first consumer of the
> same static documents and the same rip API. There is no application server. The
> "API" is mostly files.**

---

## How the pillars fit together

```
   "diverse sources"        "one catalog"        "produce a performance"
  ┌──────────────────┐   ┌────────────────┐   ┌────────────────────────┐
  │ Ch.2 INGEST &    │──▶│ Ch.3 CATALOG & │──▶│ Ch.4 PERFORMANCE       │
  │ ENRICHMENT       │   │ DATA MODEL     │   │ ENGINE  (Mix · +AI ↗)  │
  │ vinyl·AppleMusic │   │ index JSON ·   │   │ pockets→playlists→     │
  │ ·audio·grid·stems│   │ model·collections   │ setlists·realize·Mix   │
  └──────────────────┘   └───────┬────────┘   └───────────┬────────────┘
                                 │                         │ setlist (Song IDs)
        ┌────────────────────────┼─────────────────────────┘
        ▼                        ▼                          ▼
  ┌────────────────┐   ┌──────────────────┐      ┌────────────────────────┐
  │ Ch.6 SEARCH &  │   │ Ch.5 PLAYBACK &  │      │ Ch.7 DISTRIBUTION &    │
  │ DISCOVERY      │   │ RIP-ON-DEMAND    │      │ CLIENTS                │
  │ aoss · starmap │   │ rip·burns·stems  │      │ S3/CloudFront·PWA+     │
  │ online/offline │   │ ·live HLS·offline│      │ native·TestFlight·edits│
  └────────────────┘   └──────────────────┘      └────────────────────────┘

         everything stands on ── Ch.1 FOUNDATIONS (entities · files-as-API · ids)
```

**Reading the map.** Across the top is the **production-to-performance spine**:
**Ch. 2** ingests diverse sources (vinyl, Apple Music, audio analysis, beat grids,
stems, art) into the **one catalog shape** of **Ch. 3**, which the **Ch. 4**
performance engine turns into realized setlists **and mixes live on a two-deck DJ
board** (the Mix engine, §7) — and is where **AI auto-*building*** lands next (the ↗
seam). The bottom row is how that catalog and those setlists reach the user:
**Ch. 6** makes it findable (search + the spatial star map), **Ch. 5** makes it
audible anywhere (rip-on-demand into a public S3 cache, live HLS, and **offline burns +
stems**), and **Ch. 7** distributes the artifacts to thin clients (the PWA + the native
TestFlight app) and closes the **edits round-trip** back to the catalog. Everything rests on **Ch. 1 Foundations** — the entities, the
"files-as-API" principle, and the content-derived ids that make the whole
server-less coordination work.

---

## Table of contents

| # | Chapter | Pillar of the goal | What's inside |
|---|---|---|---|
| 1 | [**Foundations**](./architecture/01-foundations.md) | the whole | System entities, ownership table, the files-as-API spine, content-derived ids. **Start here.** |
| 2 | [**Ingest & Enrichment**](./architecture/02-ingest-and-enrichment.md) | *diverse sources* | Filesystem (vinyl `*Raw`), `Library.xml`, AppleScript/Shortcuts capture, the 5-stage analog indexer, Apple Music indexer, audio analysis + art mirroring. |
| 3 | [**Catalog & Data Model**](./architecture/03-catalog-and-data-model.md) | *personal catalog* | Index JSON schema (incl. the `appleMusicId` **catalog-id stage** and the **cloud re-index** that folds Apple Music length/bpm/key in with cloud precedence via **tight `am-match`**), internal model, collections — incl. the **`CollectionsDocument` schema versioning (v2→v3) + flat playlist `folders`** — the one shape everything speaks. Reference chapter. |
| 4 | [**Performance Engine**](./architecture/04-performance-engine.md) | *Playlists Producer* | Pockets → playlists → setlists, the `realize()` engine, iTunes mirroring, **the Play/Shuffle reusable "Now Playing" setlist (`playNow`)**, **the two-deck Mix engine (first-party `AVAudioEngine` — tempo/pitch/seek/crossfader/4 effects, grid-aware beat-match, Auto-Mix, and offline STEM DECKS, §7)**, **and the AI auto-*building* seam — whose first consumer now ships: the Siri "Create Pocket" on-device-LLM builder (§4.1)**. |
| 5 | [**Playback & Rip-on-Demand**](./architecture/05-playback-and-rip-on-demand.md) | *play & mix* | The rip server API (incl. batch `POST /rip-collection`, the `POST /rip-cancel` **stop + worker-kill**, the `rippedAt` manifest stamp, **the analog per-song CUT export + `POST /backfill-cuts` / `POST /retag-cuts`**), job state machine, live HLS, the public rips cache, mini-player + setlist playback, the native inline player (`PlayerEngine`/`PlayerClock`/TimelineView, **now with a length-aware position end-boundary + held playback security-scope**), the stream-first → rip-last provider chain (`PlaybackCoordinator`) **with stream-through-rip**, the offline Collection Rip/Burn store (`BurnStore`, **+ user-browsable burnt-music folder + the metadata burn-filename scheme + the per-song analog-cut burn + the `@Observable` background-burn progress mirror**), the **length-aware + manual-jump-adopting** `SetlistPlayer` burnt-or-stream sequencer with **persistent ⏮/⏭ transport**, **the home NOW PLAYING deck (§10.1 — spinning beat-grid-rate gold record, live Up-Next queue edits by row identity, debounced add-search, iOS home/restore + macOS-Mix launch defaults)**, **the global device/cloud `PlaybackMode` + shared `playLocalFile` (now burned-first + scope-held on EVERY song-start path) + the explicit offline catalog disk cache (`CatalogService` `catalog-cache/`)**, **the queue self-heal (per-job watchdog + transient backoff retry), the analog source config (`POCKETDJ_ANALOG_BASE`), the persistent collection-RIP Stop/progress poll, native BACKGROUND PROCESSING (`TransferCoordinator` background `URLSession` + `pocketdj-transfers.json` + BGTasks + background audio), the cloud-analog → `public/current-index.json` IN-PROCESS fold (`cloud-reindex-fold.mjs`), **the measured BEAT-GRID pass (`/backfill-beatgrids` → `beatGridBpm`/`firstDownbeatMs`/`steady`)**, and **STEMS end-to-end (server Demucs `/stemify` → public `rips/stems/`; the collection-burn STEM pull; the offline `StemPlayer` audition).** |
| 6 | [**Search & Discovery**](./architecture/06-search-and-discovery.md) | *instantly find* | OpenSearch Serverless (aoss), the SigV4 + CloudFront-proxy trick, online/offline modes, **online pagination (`from/size` + `track_total_hits`) + server-side sort + the `genreCategory` field**, **the native Browse genre + collection-membership filters**, **on-device Browse paging + the results memo (pre-built rows, `resultsKey`-keyed sort cache, growing-prefix render — instant tab/kind switching at ~100k songs)**, the star map. |
| 7 | [**Distribution, Clients & Edits**](./architecture/07-distribution-and-clients.md) | *portable, anywhere* | S3/CloudFront (public-read), the PWA + native clients, **the native app as a single universal SwiftUI target (iPhone/iPad/Mac, iOS 18/macOS 15) built with XcodeGen and shipped to TestFlight (`apple-publish`/`testflight.sh`)**, the deploy loop, the edits round-trip, the native app's streaming-account providers + ShazamKit recognizer (bundle `com.levi.pocketdj`), **the `backfill-rip` skill for the catalog-id-crawl misses (`apple-music-catalog-misses.csv`), and the App Intents layer (§7) — Siri/Shortcuts/Spotlight: play/shuffle playlist + pocket, auto-mix with lock-screen-seam pause/resume, Spotlight entity indexing + intent donations, and the Siri "Create Pocket" builder.** |

---

## What's current vs. what's coming

The architecture is built so the next pillars slot in **without breaking the data
contract**. Honest status:

- **Built today:** all of ingest/enrichment, the catalog, the manual performance
  engine (`realize()` with seeded sampling + harmonic autofill), rip-on-demand with
  live HLS (now including the **native inline player** — `PlayerEngine`/`PlayerClock`/
  TimelineView — on browser *and* album rows, Ch. 5 §7), online search, multi-client
  distribution, and the native edits overlay (export/import).
- **New current-state — native streaming source + ShazamKit recognition.** The
  native app adds an **Apple Music streaming-account source** beside the URL catalogs,
  plus the **"?♪?" ShazamKit recognizer** that maps the song in the room back to the
  crate (Ch. 7 §5). Both are **additive and ship inert** behind `#if canImport` +
  feature flags. **Apple Music** is wired on (`PocketDJAppleMusicEnabled = YES`; system
  MusicKit consent, in-process playback — needs the App-ID MusicKit App Service — no
  entitlement — to run on device) and **ShazamKit** uses the public catalog (no
  entitlement, no App Service; just the framework + mic string), per
  [`docs/streaming-integration.md`](./streaming-integration.md). (Earlier Spotify +
  YouTube provider scaffolding was removed.) Bundle id is now
  **`com.levi.pocketdj`**. **Apple Music (Local) songs now actually *stream*** rather
  than always ripping: an out-of-band catalog-id resolver mints an `appleMusicId` onto
  each song (Ch. 3 §1.1), and the native `PlaybackCoordinator` tries that verified
  Apple Music stream **first**, degrading to rip-on-demand only on a miss (Ch. 5 §8).
  **That crawl has now completed — 76,134 / 92,865 songs resolved → stream; the 16,730
  misses fall back to ripping and are listed in `apple-music-catalog-misses.csv`, which the
  `backfill-rip` skill local-rips through `/rip-collection` (Ch. 7 §4).**
- **New current-state — stream-through-rip + offline Collection Rip/Burn.** When an
  Apple Music stream wins a play, the native app fires **one fire-and-forget rip** so the
  track is silently captured to the public S3 cache for later (zero playback latency,
  idempotent, never blocks; Ch. 5 §8). Playlist / pocket / setlist / source detail views
  gain **Rip collection** (batch `POST /rip-collection` → the durable queue → S3) and
  **Burn collection** (a new `@Observable` `BurnStore` serial download queue that pulls
  *already-ripped* songs to an on-device offline store + a mixer-readable `.txt` sidecar;
  Ch. 5 §9). Each manifest entry now stamps **`rippedAt`** so a burn re-downloads when the
  source rip is newer. The offline player + live-mixer that consume the burn store are
  still **deferred** — only the storage layout + seams ship.
- **New current-state — cloud rips, Stop, Setlist Play, burnt-music folder, richer
  Browse + paged search.** A handful of features round out playback/discovery: a
  **"Rip from cloud source"** setting captures an *analog* song from the iMac's Apple Music
  library when it **exactly** matches (tight `am-match`, Ch. 3 §1.3), else falls back to the
  vinyl rip — and a durable **cloud re-index** folds Apple Music length + cloud bpm/key/camelot
  into `current-index.json` with cloud precedence (Ch. 3 §1.2). A **`POST /rip-cancel`**
  endpoint backs a collection **Stop** that cancels an in-flight rip (dequeue + kill the
  capture worker) or burn (keeps finished files; Ch. 5 §2.1, §9). Burns can save to a
  **user-browsable folder** (security-scoped bookmark; Ch. 5 §9). A **Setlist Play** button
  runs a set in order via the **`SetlistPlayer`** sequencer (burnt-local-file else stream,
  auto-advance; Ch. 5 §10). Online search **pages** (`from/size` + `track_total_hits`,
  accumulating, real total) and applies the Browser **sort server-side** (Ch. 6 §4.1), and
  the native **Browse** gains **genre** (tier-1-category, multi-select any-of / none-of) +
  **collection-membership** filters and a **per-clause remove** (Ch. 6 §6).
- **New current-state — rip-server self-heal + analog source config + persistent
  collection-RIP Stop.** The rip server's concurrency-1 queue gains a **self-heal** layer
  (Ch. 5 §3.1): a **duration-aware per-job watchdog** (digital = `length×1.5+90s` clamped
  90s–30min; analog ffmpeg = fixed 12min) group-kills a hung capture so one stuck job can't
  freeze the queue, and a **capped exponential-backoff retry** (`[30s,2m,8m,8m]`,
  maxAttempts 5, `attempt` persisted in the durable queue record) re-runs **transient**
  failures (missing analog drive/file, aws/network, watchdog timeout) while leaving
  **permanent** ones (unknown song / no analog ref) + cancels alone — so a remounted drive
  self-heals. The analog path now reads `${POCKETDJ_ANALOG_BASE}/<originalFilename>`, set to
  **`/Volumes/RipBurnMix`** in the launchd plist (needs removable-volume TCC for `node`;
  Ch. 5 §3.2, Ch. 7 §6). The native collection **Stop** + a live **"X of N ripped"**
  progress now stay visible for a whole server-side RIP via a **manifest poll**
  (`CollectionRipBurnController`, Ch. 5 §9.1) instead of vanishing after the ~1-2s enqueue.
- **New current-state — native BACKGROUND PROCESSING (rip-in · burning · downloading ·
  setlist playback continue while suspended/locked).** A new
  **`TransferCoordinator`** owns one background `URLSession`
  (`com.levi.pocketdj.transfers`); Burn/download run as **download tasks** that survive
  suspension + resume + finish after a **cold background relaunch**, with per-item state
  persisted atomically to **`pocketdj-transfers.json`** (the sidecar text + security-scoped
  burn-folder bookmark are captured at enqueue so the **`@MainActor`-free** delegate
  finalizes files with zero main-actor access). A new **`AppDelegate`**
  (`@UIApplicationDelegateAdaptor` iOS / `@NSApplicationDelegateAdaptor` macOS) bridges the
  background-URLSession completion handler + registers/submits a **`BGProcessingTask`**
  (burn-drain) and **`BGAppRefreshTask`** (rip-reconcile); **background audio** completes via
  `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` next/previous driving `SetlistPlayer`
  (auto-advance while locked). Capability flips: `UIBackgroundModes` += `processing,fetch`,
  `BGTaskSchedulerPermittedIdentifiers` added (Ch. 5 §11, Ch. 7 §5.3).
- **New current-state — offline-first catalog cache + burned playback, analog CUT
  export, length-aware Setlist Play transport.** Three clusters harden offline play and
  the burn export:
  - **Offline-first (no network at the venue).** `CatalogService` now persists the raw
    index bytes per source URL to an explicit disk cache (`Application Support/catalog-cache/`,
    SHA-256-of-URL filename) on every good decode and **falls back to that cache** on any
    network failure — `URLCache` silently refused to keep the 1,300+-album index, so offline
    relaunch had nothing. `AppModel.fetchIndex` degrades gracefully (skip an un-cached source,
    fail only if **every** source fails). Every song-start path is **burned-first** — row ▶,
    ⌘P (`BrowseView`), Play-All (`SetlistPlayer`) — in **both** device and cloud mode, and a
    user-folder burn's **security scope is now held through playback** (`BurnStore.localURLForPlayback`
    + `PlayerEngine` `scopeRelease`; `resolveBurnFolder` reads with `requireWritable=false`),
    fixing the 0:00/no-audio offline case. The rip `POST` timeout drops to **12 s** (fast-skip
    an asleep server) and the inline scrubber falls back to the catalog length for its end
    timestamp. (Ch. 5 §9, §12; Ch. 7 §1)
  - **Analog CUT export (burn-only).** The rip server now slices each analog song out of the
    album mp3 (`ffmpeg -ss startMs -t duration`; duration derived from `pointer.endMs-startMs`
    when the catalog length is null) and uploads `rips/<songId>.cut.mp3` — the **public** `rips/`
    prefix — ID3v2.3-tagged with title/artist/album; the manifest gains `cutKey`/`cutBytes`/
    `cutRippedAt`. A **Burn** downloads the per-song cut (paired with the per-song sidecar)
    **alongside** the whole-album backcase, named digital-style, auto-repulling when the S3
    `Last-Modified` is newer (delete-then-place). **Playback is unchanged** — album + `startMs`
    seek; the cut is burn-only. New endpoints **`POST /backfill-cuts`** (retro-slice analog
    entries missing a cut, straight from the raw source — no whole-album re-transcode) and
    **`POST /retag-cuts`** (tag-only `-c copy` remux of every existing cut). (Ch. 5 §2, §5, §9;
    Ch. 3 §1)
  - **Length-aware + manual-jump Setlist Play transport.** `PlayerEngine` arms a **position
    end-boundary** (`startMs+length`) so a track inside a **shared** album-rip mp3 advances at
    its **own** length — a one-shot latch is shared with the natural end so the set can't
    double-advance, and the boundary only arms when the analog `startMs` is non-nil (per-song
    files keep their natural end). `SetlistPlayer` observes `RipsStore.nowPlaying`, so a manual
    in-set row ▶ **repositions** the running set (nearest-forward occurrence for a duplicate
    song) instead of stranding it; ⏮/⏭ are now a **persistent** transport. The
    "Burning N of M" overlay, previously bound to the non-`@Observable` `TransferCoordinator`,
    is now **mirrored into `BurnStore.backgroundProgress`** (`@Observable`) via an `onProgress`
    hook so it re-renders per finished download. The iOS play-mode toolbar centers ⏮/⏯/⏭ via
    `.principal`, gives **Stop** the play button's trailing slot, and collapses Edit/Rip/Burn/
    Rename/Delete into a `•••` menu; macOS keeps the flat toolbar. (Ch. 5 §7, §10)
- **New current-state — playlist/pocket Play+Shuffle, playlist folders, device/cloud
  mode, metadata burns, cloud-analog index fold.** A playlist (and pocket) **▶ Play** now
  plays its songs **in order** and a new **🔀 Shuffle** plays a random order — both backing a
  **single reused "Now Playing" setlist** built **directly** from the songs (literal order,
  drops unresolvable ids, **not** via `realize()`'s autofill/sample/dedup; reserved
  `set_now_playing`/`pls_now_playing`, monotonic `nowPlayingRevision`, cleared on launch,
  hidden from history) that you land in (a `SetlistLaunch` nav value autostarts) to
  reorder/see-next; the **old realize-take Play** moved to a `list.bullet.clipboard` toolbar
  button (Ch. 4 §6). Your playlists render **above** "From your sources" and organize into
  flat, collapsible **playlist FOLDERS** (`PlaylistFolder` + `Playlist.folderId`, schema
  **v2→v3** back-compat, carried through import/merge + the backup zip's `folders.json`;
  Ch. 3 §3.1). A global **device/cloud `PlaybackMode`** + a browser-style toolbar toggle
  picks the source for every Play: **device** plays burned files (Play-All **skips** un-burned
  + a "nothing on device" banner; a single-row tap **falls back to cloud**), **cloud** streams
  (provider → rip); a shared **`playLocalFile`** keeps now-playing consistent and flipping mode
  lets the current track finish (Ch. 5 §12, §10). Burn filenames now carry a sanitized,
  length-capped **`Artist-Song-Album-Year-Genre-Camelot-Key-BPM`** prefix (per-song digital,
  album-level for the shared analog file; Ch. 5 §9). And the cloud-analog **gap closes**: a
  cloud rip of an analog song now folds its bpm/key/camelot/length into
  `public/current-index.json` **in-process** within the analysis flow (extracted
  `scripts/lib/cloud-reindex-fold.mjs`; atomic, exact-match-only, idempotent, cloud
  precedence, provenance-stamped, **never auto-deploys**, guards uncommitted working-tree
  changes; Ch. 5 §13).
- **New current-state — the two-deck MIX DSP engine + STEMS end-to-end + measured BEAT
  GRIDS (native).** The native app's **Mix tab** ships a **first-party, cross-platform
  two-deck DJ engine** (`apple/PocketDJ/Mix/MixEngine.swift`) — one `AVAudioEngine` graph per
  deck (`AVAudioPlayerNode → inputMixer → timePitch → compressor → filter(EQ) → reverb →
  flanger → mainMixer`) with **TEMPO** (0.5–2.0× pitch-preserved), **PITCH** (±12 semitones
  tempo-preserved), sample-accurate **SEEK**, an equal-power **CROSSFADER**, **4 effects**
  with continuous strength, grid-aware **BEAT-MATCHING** (follower Sync to a lead deck,
  octave-folded tempo + best-effort downbeat phase-align, **preferring the measured grid
  BPM**), a timed **AUTO-MIX** auto-DJ (with optional **FX GLIDE** — a coherent effect sweep
  held across a run of transitions — and **MIX GLIDE** — a **data-gated**
  bend that beat-matches tempo only when both BPMs are known and bends pitch only when both Camelot
  keys are known, else a plain volume crossfade; configurable length, Ch. 4 §7.11; plus **PAUSE/RESUME**
  — hand off to manual mixing mid-set and take it back with a musically-timed handoff, and an
  **Auto-mode deck-source lock**, Ch. 4 §7.5), a **mix-native lock-screen card** (album **artwork**,
  a sticky now-playing deck, remote ⏸/▶ = suspend/resume the Auto-DJ — its wall clock frozen across
  the pause so a silent in-flight fade can't self-resume — and ⏭/⏮ = the fast/slow queue skips;
  collection playback keeps ⏮ prev · ⏭ next via the `NowPlayingArbiter`, Ch. 4 §7.9), **SESSION AUDIO
  RECORDING** (capture the clean stereo house mix to a per-session folder as **crash-safe fragmented
  AAC**, scrubbable + replayable from Sessions, Ch. 4 §7.12), a **wrapped move-by-move replay timeline**
  (compact `.glide` nodes, tap-a-load → song metadata, Ch. 4 §7.8), **universal CSV / PocketDJ export**
  of any collection or session tracklist (Ch. 4 §5), and offline **STEM
  DECKS** (4 stem nodes summed into the deck chain; per-stem mute/volume) — no licensed
  third-party audio SDK (Ch. 4 §7). It's
  fed by two new analysis side-channels folded into the rips manifest: a **measured beat grid**
  (rip-server `POST /backfill-beatgrids` → librosa downbeat grid → `beatGridBpm`/
  `firstDownbeatMs`/`steady`, Ch. 3 §4.3) and **Demucs STEMS** (rip-server `POST /stemify` /
  `/backfill-stems` → `htdemucs` v4 on Apple-Silicon **MPS** with a Docker-CPU fallback → 4
  stems vocals/drums/bass/other as 256k mp3 onto the **public** `rips/stems/<songId>/` prefix;
  per-song + collection). The offline **Burn** (Ch. 5 §9) now also **pulls every stemmed song's
  stems** so a burned collection **plays AND mixes** fully offline (re-burn picks up
  newly-available stems), and a **SongDetail stem-audition panel** (`StemPlayer`,
  burn-then-play-in-sync, solo/mute/play-all) lands beside the Mix decks (Ch. 5 §15). All stem
  surfaces are **offline-only** (burned local files, never streamed).
- **New current-state — the home NOW PLAYING deck (native).** Whenever collection
  playback (the app-scoped `SetlistPlayer`) runs in any mode except Mix, the iPhone
  home menu / the iPad+macOS sidebar grows a Now Playing element (Ch. 5 §10.1):
  track title + artist over a **gold record spinning inside a blue chassis** at a
  rate reflecting the track's **measured beat-grid BPM** (one rev per 4-beat bar ≈
  33 RPM vinyl; freezes in place on pause — paused `TimelineView`, zero redraws),
  ⏮ ⏯ ⏭, the **live Up-Next queue** (reorder clamped against races, removal by
  per-row identity so an auto-advance mid-tap never deletes the wrong song, appends
  picked up without restarting — new `SetlistPlayer` upcoming/move/remove/append
  seam), and a **debounced off-main add-search** over albums + songs (albums above
  songs, collapsible; exact-title first; ＋ appends live). Launch defaults changed:
  iOS opens on the home menu unless `settings.lastSection` restores the last spot
  ("" = home; fresh iPad → Mix, like the Mac); macOS always opens on **Mix**; the iOS home
  title drops the ✦. Testing seam `PDJ_HOLD_PLAYBACK` freezes the sequencer's
  running state (no audio) so UI tests can drive running-state surfaces on the
  fixture catalog.
- **New current-state — App Intents: Siri, Shortcuts & Spotlight (native).** The
  performance surface is now OS-invocable (`apple/PocketDJ/Intents/`, Ch. 7 §7):
  **8 App Shortcuts** with install-time Siri phrases — *Play/Shuffle 〈playlist〉 /
  〈pocket〉 in PocketDJ* (the `playNow` → `SetlistPlayer` path), *Auto-mix 〈pocket |
  set list〉* (MixResolver → `startAutoMix`, burned-files-only with a speakable
  error), *Pause/Resume the auto-mix* (the lock-screen `remotePause`/`remotePlay`
  seam — wall-clock-frozen suspend, resume-only-what-paused), and ***Create a
  pocket*** — the first shipped consumer of the AI auto-building seam: Apple's
  on-device Foundation model (iOS 26+, availability-gated; app still deploys to
  iOS 18/macOS 15) parses a brief → deterministic catalog search (exact year range +
  fuzzy genre + `NLEmbedding` mood-vector ranking) → LLM curation → 90-minute fit →
  a plain literal-member pocket (Ch. 4 §4.1). Intents run **in-app** via an
  `IntentServices` bridge registered with `AppDependencyManager` in
  `PocketDJApp.init()` (store cross-wiring moved there from `RootView.task` so
  scene-less background launches are wired). **Donations**: playlists/pockets are
  Spotlight-indexed as `IndexedEntity`s (debounced re-index on every collections
  save + `updateAppShortcutParameters()` re-teaching Siri renamed names; `OpenIntent`
  deep-links results into the app), and the UI's play/auto-mix actions donate their
  parameterized intents for system predictions.
- **Current-state — the NATIVE app is a first-class client.** The SwiftUI app
  (`apple/`) is a **single universal target** (one XcodeGen `project.yml` → iPhone + iPad +
  Mac via `supportedDestinations:[iOS,macOS]` × device-family `1,2`; iOS 18 / macOS 15; bundle
  `com.levi.pocketdj`), built with the `apple-build` skill and **shipped to TestFlight** via
  `apple-publish` / `apple/scripts/testflight.sh` (local archive → distribution-sign → App
  Store Connect upload; `ITSAppUsesNonExemptEncryption=false`; auto-distributes to the "Alphas"
  internal group). It is the **primary modern client** where the DJ/mix/stem features live,
  alongside the original offline-first PWA (Ch. 7 §2.1, §4.1).
- **Coming — AI-assisted auto-*building* playlists.** The *mixing* half is no longer
  hypothetical — a two-deck Mix engine with grid-aware beat-matching **and a timed
  Auto-Mix auto-DJ now ships** (Ch. 4 §7). What's still deferred is **AI-curated
  auto-*building*** of the set itself; the seams already exist (no migration needed to light
  them up): `SetlistTrack.mixSuggestions` + the `MixSuggestion` shape, the reserved
  `PocketKind:'performance'`, and the `realize()` sampling/autofill boundary an AI sequencer
  would extend. See
  [Ch. 4 §4](./architecture/04-performance-engine.md#4-the-ai-seam--auto-building-coming).
- **Deferred — the iMac edits-merge tool.** The native edits round-trip is built on
  the client side and the schema is designed for it, but the iMac-side merge tool that
  folds exported edits back into `current-index.json` **does not exist yet**. See
  [Ch. 7 §3](./architecture/07-distribution-and-clients.md#3-the-edits-database--the-round-trip).

---

## Appendix — inconsistencies & notes for maintainers

Things found while writing that don't fully line up, gathered here so they're not lost:

1. **The iMac edits-merge tool does not exist yet.** `EditSchema.swift` /
   `EditsStore.swift` cite "the iMac merge tool that folds edits back into the index,"
   but there is no such script in `scripts/` or the skills. Client half built; server
   half deferred. (Ch. 7 §3)
2. **Web vs native edits are different mechanisms.** Web mutates IndexedDB in place (no
   portable doc, no round-trip); only native keeps the versioned `EditsDocument`. The
   "edits database" is a native-only entity today. (Ch. 7 §3)
3. **aoss collection vs index name.** Collection is `pocketdj-search` (NextGen
   scale-to-zero, id `mii9dwge3uiee2tvivt5` — changes on rebuild; clients read the host
   from `public/search-config.json`); the index inside it is `pocketdj`. Client code and
   the CloudFront proxy path both use `pocketdj` (the index), which must match. (Ch. 6)
4. **`coverArtSources.url` extension drift.** `mirror-art.sh` / `index-json.ts` show
   `/art/<id>.jpg`; the Swift `Config.artURL` docstring shows `.webp`. The mirror
   writes `.jpg` (`image/jpeg`); the `.webp` comment appears stale. (Ch. 2, 7)
5. **Live streaming is HLS-only; the legacy `/stream/<id>.mp3` route was removed.** The
   client detects live via `url.includes('/hls/')` and the job's `streamUrl` is the
   `/hls/<id>/index.m3u8` playlist; iOS needs HLS, and the durable public mp3 covers
   every non-live play, so the old progressive-mp3 route is gone (a maintainer wiring a
   client to `/stream` would 404). (Ch. 5 §2)
6. **`TrackSource:'autofill'` in data = `↔ bridge` in the UI** — code name and product
   label differ (a grep for "bridge" in the data layer comes up empty). (Ch. 4, 5)
7. **`POST /analysis` overloads "key".** The body uses `musicalKey` for the musical key
   but `key` for the S3 object key when creating a fresh entry — same word, two
   meanings in one payload. Not a bug, but a footgun. (Ch. 5)
8. **Streaming is Apple Music + ShazamKit.** **Apple Music** (flag on) + **ShazamKit**
   (public catalog) are the wired-live streaming/recognition paths; the Settings row reads
   "Not available" until Apple Music is provisioned, so the UI is honest. (Earlier Spotify
   + YouTube provider scaffolding was removed.) (Ch. 7 §5)
9. **`PlayerClock` is intentionally NOT `@Observable`.** The inline player's ~4×/s
   position lives on a plain `PlayerClock` sampled by a `TimelineView`, *by design* —
   making it `@Observable` would re-invalidate the panel and drop clicks on its control
   buttons (the documented "dead slide-out buttons" bug). A maintainer "fixing" the
   missing `@Observable` would regress it. (Ch. 5 §7)
10. **Bundle id moved to `com.levi.pocketdj`** (was `net.pocketdj.app`). External
    references (the Developer-portal App ID) must match this exactly; the `net.pocketdj.*`
    name is fully retired in `project.yml`. (Ch. 7 §5)
11. **`appleMusicId` is a *candidate*, not a verified catalog id.** It's an iTunes
    Search `trackId` — *empirically* the same value MusicKit plays by, but the equality
    is an undocumented assumption (regions/versions can drift, tracks get removed). The
    client must verify it with a real `MusicCatalogResourceRequest` and degrade to
    ripping on a miss; a maintainer who "optimizes" by playing `appleMusicId` *without*
    the `fetchRow` verification would silently regress to wrong/failed tracks.
    (Ch. 3 §1.1, Ch. 5 §8)
12. **Three names for the cloud-rip flag, on purpose.** Client/persisted `ripFromCloud`,
    the request-body field `"ripFromCloud"` (sent only when true), and the server job's
    `preferCloud` (the **RESOLVED** post-probe boolean) are deliberately distinct. The
    server persists `preferCloud` (not the raw request flag) and **never re-probes on
    resume**, so a track later deleted from the library can't flip the `resourceKey`
    between persist and resume. (Ch. 3 §1.2, design-rip-from-cloud.md)
13. **Two cloud-fold paths with opposite write targets — by design.** The **offline CLI**
    `scripts/reindex-cloud-analysis.mjs` writes a **SIDE output**
    (`index-out/reindex/current-index.json` + a report) and **never** touches
    `public/current-index.json`; the **rip-server in-process fold** (Ch. 5 §13) *does* write
    `public/current-index.json` directly (atomic, fold-fields-only working-tree guard,
    `report.changed`-gated). Both share the same pure `scripts/lib/cloud-reindex-fold.mjs`,
    but **neither deploys** — the in-process one logs a publish hint and leaves CloudFront
    untouched. A maintainer expecting *either* to ship the catalog, or expecting the CLI to
    mutate the live file, would be surprised. (Ch. 3 §1.2, Ch. 5 §13)
14. **`am-match` deliberately trades coverage for fidelity.** Tight matching means analog
    songs that exist in Apple Music under a slightly different version label (a loose
    match) **silently rip from vinyl / keep the analog value** instead of cloud — by
    design (vinyl is always the correct personal cut), but it "misses" some cloud-eligible
    songs. (Ch. 3 §1.3)
15. **`/rip-cancel` refuses the kill mid-`uploading` and never Tier-2-falls-back.** A
    cancel landing while a job is uploading lets the idempotent `aws s3 cp` + `saveManifest`
    finish; a cancel mid-capture on an analog cloud rip does **not** fall back to vinyl
    (cancel means stop, not "try the other path"). A maintainer "simplifying" the cancel
    path could corrupt the manifest or resurrect a canceled rip as a vinyl rip. (Ch. 5 §2.1)
16. **Online pagination tops out at the 10k `from+size` window.** `hasMore` is false once
    the accumulator reaches the exact `total` *or* `SearchService.maxResultWindow` (10,000)
    — aoss's `index.max_result_window`. A query with >10k matches can't be paged to the end
    by offset; deep pagination would need `search_after`. (Ch. 6 §4.1)
17. **Online genre filter/sort depends on the `genreCategory` keyword existing in the
    index.** `FilterQuery`/`sortBody` map `genre → genreCategory`; if a stale index built
    before `scripts/es-index.mjs` added that field is live, online genre clauses silently
    match nothing. Re-run the `es-search-index` skill after upgrading. (Ch. 6 §2, §4.1, §6)
18. **The background download delegate MUST stay `@MainActor`-free.** `TransferCoordinator`'s
    `URLSessionDownloadDelegate` runs on a background queue and during cold relaunches when
    `BurnStore` may not exist — so it captures the sidecar text + the security-scoped
    burn-folder bookmark `Data` onto the `TransferRecord` at enqueue time and resolves the
    destination from *that*, never a `@MainActor` closure. A maintainer who "simplifies" by
    reading `SettingsStore`/the catalog inside the delegate reintroduces the
    `MainActor.assumeIsolated`-off-the-main-thread trap (the documented BLOCKER). (Ch. 5 §11.1)
19. **`isTransient` retries by default (allow-list of permanents).** The rip-server self-heal
    treats *everything except* `unknown songId` / `no analog file reference` / `canceled` as
    transient → retryable. A new genuinely-permanent failure mode would be retried 5× with
    backoff unless it's added to the permanent set — a footgun, not a bug. (Ch. 5 §3.1)
20. **The collection-RIP progress poll ends the *indicator*, not the rip.** Its
    `ripPollMaxTicks` (~2h) safety cap stops the poll to avoid a leaked Task; the server-side
    rip may still be running, and a manual Refresh reconciles. A maintainer treating the cap
    as "rip done/failed" would be wrong. (Ch. 5 §9.1)
21. **`UIBackgroundModes` + BGTask identifiers must agree across three places.** The two
    BGTask ids (`com.levi.pocketdj.burn-drain` / `.rip-reconcile`) are hard-coded in
    `TransferCoordinator`, declared in `BGTaskSchedulerPermittedIdentifiers`, and registered
    in `AppDelegate`; iOS refuses to register/submit an id missing from the plist. Changing
    one without the others silently disables a background task. (Ch. 5 §11.2, Ch. 7 §5.3)
22. **The "Now Playing" setlist is deliberately NOT `realize()`.** `CollectionsStore.playNow`
    builds the reserved `set_now_playing` setlist **directly** from the resolved song ids —
    literal order, unresolvable ids dropped, **no** autofill/pocket-sampling/dedup. A
    maintainer "unifying" Play through `realize()` would reintroduce reordering and bridge
    inserts the ▶/🔀 buttons exist to avoid (and would start appending history takes). It's
    also cleared on launch + filtered out of `setlists(forPlaylist:)` history on purpose.
    (Ch. 4 §6)
23. **Playback `PlaybackMode` is read through a lazy seam so a mid-set flip is deferred.**
    `SetlistPlayer.playbackMode` is a `() -> PlaybackMode` closure read **per track**, so
    toggling device⇄cloud mid-set applies to the **next** track (the current one finishes
    under its starting mode). In **device** mode Play-All **skips** un-burned tracks (no
    fallback to cloud — that's the single-row tap's behaviour, not Play-All's), and a wholly
    un-burned set raises the one-shot `deviceQueueUnplayable` banner instead of silently
    ending. A maintainer expecting Play-All to stream a missing track in device mode, or the
    flip to interrupt the current track, would be wrong. (Ch. 5 §10, §12)
24. **The analog burn file is named ALBUM-level, not per-song.** Because one analog rip is a
    whole-side mp3 shared by every song of the album, `BurnStore.fileNames` gives analog the
    `Artist-Album-Year-Genre` prefix (no per-song bpm/key) so all the album's songs map to the
    **same** audio name — the shared-file reuse / `isFresh` / dedup logic depends on that. The
    `idSuffix` (albumId/songId) + extension are **never** truncated; only the descriptive
    prefix is capped. A maintainer adding per-song tokens to the analog prefix would break the
    shared-file dedup. (Ch. 5 §9)
25. **The analog CUT is BURN-ONLY — playback never touches `cutKey`.** Playback of an analog
    song stays *album mp3 + `startMs` seek*; `cutKey`/`cutBytes`/`cutRippedAt` (manifest) and
    `cutFileName`/`cutDownloadedAt` (`BurnItem`) are consumed **only** by the burn's per-song
    export. The cut goes under the **public** `rips/` prefix with a `.cut.` infix
    (`rips/<songId>.cut.mp3`) to stay distinct from a per-song cloud rip's `rips/<songId>.mp3`.
    A maintainer routing playback through the cut (or filing it under a private prefix) would
    break offline play and the public read. (Ch. 5 §5, §9, Ch. 3 §1)
26. **The position end-boundary arms ONLY on a non-nil analog `startMs`.** `PlayerEngine`'s
    `endBoundarySec` (= `startMs+length`) exists so a track inside a **shared** album mp3
    advances at its own length; a **per-song** file (`startMs` nil) must rely on its natural
    end, because the catalog `length` can be missing/short and would cut it early. Both end
    paths funnel through one `signalTrackEnded` latch (reset per `load`/`setEndBoundary`) so the
    set can't double-advance. A maintainer arming the boundary for every track would truncate
    per-song burns. (Ch. 5 §7, §10)
27. **Burned playback MUST hold the security scope until the player is done.** `localURL`
    stops the scoped-folder access in its `defer` (fine for an existence check), so playback
    uses **`localURLForPlayback`**, which keeps the scope OPEN and hands `PlayerEngine` a
    `release` closure fired on the next `load`/`stop`. Releasing early leaves AVPlayer unable to
    read a user-folder burn → a silent 0:00/no audio. Relatedly, the playback `resolveBurnFolder`
    read path uses `requireWritable=false` (an offline iCloud-Drive folder resolves read-only).
    A maintainer reusing `localURL` for playback regresses the offline no-audio bug. (Ch. 5 §9, §12)
28. **The catalog disk cache is a deliberate replacement for `URLCache`, and is per-source.**
    `CatalogService` keeps an explicit `catalog-cache/<sha256-of-url>.json` because `URLCache`
    silently refuses to persist the (large) index past relaunch, leaving offline launch with
    nothing. `AppModel.fetchIndex` fails only when **every** enabled source has neither network
    nor cache — an un-cached source is skipped so an already-cached one still opens. A
    maintainer reverting to `.returnCacheDataElseLoad`-on-`URLCache` alone would silently break
    offline relaunch. (Ch. 5 §12, Ch. 7 §1)
29. **The "Burning N of M" overlay reads `BurnStore.backgroundProgress`, NOT the coordinator.**
    `TransferCoordinator` is a plain `NSObject` (it must be the background-`URLSession` delegate),
    so a view bound to its `progressSnapshot` never re-renders as downloads finish (the
    "burning number doesn't update" bug). The count is mirrored onto the `@Observable`
    `BurnStore.backgroundProgress` via an `onProgress` main-actor hook. A maintainer re-binding
    the overlay to the coordinator would freeze it at the enqueue total. (Ch. 5 §9)
30. **The Mix spec is "research"; the shipped `MixEngine.swift` is authoritative — and the
    node order differs.** `docs/design/mix-ondevice-tempo-pitch-beatmatch-spec.md` is dated
    "not yet built" and its graph diagram (`TimePitch → EQ → Reverb → Dynamics`, no inputMixer,
    no flanger) does **not** match the code. The live `connectChain()` order is
    `player → inputMixer → timePitch → comp(Dynamics) → filter(EQ) → reverb → flanger(Delay) →
    mainMixer`, and the engine adds Auto-Mix + stem decks the spec never covered. Trust the
    code. (Ch. 4 §7)
31. **`stemVersion` (singular) is the canonical "is stemmed" flag — there is no `stemKeys`
    / `stemRippedAt`.** The manifest stem group is `stems:{vocals,drums,bass,other}` (the 4 S3
    keys) + `stemModel`/`stemVersion`/`stemFormat`/`stemmedAt`/`stemBytes`; presence of
    `stemVersion` ⇒ stemmed (`RipsStore.isStemmed`). It's **distinct from `analysisVersion`**
    (the shared bpm/key/**beat-grid** stamp), so a Demucs model change never forces a beat-grid
    re-run and vice-versa. A maintainer collapsing the two version stamps would couple unrelated
    re-analysis sweeps. (Ch. 3 §4.3, Ch. 5 §15)
32. **Stems + beat grids are PER-SONG, even for analog.** A vinyl song stems/grids its per-song
    **cut** (`rips/<id>.cut.mp3`), never the shared album side — so a stem key is always
    `rips/stems/<songId>/…` and a grid is keyed by `songId`. A maintainer stemming the album mp3
    would mis-key every analog song to one blob. (Ch. 5 §14, §15)
33. **Every stem surface is OFFLINE-ONLY (burned local files), and burning FETCHES stems — it
    never separates them.** The Mix stem decks (`MixEngine`), the SongDetail audition
    (`StemPlayer`), and the collection-burn pull all require the 4 stems to be **burned locally**
    and require all four present; the "Stems" affordance only appears for a track the **server**
    has already stemmed (`rips.isStemmed` ⇒ `stemVersion != nil`). `MixResolver` likewise drops
    any song with no burned file, so a mix is offline-by-construction. A maintainer wiring stem
    playback to a stream, or triggering Demucs from the burn, breaks the model. (Ch. 4 §7.6,
    Ch. 5 §9, §15)
34. **`/health` advertises `stems:true` as a capability flag with NO `RIP_PROTOCOL` bump.**
    Stems and beat grids are **additive** manifest fields, so the protocol version stays `2` and
    an older client neither sees the "outdated — restart it" banner nor breaks; it just ignores
    the new fields. A maintainer bumping `RIP_PROTOCOL` for an additive field would needlessly
    flag every old client as outdated. (Ch. 5 §2, §15)
35. **The native app is ONE universal target, not three.** `apple/project.yml` declares a single
    `application` target with `supportedDestinations:[iOS,macOS]` × `TARGETED_DEVICE_FAMILY "1,2"`
    (iOS 18 / macOS 15); iPhone/iPad/Mac come from that one target + `#if os(...)` forks, and the
    `.xcodeproj` is **generated** by XcodeGen (a file added via the Xcode UI is dropped on the
    next `xcodegen generate`). A maintainer adding per-platform targets or hand-editing the
    project would fight the generator. (Ch. 7 §2.1)
36. **Two different "setlist CSV"s exist — don't conflate them.** The native app exports a
    **universal tracklist CSV** (`#, Title, Artist, Album, Year, Genre` — `TracklistCSV`, chosen via
    the PocketDJ/CSV format picker) that deliberately carries **no** BPM/key/**Song ID**. The
    `burn-setlist` **tooling skill** still requires a **richer** `#,Artist,Title,BPM,Key,Length,
    Source,Sequence,Song ID` CSV (it resolves rips by the **Song ID** column) — that Song-ID export
    is the **PWA/tooling** path, not the native app's. A maintainer feeding the native universal CSV
    to `burn-setlist` would get "Song ID column missing"; downstream audio resolution rides the
    **`.pocketdj.zip`** (catalog-by-id) instead. (Ch. 4 §5, Ch. 5)
