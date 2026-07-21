# PocketDJ — Architecture (Android)

> **LIVING DOCUMENT.** This is the plan-and-progress record for the Android port,
> updated as each phase is implemented. Today **nothing is implemented** — every
> section below is marked *Status: Planned (Phase N)*. When a phase lands, its
> sections flip to *Built* with the same per-component honesty as the
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

### Ch. 1 — Foundations · *Status: Planned (Phase 1)*
Android consumes the shared entities, the files-as-API spine, and the
content-derived ids **unchanged** — no Android-side id minting, no new document
shapes. The client stack (decision 2) and catalog plumbing (decision 5) land here:
fetch + disk-cache the catalog documents, decode with kotlinx.serialization, render
art with Coil.

### Ch. 2 — Ingest & Enrichment · *Status: Shared backend — no Android work*
All ingest/enrichment runs on the iMac + cloud workers and publishes to S3; Android
only ever reads the outputs. Nothing to port. (Client-visible enrichment fields —
bpm/key/beat grids/lyrics — arrive with the catalog in Phase 1.)

### Ch. 3 — Catalog & Data Model · *Status: Planned (Phase 1 catalog · Phase 2 collections)*
Phase 1: the read-side catalog model + the offline-first disk cache (decision 5).
Phase 2: the collections document (pockets/playlists/setlists) and the favorites
document — **device-local only** at first, since there is no CloudKit on Android;
cross-device profile sync is deferred (open question: S3-backed sync).

### Ch. 4 — Performance Engine · *Status: Planned (Phase 2 realize · Phase 3 Mix · Phase 4 Producer)*
Phase 2: pockets → playlists → setlists and the `realize()` engine over the shared
collection shapes. Phase 3: the two-deck **Mix** engine — the DSP substrate
(Media3/AudioTrack vs Oboe/native) is chosen at the start of this phase. Phase 4:
the **Producer** (Studio) surfaces.

### Ch. 5 — Playback & Rip-on-Demand · *Status: Planned (Phase 1 core · later phases grow it)*
Phase 1: Media3/ExoPlayer + MediaSession playback (decision 4) of public rips/burns
and rip-on-demand against the unchanged rip-server API — remembering the sources
reality: an AM-only track with no public rip is metadata-only on Android. Offline
burns, setlist transport, and stem playback follow with the phases that need them
(Playlists → Mix → Producer). Android Auto lands after phone playback is solid, as
the CarPlay-parity step.

### Ch. 6 — Search & Discovery · *Status: Planned (Phase 1)*
The **Browser** tab (browse kinds, filters, online aoss search through the same
CloudFront proxy) and **History** are Phase 1 scope. The web star map is a
PWA-only surface — no Android port planned.

### Ch. 7 — Distribution & Clients · *Status: Planned (Phase 1 skeleton)*
The Gradle root under `android/` (decisions 1–3) is the Phase 1 skeleton.
**Jukebox Hero** (the app as DJ against the unchanged broker API) is Phase 1 scope.
The distribution channel (Play internal testing vs direct APK — the TestFlight
analogue) is an open question. Apple-specific system surfaces (widgets, App
Intents/Siri, CloudKit profiles, MusicKit favorites sync) have **no Android
counterpart planned yet**; they are listed here so their absence is a recorded
decision, not an oversight.

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
