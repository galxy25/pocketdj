# PocketDJ — Architecture (Android)

> **LIVING DOCUMENT.** This is the plan-and-progress record for the Android port,
> updated as each phase is implemented. **Phase 1 is built** (branch
> `feat/android-phase1`, 2026-07-21): Browser (incl. Settings) + History +
> Jukebox Hero over the core catalog/playback layers, verified end-to-end on the
> `pocketdj` emulator against the live CloudFront catalog. Later-phase sections
> remain *Planned* with the same per-component honesty as the
> [Apple doc's Status ledger](./ARCHITECTURE-APPLE.md#status--whats-built-by-component).
>
> **Parity program (2026-10-27, branch `feat/android-parity`).** The four-phase plan
> below is superseded by a 22-wave, 116-package parity roadmap built from eight
> per-area gap audits. The cross-cutting design is in
> [`architecture/android-parity.md`](./architecture/android-parity.md); the machine
> source of truth is `android/specs/parity/roadmap.json` + `audits/*.json`. Baseline:
> 79 Kotlin files, 275 JVM tests, 267 audited features — 28 DONE · 39 PARTIAL ·
> 168 MISSING · 32 N/A. The [parity status ledger](#parity-status-ledger--by-package)
> at the bottom is updated by every package as it lands.

The **shared backend/system core** — sources, indexers, S3/CloudFront, the SQS/EC2
cloud workers, aoss search, the rip server, the jukebox broker — is documented in
[`ARCHITECTURE-APPLE.md`](./ARCHITECTURE-APPLE.md) and the shared chapter files
under [`architecture/`](./architecture/); it is **not duplicated here**. Android is
a **new thin client** over that unchanged core: it reads the same static catalog
documents and speaks the same rip-server + jukebox HTTP APIs. This doc records the
Android-side decisions, the deltas from the Apple client, and the build-out phases.
Sections mirror the Apple doc's chapter structure so a reader can hold the two
side-by-side.

---

## Locked decisions

These are settled — do not relitigate them in-implementation; a change here needs a
deliberate edit to this doc.

1. **Repo layout & package.** Code lives in a top-level **`android/`** directory
   (the Gradle root). Package/org name mirrors the Apple bundle id prefix
   (`com.levi`, from `apple/project.yml`): **`com.levi.pocketdj`**.
2. **Language & UI stack.** **Kotlin 2.x + Jetpack Compose (Material 3)**;
   **single-activity** architecture with **Navigation Compose**; **Gradle Kotlin
   DSL + a version catalog** (`libs.versions.toml`).
3. **SDK targets.** **compileSdk/targetSdk 36** (Android 16), **minSdk 35**
   (Android 15). Levi targets only the **last two Android versions**, and is
   willing to drop to **36-only** if a major platform capability makes a PocketDJ
   feature possible or markedly more reliable — candidates are tracked in the
   running [API-36-only candidates](#api-36-only-candidates) list below.
4. **Playback.** **Media3/ExoPlayer + MediaSession** (notification / lock-screen
   transport). **Android Auto comes later**, as the CarPlay parity step.
5. **Catalog.** The **same CloudFront `apple-music-index.json` endpoints as iOS**,
   with an **offline-first disk cache** mirroring the iOS `CatalogService`
   approach (explicit per-source cache on disk; render from cache instantly, then
   non-destructive conditional refresh — never rely on the HTTP cache to persist
   the large index). HTTP via **OkHttp**, JSON via **kotlinx.serialization**,
   artwork via **Coil**.
6. **Sources reality on Android** *(revised 2026-10-27)*.
   - **Apple Music via the vendored native MusicKit AARs** (`app/libs/`, flatDir):
     the auth AAR yields the Music-User-Token, the mediaplayback AAR plays DRM
     full tracks. Full-track playback is **device-only** (arm64 + subscription);
     the emulator path is the 30 s preview. Everything else Apple Music — catalog
     search, library playlists, favorites, artists/latest releases — goes through
     **one REST client** (`AppleMusicApi`, roadmap D12) with the developer token
     the app already mints, exactly as iOS does write-back over the Web API.
     AM-only tracks with no rip and no sign-in remain browsable metadata.
   - **NO CloudKit** — profile sync is an **S3-backed verbatim port of the iOS
     `CloudSyncService`** over a `CloudDocDatabase` interface, served by the
     first-party `pocketdj-profile-sync` Lambda; "Link with iCloud" becomes
     "Link a device" (QR/code). Document shapes stay identical so iOS and
     Android profiles merge. Owner gates become per-install opt-ins (roadmap D7).
   - The **rip-server (Tailscale/Funnel) + jukebox broker HTTP APIs are reused
     unchanged**.
7. **Mix-tab DSP engine — RESOLVED (roadmap D1).** One shared platform audio
   layer `com.levi.pocketdj.audio` (`AudioSink` + `AudioTrackSink`, one MediaCodec
   decoder, one `OfflineRenderer` for tests, `Voice`/`VoiceGroup`/`RenderClock`).
   The **Mix is a Kotlin in-process pull graph on `AudioTrack`** (low-latency
   float, urgent-audio render thread; per-deck tempo/pitch via Media3's public
   `SonicAudioProcessor`; **no NDK on the Mix path**) because stems, the 60 ms
   handover, cue split, house sum and limiter force an in-process mixer, and a
   pure-Kotlin graph makes the iOS invariants ordinary JVM tests. The **Studio
   gets an `OboeSink` + a small C++ core** (`cpp/pdjdsp`: TinySoundFont,
   Signalsmith Stretch offline, TrackFX/MasterFX kernels) because SoundFont/MIDI
   latency needs a native data callback; all scheduling and state stay in Kotlin.
   Accepted cost: Sonic is a notch below `AVAudioUnitTimePitch` beyond ±25 %
   (Auto-DJ glide ≤10 % and Sync ≈ ±15 % are clean). Switching the Mix onto the
   Oboe sink later is a one-line sink swap.
8. **One MediaSession, one audio owner (roadmap D2).** `PlaybackService` hosts the
   ONLY session (a `MediaLibrarySession` once Android Auto lands). The sequencer's
   forwarding player, the Apple Music adapter and the Mix's `MixSessionPlayer`
   are `SimpleBasePlayer`/`TransportOwner` facades swapped in by a
   `SessionSwitchboard`: the engine that last STARTED audio owns the card; a
   restored-never-sounded engine is not a remote target. No second
   `MediaSessionService`, ever.
9. **Playback core owns the queue (roadmap D11).** An app-scoped
   `SetlistSequencer` (the iOS `SetlistPlayer`) owns the index-cursor queue and
   resolves each row fresh at its turn; ExoPlayer holds only a 1–2 item window.
   Zero-dead-air discipline (runway, watchdogs, stall hop, cascade breaker, rip
   window, supervisor, `DeadAirMeter` with iOS-identical log lines) lands before
   any surface. Rips inside a run are explicit and window-gated; Android never
   fires passive stream-through rips.
10. **Shell extension points + hot-file budget (roadmap D3/D4).** Wave 1 adds a
    `FeatureModule` registry with one DI sidecar graph per area, a settings
    section registry and typed `PrefKey<T>` settings; dependencies, permissions,
    `FileProvider` and shortcut placeholders are swept into the Manifest/Gradle
    once. After wave 1 **no package edits `MainActivity`, `AppGraph`,
    `AppSettingsStore`, `SettingsScreen` or `PocketDjDestination`**; the only
    later Manifest/Gradle editors are named in the parity doc.
11. **Persistence doctrine (roadmap D5/D6).** JSON documents keep the iOS file
    names and CodingKeys verbatim (additive-optional, lenient, atomic
    temp+rename) through one shared `VersionedJsonWriter`; prefs in Preferences
    DataStore; **every secret** (rip/jukebox tokens, Music-User-Token, search
    creds, diag key, profile secret) in a Keystore-backed `SecretStore`; **no
    Room**. **ONE offline burn store** (`data/burns` + WorkManager
    `TransferCoordinator`) shared by Playback, Mix, Studio and Storage.
12. **Diagnostics + verification (roadmap D8/D14).** One `diag/` stack (DiagLog,
    NPLog lanes in the iOS grammar, hand-rolled SigV4 PUT) gated by
    `BuildConfig.DEBUG || DIAG_CHANNEL`; release builds never upload. Every
    package ships JVM tests against iOS fixtures, emulator steps for the headless
    `pocketdj` AVD and an explicit device-only list; acceptance requires the
    **JVM test count to move** and this doc's ledger row to be updated.
13. **Phases → waves.** Phase 1 shipped as its own branch with an emulator
    checkpoint. The remaining work proceeds in the **22 parity waves** below
    (≤6 packages each, parallel worktrees, one owner per hot file per wave);
    each wave ends with an integrator merge + emulator pass, and Levi's review
    milestones fall after the P0 spine (wave 12) and the P1 tail (wave 18).

---

## Implementation phases

| Phase | Scope | Checkpoint |
|---|---|---|
| **1** | **Browser** (incl. **Settings**) + **History** + **Jukebox Hero** | Own branch → emulator checkpoint with Levi |
| **2** | **Collections** (Playlists tab) | Own branch → emulator checkpoint with Levi |
| **3** | **Mix** (DSP-engine decision resolved here) | Own branch → emulator **review milestone** with Levi |
| **4** | **Producer** | Own branch → emulator **review milestone** with Levi |

**Settings ships within Phase 1** and grows as later tabs land (each phase adds its
own Settings rows rather than front-loading them).

**Status of this table (2026-10-27):** Phase 1 is built. Phases 2–4 are **replaced by
the parity waves** below; the Phase 3 DSP decision is resolved (decision 7).

### Parity waves (2026-10-27)

Full wave table with one-line goals, the gap matrix and the per-area architecture are
in [`architecture/android-parity.md`](./architecture/android-parity.md); the roadmap
JSON is `android/specs/parity/roadmap.json`. Packages inside a wave have disjoint
files and run in parallel worktrees (`parity/<ID>` branches); every `depends_on`
lands in an earlier wave.

| Wave | Theme | Packages |
|---|---|---|
| 1 | Foundations: shell/DI extension points + pure cores | GM-2 · SURF-1 · MIX-0 · BRW-1 · COL-1 · SVC-12 |
| 2 | Diag, writer, lifecycle, editions, DSP nodes, recs core A | SVC-5 · COL-2 · SURF-2 · BRW-3 · MIX-3 · BRW-8 |
| 3 | Rip client, onboarding, shared audio core, favorites, Mix + Studio stores | SVC-1 · SURF-3 · MIX-2 · COL-10 · MIX-1 · STU-1 |
| 4 | Sequencer core, burn store, deep links, online search, Mix graph, recs core B | PB-1 · SVC-2 · SURF-4 · BRW-5 · MIX-4 · BRW-9 |
| 5 | Session transport/arbiter, transfers, detail parity, Add-to, stream loader, Studio native lib | PB-2 · SVC-3 · BRW-4 · COL-4 · MIX-6 · STU-2 |
| 6 | Zero dead air, Now Playing deck, burned-first, Mix engine core, jukebox gaps, dedupe | PB-3 · PB-6 · SVC-4 · MIX-5 · SURF-10 · COL-3 |
| 7 | History outcomes, ShellActions, Mix resolver/downloader, stems client, Apple Music API, Producer shell + Samples | PB-5 · SURF-5 · MIX-7 · SVC-11 · SVC-15 · STU-3 |
| 8 | Durable session, filter sheets, Games tab, loop/stems/handover, In the Pocket core, Up Next | PB-4 · BRW-2 · GM-1 · MIX-8 · GM-5 · PB-7 |
| 9 | History screen, Gem Collector engine, multi-select, Auto-DJ, streaming decks, AM rows in a run | BRW-6 · GM-3 · COL-5 · MIX-9 · MIX-10 · PB-8 |
| 10 | Gem Collector UI, source sync, deck UI, storage/prune, Loops + slices, profile-sync Lambda | GM-4 · COL-7 · MIX-13 · SVC-6 · STU-4 · SVC-8 |
| 11 | Mix transport owner, Cues, ZoneEngine, Sequencer tab, In the Pocket store, Settings rows | MIX-11 · STU-6 · BRW-10 · STU-5 · GM-7 · SURF-6 |
| 12 | Document sync engine, Recently added, Mix screen shell, MwF logic, Studio↔collections, jukebox guest | SVC-7 · COL-12 · MIX-14 · GM-9 · STU-7 · SURF-11 |
| 13 | Mix recording, S3 sync + link-a-device, AM write-back, collection timeline, Tracks arranger, Instruments | MIX-12 · SVC-9 · COL-8 · BRW-7 · STU-11 · STU-8 |
| 14 | Credentials sync, For You store, ITP screen, Demuxer core, widgets, Score | SVC-10 · BRW-11 · GM-8 · STU-14 · SURF-7 · STU-9 |
| 15 | Reset/account deletion, MwF screens, Android Auto, MultitrackPlayer, For You UI, Mix sessions screen | SVC-13 · GM-10 · SURF-8 · STU-12 · BRW-12 · MIX-15 |
| 16 | Cloud recs, Mix integrations, MIDI + arp, bounce/record/beat-match, collection codecs, listening-pockets wires | BRW-13 · MIX-16 · STU-10 · STU-13 · COL-14 · COL-16 |
| 17 | Discover, Now Playing Mix panel + Stem Lock, export/import UI, Demux extras, per-collection sort, gapless | BRW-15 · MIX-18 · COL-15 · STU-15 · COL-13 · PB-10 |
| 18 | Discover ＋Add, drag & drop, AM playlist sync, slot modulation, Auto Mix tab, SAF burn folder | BRW-16 · COL-6 · COL-9 · MIX-17 · SURF-9 · SVC-14 |
| 19 | Recognizer, favorites two-way sync, Studio hardening | BRW-17 · COL-11 · STU-16 |
| 20 | Listening pockets service, New releases | COL-17 · BRW-14 |
| 21 | History ▸ Pockets, listening places engine | COL-18 · COL-19 |
| 22 | Android location source | COL-20 |

---

## Status — by component (mirroring the Apple doc)

### Ch. 1 — Foundations · *Status: Built (Phase 1)*
Android consumes the shared entities, the files-as-API spine, and the
content-derived ids **unchanged** — no Android-side id minting, no new document
shapes. Built: `data/config/Endpoints.kt` (prod CloudFront base + per-source index
URLs + art/rips/lyrics URL builders), one lenient `PdjJson` for every remote and
on-disk doc, `AppSettingsStore` (Preferences DataStore, corruption-handled,
transactional edits), implementation contracts extracted from the iOS app into
`android/specs/*.md` (catalog / playback / browse / history / jukebox).

### Ch. 2 — Ingest & Enrichment · *Status: Shared backend — no Android work*
All ingest/enrichment runs on the iMac + cloud workers and publishes to S3; Android
only ever reads the outputs. Nothing to port. (Client-visible enrichment fields —
bpm/key/beat grids/lyrics — arrive with the catalog in Phase 1.)

### Ch. 3 — Catalog & Data Model · *Status: Catalog Built (Phase 1) · Collections Planned (Phase 2)*
Built: lean lenient index models, `CatalogService` (ETag/Last-Modified conditional
GET — live-verified 304s against prod — atomic disk cache), `CatalogRepository`
(render-from-cache-instantly, non-destructive refresh with per-source last-good
substitution so a failed fetch can never shrink a rendered catalog, queued-refresh
on concurrent source changes), `MergedCatalog` multi-source merge with
ids-travel-verbatim. `PlayHistoryStore`: additive-optional JSON doc, atomic writes,
corrupt-quarantine-to-`.bak` + unreadable-salvage (union-by-event-id) so transient
IO can never destroy the log. Also built: the collections document v7
(`CollectionsStore` + lossy `CollectionsCodec`), `CollectionActivityStore`, the
Playlists tab with pocket/playlist/setlist detail — **device-local only** today.
Parity (audit: 11 DONE · 5 PARTIAL · 20 MISSING): additive iOS fields + fixture
round-trip (COL-1), batch choke points + shared writer (COL-2), favorites (COL-10),
Add-to parity (COL-4), dedupe (COL-3), multi-select/DnD (COL-5/6), source sync +
AM write-back/playlist sync (COL-7/8/9), recently-added (COL-12), per-collection
sort (COL-13), export/import (COL-14/15), listening pockets + places (COL-16…20).
Cross-device sync arrives with SVC-7/8/9 (S3 profile sync, decision 6).

### Ch. 4 — Performance Engine · *Status: realize() Built · Mix Planned (waves 1–18) · Producer Planned (waves 3–19) · Games Planned (waves 1–15)*
Built: pockets → playlists → setlists and the `realize()` engine over the shared
collection shapes (`QueuePlan`). **Mix** (audit: 1 PARTIAL · 32 MISSING · 7 N/A):
the DSP substrate is decided (decision 7) — pure models/math (MIX-0), shared audio
core (MIX-2) + DSP nodes (MIX-3) + graph (MIX-4), stores (MIX-1), engine core (MIX-5),
streams (MIX-6/10), resolver/downloader (MIX-7), loop/stems/handover (MIX-8), Auto-DJ
(MIX-9), transport owner (MIX-11), recording (MIX-12), deck UI + screen + sessions
(MIX-13/14/15), integrations (MIX-16), slot modulation (MIX-17), Now Playing panel +
Stem Lock (MIX-18). **Producer** (audit: 1 DONE · 2 PARTIAL · 27 MISSING): STU-1
models/store → STU-2 native lib + `OboeSink` → STU-3 shell + Samples → Loops,
Sequencer, Cues, collections integration (STU-4…7) → Instruments, Score, MIDI,
Tracks arranger, Demuxer (STU-8…15) → hardening (STU-16). Only the Producer
placeholder route exists today. **Games** (audit: 24 MISSING · 4 N/A): GM-2 Gem
Collector core (wave 1, pure) → GM-1 tab + scoreboard → GM-3/4 engine + UI → GM-5/7/8
In the Pocket → GM-9/10 Music with Friends. Nothing of Games exists today.

### Ch. 5 — Playback & Rip-on-Demand · *Status: Core Built (Phase 1) · grows with later phases*
Built: `PlaybackService` (Media3 ExoPlayer inside a `MediaSessionService`,
media-notification transport) + `PlaybackController` facade (play by songId via the
public rips manifest, album-context queueing, `StateFlow` now-playing state,
app-wide error snackbar), the docked mini-player bar, play-event bus → History
(iOS-parity dedup semantics; Browse singles tagged `browser`, album queues tagged
`album`). Rip-on-demand against the user-configured rip server with
transient-poll-resilient await (only 10 consecutive failures abort). The vendored
MusicKit `AppleMusicBackend` plays full tracks on a signed-in device (30 s previews
on the emulator) but has no MediaSession and is a second, uncoordinated engine.
**Honest gaps** (audit: 2 DONE · 11 PARTIAL · 15 MISSING · 5 N/A): no sequencer
object (ExoPlayer's playlist IS the queue today), no Now Playing deck, no durable
session, no dead-air/stall discipline, no diag upload, no burns. Parity order
(decision 9): SVC-5 diag → SVC-1 rip client → PB-1 sequencer → PB-2 session
transport + one-owner arbiter → PB-3 zero dead air + PB-6 Now Playing deck →
PB-5 history outcomes → PB-4 durable session + PB-7 Up Next → PB-8 Apple Music
rows in a run → PB-10 gapless. Offline burns = SVC-2/3/4 (waves 4–6). Android Auto
= SURF-8/9 (waves 15/18), after phone playback is solid.

### Ch. 6 — Search & Discovery · *Status: Browser + History Built (Phase 1) · online search deferred*
Built: **Browser** — Albums|Songs kinds, grid/list layouts, device search, filter
sheet (genre/BPM/Camelot/source), multi-key **sort sheet** (BPM numeric, Camelot
wheel-rank, nulls-last; engine ported bit-for-bit from iOS `BrowseModel`), album
detail + song detail sheet, and a **persisted browse session** (kind/filters/
sort/layout survive process death; lenient snapshot doc, 400 ms debounce).
**History** — Plays timeline w/ search, Newest/Oldest sort, date-range filter,
row → song detail, per-context labels; an Android-only "Unified" History tab exists
and will be removed to match iOS (BRW-6). **Gaps** (audit: 6 DONE · 10 PARTIAL ·
21 MISSING · 5 N/A): the full 18-field clause filter engine (BRW-1/2), the
explicit/edition system (BRW-3), lyrics/share/shuffle on detail (BRW-4), online
**aoss** search with SigV4-signed direct queries (BRW-5 — the Settings toggle was
deliberately removed rather than shipping a dead control), History parity +
collection timeline (BRW-6/7), the recommendation engine and For You (BRW-8…13),
new releases (BRW-14), Discover search + ＋Add (BRW-15/16), the Shazam recognizer
(BRW-17). Artists kind + `ArtistCatalog` are built. The web star map is a PWA-only
surface — no Android port planned.

### Ch. 7 — Distribution & Clients · *Status: Skeleton + Jukebox Built (Phase 1)*
Built: the Gradle root under `android/` (decisions 1–3; AGP 8.9.1 / Gradle 8.13
wrapper / Kotlin 2.1 / Compose BOM 2025.01.00), the 6-tab shell, and the
`android-build` / `android-test` / `android-emu` skills (verified commands).
**Jukebox Hero DJ-side**: broker session open, locally-rendered QR of the guest
URL (zxing-core), lifecycle-aware request polling, accept→play / deny with
thread-safe decision bookkeeping, honest state posts (a failed player read skips
the post rather than reporting idle), played-history section, graceful
not-configured/unreachable states. The distribution channel (Play internal
testing vs direct APK — the TestFlight analogue) is still an open question.
**Shell + surfaces gaps** (audit: 2 DONE · 7 PARTIAL · 7 MISSING · 4 N/A): adaptive
scaffold + 7th Games destination + registries (SURF-1), Application lifecycle +
WorkManager (SURF-2), zero-to-hero onboarding (SURF-3), deep links + file opens
(SURF-4), `ShellActions` + Assistant + shortcuts (SURF-5), settings rows (SURF-6),
Glance widgets (SURF-7), Android Auto (SURF-8/9), jukebox host gaps + guest surface
(SURF-10/11). **Services gaps** (audit: 6 DONE · 3 PARTIAL · 22 MISSING · 2 N/A):
rip client parity, burn store, transfers, burned-first playback, diag, storage
prune, profile sync + link-a-device, credentials sync, stems client, reset, catalog
polish, SAF burn folder, Apple Music API (SVC-1…15). Apple-specific surfaces now
have **named Android counterparts**: WidgetKit → Glance (SURF-7), App Intents/Siri
→ `ShellActions` + `MEDIA_PLAY_FROM_SEARCH` + launcher shortcuts (SURF-5), CloudKit
profiles → S3 profile sync (SVC-7/8/9), MusicKit favorites sync → Web-API favorites
sync, opt-in (COL-11), CarPlay → Android Auto (SURF-8/9). What stays N/A is listed
in the parity doc §5 (22 entries, each with its replacement or reason).

---

## API-36-only candidates

Running list of Android-16-only capabilities that could justify dropping minSdk 35
(per decision 3). Add entries only when confident they are real API-36 additions
that materially help a PocketDJ feature — no speculation.

- **`Notification.ProgressStyle` (Live Updates, API 36):** progress-centric,
  richly-rendered live notifications — a natural fit for the rip / burn / transfer
  progress surfaces that iOS shows via background-task UI. On minSdk 35 these fall
  back to plain progress notifications.

*(Nothing else identified yet.)*

---

## Open questions

1. **Mix DSP engine — RESOLVED 2026-10-27 (decision 7, roadmap D1).** Kotlin
   pull-graph on `AudioTrack` with Media3 Sonic time/pitch for the Mix; Oboe +
   small C++ core for the Studio; one shared `audio/` layer and `AudioSink`
   contract so the Mix can move onto Oboe later with a sink swap. Accepted cost
   recorded: Sonic quality beyond ±25 % stretch. The original candidates were
   Media3/AudioTrack (managed) vs Oboe/native (C++); the answer is both, split by
   what each path actually needs.
2. **Profile sync without CloudKit — RESOLVED 2026-10-27 (decision 6, roadmap
   D7).** Verbatim `CloudSyncService` port over `CloudDocDatabase`, S3 behind the
   `pocketdj-profile-sync` Lambda (SVC-7/8/9, waves 12–13), optional remote-endpoint
   key `profileSyncBase`, link-a-device by QR/code. Still open inside it: QR
   *scanning* on the joining device is deferred (code entry only).
3. **Distribution channel.** Play Console internal testing vs direct APK sideload
   for Levi's devices — decide before the first wave ships a build worth
   installing. Still open.
4. **App Links verification.** `https://jukebox.pocket-dj.com/{join,mwf}/` deep
   links need `/.well-known/assetlinks.json` with the signing-cert fingerprint on
   the jukebox host (SURF-4/GM-10); `pocketdj://` links work without it.
5. **Push for Music with Friends.** The broker speaks APNs only; FCM would need
   Firebase in the app plus a broker change. Shipping without push (4 s poll, the
   source of truth on iOS too). Revisit only if polling proves costly.

---

## Parity status ledger — by package

One row per roadmap package. **Every package's acceptance includes updating its
row** (DONE / PARTIAL + what is device-only, with the merge commit). Status
values: *Planned* → *In progress* (branch `parity/<ID>`) → *Merged* (into
`feat/android-parity`, JVM green, emulator steps run) → *Device-verified* where
the row has device-only items. Wave sections with test counts and emulator results
accumulate in `android/specs/parity/PROGRESS.md`.


**Shell + system surfaces**

| Package | Wave | Status | Device-only |
|---|---|---|---|
| SURF-1 — Shell foundation: adaptive scaffold, FeatureModule registry + area sidecar graphs, settin… | 1 | Planned | — |
| SURF-2 — Application lifecycle + background work: PocketDjApplication, ProcessLifecycle flush funn… | 2 | PARTIAL | storage-prune measure-only (no soft-cap prune); jukebox onStart bootstrap deferred; emulator steps not run |
| SURF-3 — Zero-to-hero onboarding (store, 3 stages, launch gate, mutating-intent veto, link-a-devic… | 3 | PARTIAL (veto wiring deferred to SURF-5; link probe stubbed until SVC-9; real AM sign-in device-only) | Real Apple Music sign-in completion in stage 2 (emulator verifies can… |
| SURF-4 — Deep links + file opens: manifest filters, DeepLinkParser, pending-until-onboarding, disp… | 4 | PARTIAL (seams unassigned, defaults are visible placeholders: playItem SURF-5; joinJukebox JBX-2; importCollection SET-2/COL-15; mwf GM-10) | App Links auto-verification (needs https://jukebox.pocket-dj.com/.wel… |
| SURF-10 — Jukebox host parity gaps: played-history dedup rule, require-token default toggle, sessio… | 6 | Planned | Apple Music catalog search stage (needs AM sign-in) — seam only in th… |
| SURF-5 — ShellActions façade (IntentServices analogue) + MixFacade seam + Assistant media search +… | 7 | Planned | Real Google Assistant voice ('play my warmup pocket on PocketDJ') — t… |
| SURF-6 — Settings shell rows: Profile name, Collections default recently-added count, Import serve… | 11 | Planned | — |
| SURF-11 — Jukebox guest: JukeboxLink, joined-sessions list, join panel with request line + Tune In … | 12 | Planned | — |
| SURF-7 — Glance Now Playing widget (small/medium/large + idle) with snapshot sync and offline comm… | 14 | Planned | — |
| SURF-8 — Android Auto: MediaLibraryService browse tree (Playlists · Pockets · Continue), play/add-… | 15 | Planned | Real head unit / DHU rendering, voice; emulator uses the Desktop Head… |
| SURF-9 — Android Auto Mix tab + Jukebox session rows (two-crate Auto DJ remote) | 18 | Planned | Real head unit; real Mix audio (depends on the Mix area's engine). |

**Services (rips, burns, sync, diag, storage)**

| Package | Wave | Status | Device-only |
|---|---|---|---|
| SVC-12 — Catalog cache polish + green compiled-in endpoints pinned by test | 1 | Planned | — |
| SVC-5 — Diagnostics: DiagLog + NPLog lanes, shared SigV4 S3 uploader, .pdjdiagkey import, jank wa… | 2 | Planned | — |
| SVC-1 — Rip client parity: presign + prefetch, 20 s bounded interactive wait + StillRipping, job … | 3 | PARTIAL | emulator-verified 2026-10-27 with a mock rip server (presign, bounded wait + tracker hand-off); not verified: presigned playback on a private bucket, "Still ripping" flow, mid-queue URL refresh) |
| SVC-2 — BurnStore core (ONE offline store): ledger, byte-identical file names, sidecar, stems + b… | 4 | Planned | — |
| SVC-3 — TransferCoordinator over WorkManager: background burn downloads surviving process death, … | 5 | Planned | Doze-deferred periodic timing is only observable on hardware; the emu… |
| SVC-4 — Burned-first row resolver + device/cloud PlaybackMode + collection Rip/Burn bar with Stop… | 6 | Planned | — |
| SVC-11 — Cloud stems client (stemify/stem jobs) + burned stems/beat-grids pull + Stemify action on… | 7 | Planned | — |
| SVC-15 — Apple Music Web API client: catalog search, library playlists CRUD, favorites, artists la… | 7 | Planned | Library (write) endpoints need a real Music-User-Token from the vendo… |
| SVC-6 — PlayStatsStore + StorageManager prune engine + StoragePruneWorker + Storage screen burn/s… | 10 | Planned | Periodic worker cadence under Doze. |
| SVC-8 — Backend: pocketdj-profile-sync Lambda (S3 document store) + optional endpoint key | 10 | Planned | Deploy to the green account needs AWS profile llc; unit tests run aga… |
| SVC-7 — Document sync engine (CloudSyncService verbatim port) + ProfileStore + in-memory CloudDoc… | 12 | Planned | — |
| SVC-9 — S3CloudDocDatabase + enroll + link-a-device (QR/code) + onboarding stage-1 probe | 13 | Planned | QR camera scanning is deferred (code entry only); nothing else. |
| SVC-10 — Synced connection credentials doc (empty-secret guard) + diag-key sync doc + X-PocketDJ-P… | 14 | Planned | — |
| SVC-13 — Reset everything (FeatureModule.resetHooks orchestrator, iOS mushroom-cloud order) + acco… | 15 | Planned | — |
| SVC-14 — User-browsable burn folder via SAF (destination captured on the transfer record at enqueu… | 18 | Planned | Removable media on a real device; emulator verifies the picker + inte… |

**Playback core + Now Playing**

| Package | Wave | Status | Device-only |
|---|---|---|---|
| PB-1 — SetlistSequencer core: cursor queue, live edits, repeat/shuffle, per-row resolve ladder, … | 4 | Planned | Apple Music rows inside a run (full-track rung) need a signed-in arm6… |
| PB-2 — Session transport + one-owner arbiter: SequencerForwardingPlayer, SessionSwitchboard (Tra… | 5 | Planned | Bluetooth/headset routes, AVRCP head units and the actual lock-screen… |
| PB-3 — Zero dead air: rip-on-demand resolver in runs, runway, watchdogs, stall hop, cascade brea… | 6 | Planned | Real cellular dead zones; Apple Music lane behaviours |
| PB-6 — Now Playing deck screen (gold record at beat-grid BPM, transport, notices) + mini bar upg… | 6 | Planned | — |
| PB-5 — History outcomes: SkipTracker + additive PlayEvent fields + progress/advance-away events … | 7 | Planned | — |
| PB-4 — Durable playback session: real-time snapshot, held restore, resume at position, materiali… | 8 | Planned | — |
| PB-7 — Up Next, previously played, add-search, open set list, queue reorder; jukebox routed thro… | 8 | Planned | — |
| PB-8 — Apple Music rows in a run: AppleMusicPlayerAdapter (SimpleBasePlayer TransportOwner) + en… | 9 | Planned | Full-track DRM playback requires a real device with a subscription (v… |
| PB-10 — Gapless preload window (next resolved row pre-added to ExoPlayer) | 17 | Planned | — |

**Collections**

| Package | Wave | Status | Device-only |
|---|---|---|---|
| COL-1 — Collections + activity schema parity (additive iOS fields, lenient kinds, iOS fixture rou… | 1 | DONE (JVM) | Emulator adb-push round-trip not run (integrator). amPlaylistId NOT persisted, matches iOS CodingKeys (roadmap deviation, owner decision pending). |
| COL-2 — Store batch choke points + shared VersionedJsonWriter (off-main, version-ordered, invalid… | 2 | Planned | — |
| COL-10 — Favorites store + ♥ toggle + Browse favorite tri-state filter model + heart/unheart activ… | 3 | PARTIAL (JVM) | Browse ♥ + tri-state filter (song mode) wired in BrowseScreen/SongDetailSheet/AlbumDetailScreen; emulator drive not run (integrator). Open: backup-zip + profile-sync registration of `pocketdj-favorites.json`; `favorites.remapSongIds` has no caller (no Discover/amrec_ supersede path on Android yet — wire alongside CollectionsStore remap). |
| COL-4 — AddToActions + Add-to sheet parity (Suggested + Recent, pockets A–Z, playlists A–Z, More…… | 5 | Planned | — |
| COL-3 — SongDuplicateJudge (deterministic tiers) + Remove duplicates (collection, all collections… | 6 | Planned | — |
| COL-5 — Multi-select: RowSelection + SelectableRow + SelectionBar on Browse and every collection … | 9 | Planned | — |
| COL-7 — Source-sync completion: auto reconcile on catalog refresh, global + per-item toggles, dir… | 10 | Planned | — |
| COL-12 — Recently added virtual playlist (derivation from IndexSong.dateAdded + add history) + Set… | 12 | Planned | — |
| COL-8 — Apple Music write-back queue (durable, Web API transport via SVC-15, batch confirm, backf… | 13 | Planned | Needs a real Apple Music subscription + Music-User-Token; emulator ve… |
| COL-14 — .pdjcollection + backup .pocketdj.zip codecs, idempotent import merge, CSV (pure JVM, byt… | 16 | Planned | — |
| COL-16 — Listening pockets wire models (extending GM-5 PocketsModels), HTTP client, CollectionFlat… | 16 | Planned | — |
| COL-13 — Per-collection sort/filter on every collection detail (BrowseEngine over the song subset,… | 17 | Planned | — |
| COL-15 — .pdjcollection / backup SAF export-import UI, tapped-file open (deep-link handler), provi… | 17 | Planned | — |
| COL-6 — Song drag & drop + clipboard (SongTransfer payload, collection-row and whole-list drop ta… | 18 | Planned | — |
| COL-9 — Apple Music playlist sync (Lambda WS2): client, coordinator, audit/run persistence, daily… | 18 | Planned | Real subscription + MUT. |
| COL-11 — Favorites two-way Apple Music sync (opt-in) + owner-seed opt-in (default OFF) | 19 | Planned | Real subscription + MUT. |
| COL-17 — ListeningPocketsService (upload cadence, results cache, cursors/flushEpoch, delete cascad… | 20 | Planned | — |
| COL-18 — History ▸ Pockets screen (Recurring/Recent, patterns, detail: features/harmonic/when/song… | 21 | Planned | — |
| COL-19 — Listening places engine + location store (pure port, no platform APIs) | 21 | Planned | — |
| COL-20 — Android location source (fused low-power + dwell detection) + Settings rows + wiring (def… | 22 | Planned | Real movement/dwell; emulator uses `adb emu geo fix` sequences. |

**Browse / History / Discover / For You / search**

| Package | Wave | Status | Device-only |
|---|---|---|---|
| BRW-1 — Full filter/sort clause engine (18 fields, 5 ops) as pure BrowseEngine.filterSort + persi… | 1 | Planned | — |
| BRW-3 — Explicit/edition system (SongVariant, EditionPolicy, clean-only) + streaming-link and dat… | 2 | Planned | Actual explicit/clean Apple Music streaming (DRM) verification. |
| BRW-8 — Recs core A: SimilarityFamilies, Similarity profile, TimbreCatalog (timbrePrior=2 load-be… | 2 | Planned | — |
| BRW-5 — Online OpenSearch (aoss) search: device↔online toggle, SigV4-signed direct queries, claus… | 4 | Planned | — |
| BRW-9 — Recs core B: identity + shaping (version/recording identity, membership, novelty, composi… | 4 | DONE | device-only: none (pure) |
| BRW-4 — Song/Album detail parity: lyrics store + timed-lyrics sidecar + lyrics panel, share text,… | 5 | Planned | — |
| BRW-2 — Filter/sort sheets at full width + membership (in/not-in, none-of) + favorite + hide-skip… | 8 | Planned | — |
| BRW-6 — History screen parity: tab model (Playback \| Collection \| Pockets \| For You slots), en… | 9 | Planned | — |
| BRW-10 — ZoneEngine: In Da Zone + collection suggestions + cloud shaping | 11 | Planned | — |
| BRW-7 — Collection timeline (F8) + timeline cue store + History ▸ Collection tab | 13 | Planned | — |
| BRW-11 — For You feed store, feedback store, read-time refresh schedule, tiles/grid, recsEnabled t… | 14 | Planned | — |
| BRW-12 — For You UI: History ▸ For You tab, tiles grid, song list, feedback buttons, recs toggle, … | 15 | Planned | — |
| BRW-13 — Cloud recommendation engine service + client + rec key (device-local) + Settings ▸ Recomm… | 16 | Planned | — |
| BRW-15 — Discover tab: Apple Music catalog search (SVC-15) ∥ rip-server /search, Songs\|Albums sco… | 17 | Planned | — |
| BRW-16 — Discover ＋Add: provisional catalog entries, album fan-out, supersede, Remove from Library | 18 | Planned | Apple Music library write needs a signed-in Music-User-Token (works i… |
| BRW-17 — '?♪?' recognizer: vendored ShazamKit-for-Android AAR + AudioRecord + catalog match + resu… | 19 | Planned | Live recognition needs a microphone + the vendored AAR's native libs;… |
| BRW-14 — New releases feed + screen + release streaming (am:<storeId> rows through the AM resolver) | 20 | Planned | Playing an unowned release (Apple Music DRM playback) — verify on a d… |

**Mix**

| Package | Wave | Status | Device-only |
|---|---|---|---|
| MIX-0 — Mix models, FX rack types, pure math (BeatMath, MixMath, Camelot, FxParams) | 1 | In progress (parity/MIX-0) | — |
| MIX-3 — Shared DSP nodes (`audio/dsp`): Biquad/Eq3/Trim, TimePitch (Sonic), Compressor, Reverb, M… | 2 | Planned | Subjective quality of Sonic at large stretch ratios |
| MIX-1 — Durable Mix stores over the shared VersionedJsonWriter: MixDeckSessionStore (decks v1) + … | 3 | DONE (JVM; stores unreachable from UI until MIX-14) | — |
| MIX-2 — Shared audio core (`audio/`): AudioSink + AudioTrackSink, RenderClock, FloatRing, PcmSour… | 3 | DONE (JVM + emulator decode; audible output device-only) | Audible output and AudioTrack low-latency behaviour on real hardware. |
| MIX-4 — MixGraph: deck chains, house/cue/limiter, taps, render-thread handover + parameter snapsh… | 4 | Planned | Hearing cue on the chosen channel of a real stereo interface |
| MIX-6 — MixStreamLoader: growing-file song streams (public rips object + Range) + stem sets, adop… | 5 | Planned | — |
| MIX-5 — MixEngine core: decks, load/seek/transport, EQ, FX rack, Vol/crossfader, cue, lead/sync, … | 6 | Planned | Audible verification of tempo/pitch quality and cue routing |
| MIX-7 — MixResolver + CollectionMixDownloader (collection pull with progress/ETA + progressive el… | 7 | Planned | — |
| MIX-8 — Loop (∞) + stem decks + zero-dead-air handover + beat-grid hydrate | 8 | Planned | Hearing the handover seam and loop click-freeness |
| MIX-10 — Streaming decks in the engine (growing-file playback, hold/resume, truncation, stem strea… | 9 | Planned | Cellular dead-zone behaviour |
| MIX-9 — Auto-DJ machine + readiness rules + glide + remote freeze + jukebox queue seams | 9 | Planned | Real lock-screen transport and headset-button behaviour |
| MIX-13 — Deck UI: DeckView + controls (sliders/knobs/steppers), seek slider, FX chips, stem pads, … | 10 | Planned | — |
| MIX-11 — Mix transport owner: MixSessionPlayer (SimpleBasePlayer TransportOwner) into the ONE Medi… | 11 | Planned | Bluetooth route changes, phone-call interruption, headset buttons, re… |
| MIX-14 — Mix screen shell: session header, Auto setup bar/banner/skip, crate menus A/B (scroll res… | 12 | Planned | — |
| MIX-12 — Mix session audio recording (house tap → ADTS AAC) + MixRecorder + orphan recovery + Reco… | 13 | Planned | — |
| MIX-15 — Sessions screen + replay timeline + recordings panel | 15 | Planned | — |
| MIX-16 — Integrations: Jukebox ↔ Mix seams, MixPlayOutcomeBridge → History, MixFacade implementati… | 16 | Planned | — |
| MIX-18 — Now Playing Mix mini-panel (F4: swap-on-touch ExoPlayer→DSP hand-off, stems/effects/tempo… | 17 | Planned | Audible seamless hand-off and route changes. |
| MIX-17 — Slot modulation (LFO beat-locked + envelope follower) on the FX rack | 18 | Planned | Audible sweep |

**Producer (Studio)**

| Package | Wave | Status | Device-only |
|---|---|---|---|
| STU-1 — Studio models + store (pocketdj-studio.json v1 over VersionedJsonWriter) + folders (SAF r… | 3 | DONE (JVM + emulator seed/persist; SAF persistence device-only) | SAF tree permission persistence on real external storage |
| STU-2 — Studio native DSP lib (cpp/pdjdsp: TinySoundFont, Signalsmith Stretch, TrackFX/MasterFX k… | 5 | Planned | Oboe low-latency path, real latency numbers, route-change (headphones… |
| STU-3 — Producer shell + Samples tab (mic, import, from-track via LocalAudioCache→BurnStore) + sa… | 7 | Planned | Real mic quality, Bluetooth input picker, DRM-protected file rejectio… |
| STU-4 — Loops tab + slice editor (performance pads) | 10 | Planned | Audible seam-click judgement |
| STU-5 — Sequencer tab + pattern engine (clock, step modes, per-step loop/stretch) + bounce | 11 | Planned | Timing tightness and .interrupts cut audibility |
| STU-6 — Cues tab + cue-seek playback plumbing (sequencer seek) + CuePointsProvider for the Mix de… | 11 | Planned | Apple Music native backend play-then-seek |
| STU-7 — Collections integration: StudioRowResolver (play studio ids as local files), counts, real… | 12 | Planned | — |
| STU-11 — Tracks arranger: model CRUD, home list + folders, lanes/clips UI, clip baker, artifacts b… | 13 | Planned | — |
| STU-8 — Instrument packs + SF2 synth engine (native) + on-screen keys + takes (click/count-in) | 13 | Planned | Latency feel on Oboe; large-bank parse time on a real device |
| STU-14 — Demuxer core: sources + DemuxStore + chord detection + timeline + chord detail + stems (d… | 14 | Planned | Real-song chord quality |
| STU-9 — Score: quantizer, layout, editor (Enter/Select/Move/Edit, undo/cancel), live staff, PDF +… | 14 | Planned | — |
| STU-12 — MultitrackPlayer (single render callback: clip sum + per-track gain/pan + TrackFX + Maste… | 15 | Planned | Oboe latency, live FX quality judgement |
| STU-10 — MIDI input (USB + BLE via MidiManager) + arpeggiator + overdub staffs | 16 | Planned | USB/BLE MIDI hardware. |
| STU-13 — Bounce (artifact), record-to-master (Clean/Quantized), scissor trim (multi-select), Beat … | 16 | Planned | Record-pitch correctness on a 48 kHz hardware device (the iOS 8.8%-sl… |
| STU-15 — Demux drum pattern + melody + key + instrumental + cut sample + send stems to arrangement… | 17 | Planned | Real-stem detection quality |
| STU-16 — Studio hardening + diagnostics + emulator seed + docs sync + single-audio-layer grep guard | 19 | Planned | Headphone unplug / Bluetooth route change re-prime across each engine |

**Games**

| Package | Wave | Status | Device-only |
|---|---|---|---|
| GM-2 — Gem Collector core: settings, recency, sampler, similarity, decision store, rec bridge (p… | 1 | DONE | device-only: none |
| GM-1 — Games tab (7th destination via nav registry) + Scoreboard store (tombstones, union merge)… | 8 | Planned | — |
| GM-5 — In the Pocket core: models, pockets results decode (PocketsModels owner), scorer, members… | 8 | Planned | — |
| GM-3 — Gem Collector engine + GameRunPlayer over the sequencer (appendRows(runTag), preview-reso… | 9 | Planned | Apple Music preview resolution needs network; full-track AM is delibe… |
| GM-4 — Gem Collector screens (setup / countdown / running / summary) + multi-collection filing v… | 10 | Planned | — |
| GM-7 — In the Pocket store + PocketsBridge interface (NoPocketsBridge default) + rounds upload c… | 11 | Planned | Cloud mode needs real pockets results (services area + rec key) — ver… |
| GM-9 — Music with Friends link, models, client, join secret, session file, store (broker-driven,… | 12 | Planned | — |
| GM-8 — In the Pocket screen + on-device feedback dictation | 14 | Planned | SpeechRecognizer dictation needs a real microphone/Google app; emulat… |
| GM-10 — Music with Friends screens + deep-link handler (pocketdj://mwf, https /mwf/) + Games home… | 15 | Planned | https App Link auto-verification needs /.well-known/assetlinks.json o… |
