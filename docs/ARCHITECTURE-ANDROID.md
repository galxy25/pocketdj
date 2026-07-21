# PocketDJ — Architecture (Android)

> **LIVING DOCUMENT.** This is the plan-and-progress record for the Android port,
> updated as each phase is implemented. **Phase 1 is built** (branch
> `feat/android-phase1`, 2026-07-21): Browser (incl. Settings) + History +
> Jukebox Hero over the core catalog/playback layers, verified end-to-end on the
> `pocketdj` emulator against the live CloudFront catalog. Later-phase sections
> remain *Planned* with the same per-component honesty as the
> [Apple doc's Status ledger](./ARCHITECTURE-APPLE.md#status--whats-built-by-component).

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
6. **Sources reality on Android.**
   - **NO MusicKit** — Apple Music streaming is impossible on Android. AM-only
     tracks are **browsable metadata**; playback exists only where a **public
     rip/burn** exists.
   - **NO CloudKit** — profile sync is **deferred**; a future S3-backed sync is
     noted as an [open question](#open-questions).
   - The **rip-server (Tailscale/Funnel) + jukebox broker HTTP APIs are reused
     unchanged**.
7. **Mix-tab DSP engine** (Media3/AudioTrack vs Oboe/native) is an **OPEN
   question**, resolved in Phase 3 — both candidates recorded under
   [open questions](#open-questions).
8. **Phases.** Implementation proceeds in the four phases below; **each phase is
   its own branch** and ends with an **emulator checkpoint with Levi**.

---

## Implementation phases

| Phase | Scope | Checkpoint |
|---|---|---|
| **1** | **Browser** (incl. **Settings**) + **History** + **Jukebox Hero** | Own branch → emulator checkpoint with Levi |
| **2** | **Playlists** | Own branch → emulator checkpoint with Levi |
| **3** | **Mix** (DSP-engine decision resolved here) | Own branch → emulator **review milestone** with Levi |
| **4** | **Producer** | Own branch → emulator **review milestone** with Levi |

**Settings ships within Phase 1** and grows as later tabs land (each phase adds its
own Settings rows rather than front-loading them).

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
IO can never destroy the log. Phase 2: the collections document
(pockets/playlists/setlists) and favorites — **device-local only** at first, since
there is no CloudKit on Android; cross-device profile sync is deferred (open
question: S3-backed sync).

### Ch. 4 — Performance Engine · *Status: Planned (Phase 2 realize · Phase 3 Mix · Phase 4 Producer)*
Phase 2: pockets → playlists → setlists and the `realize()` engine over the shared
collection shapes. Phase 3: the two-deck **Mix** engine — the DSP substrate
(Media3/AudioTrack vs Oboe/native) is chosen at the start of this phase. Phase 4:
the **Producer** (Studio) surfaces.

### Ch. 5 — Playback & Rip-on-Demand · *Status: Core Built (Phase 1) · grows with later phases*
Built: `PlaybackService` (Media3 ExoPlayer inside a `MediaSessionService`,
media-notification transport) + `PlaybackController` facade (play by songId via the
public rips manifest, album-context queueing, `StateFlow` now-playing state,
app-wide error snackbar), the docked mini-player bar, play-event bus → History
(iOS-parity dedup semantics; Browse singles tagged `browser`, album queues tagged
`album`). Rip-on-demand against the user-configured rip server with
transient-poll-resilient await (only 10 consecutive failures abort). AM-only
tracks with no public rip render metadata-only, exactly per the sources reality.
Offline burns, setlist transport, and stem playback follow with the phases that
need them (Playlists → Mix → Producer). Android Auto lands after phone playback
is solid, as the CarPlay-parity step.

### Ch. 6 — Search & Discovery · *Status: Browser + History Built (Phase 1) · online search deferred*
Built: **Browser** — Albums|Songs kinds, grid/list layouts, device search, filter
sheet (genre/BPM/Camelot/source), multi-key **sort sheet** (BPM numeric, Camelot
wheel-rank, nulls-last; engine ported bit-for-bit from iOS `BrowseModel`), album
detail + song detail sheet, and a **persisted browse session** (kind/filters/
sort/layout survive process death; lenient snapshot doc, 400 ms debounce).
**History** — Plays timeline w/ search, Newest/Oldest sort, date-range filter,
row → song detail, per-context labels; the Activity segment is a selectable
Phase-2 placeholder. **Deferred:** online **aoss** search (the Settings toggle was
deliberately removed rather than shipping a dead control — wire the CloudFront
SigV4 proxy + credential fields when it lands). The web star map is a PWA-only
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
Apple-specific system surfaces (widgets, App Intents/Siri, CloudKit profiles,
MusicKit favorites sync) have **no Android counterpart planned yet**; they are
listed here so their absence is a recorded decision, not an oversight.

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

1. **Mix DSP engine (resolve in Phase 3).** Candidates:
   - **Media3/AudioTrack** — managed-side pipeline; simpler, shares the Phase 1
     playback stack; tempo/pitch and multi-deck sync feasibility to be proven.
   - **Oboe/native (C++)** — low-latency native audio; better fit for
     tempo/pitch/effects DSP and tight beat-sync, at the cost of an NDK build and
     a native audio graph.
2. **Profile sync without CloudKit.** Deferred for now (device-local profiles). A
   future **S3-backed sync** (per-profile documents under an authenticated prefix)
   is the sketched direction — undesigned, unscheduled.
3. **Distribution channel.** Play Console internal testing vs direct APK sideload
   for Levi's devices — decide before the first phase ships a build worth
   installing.
