# Performance tab ("Studio") — samples, loops, step sequencer, virtual instruments, cue points

**Status: design complete — being built on `feat/performance-tab` (2026-07-05).**

A new top-level **Performance** tab in the native app (iPhone / iPad / macOS) for making and
performing with your own material: record **samples** from any indexed track or the microphone,
slice beat-grid-synced **loops**, program a 16-step **sequencer**, play seven **virtual
instruments** from a MIDI keyboard (with recorded takes rendered to a musical score you can
replay or export as PDF/MIDI), and set per-track **cue points** that start playback where you
tapped. Samples, loops, and sequences become collection items (pockets / playlists), and each
family gets its own configurable storage location in Settings ▸ Storage. Instrument sound banks
download from S3 for offline use.

This is a **native-only** feature (like Mix). The PWA degrades gracefully (see §8).

---

## 0. Naming — the collision table

The obvious names are all taken. These choices are deliberate; do not "fix" them:

| Concept | NOT this (taken) | Use this |
|---|---|---|
| Feature folder | `PocketDJ/Performance/` (realize engine) | `PocketDJ/Studio/` |
| Tab enum case | — | `RootView.Section.performance = "Performance"` (rawValue persisted; never rename) |
| A type called `Performance` | taken by RealizeEngine.swift:44 | `Studio*` prefix on all new types |
| 16-step sequence | `sequence` = playlist chapter (PlaylistNode.Kind); `sequencer` = RootView's SetlistPlayer env name | **`StudioPattern`** in code/schema; user-facing label "Sequencer" / "sequence" is fine in UI copy |
| Instrument recording | `performance` = reserved PocketKind (AI crate) | **`StudioTake`** |
| Keyboard shortcut ⌘P | Playlists (RootView:239), Browse play-focused (BrowseView:307) | ⌘P → Performance. Playlists → **⇧⌘P**. Browse play-focused → **⌥⌘P** |

Sub-tab shortcuts ⌘1–⌘5 are **scoped inside PerformanceView** (BrowseView shadow-button
pattern, mounted-only) so they never fight Browse's ⌘1/⌘2.

## 1. Sub-tabs

`PerformanceView` hosts a segmented `Picker` (a11y id `studio-tab-picker`) + hidden shadow
buttons, persisted in `SettingsStore.studioTab` (optional String):

1. **Samples** (⌘1) — create from track region or mic; rename / delete / trim / FX / tempo / pitch / volume
2. **Loops** (⌘2) — beat-grid-synced slices of samples at ½,1,2,4,8,16,32 beats; save / rename / delete; looped audition
3. **Sequencer** (⌘3) — 16-step grid over sample/loop rows; BPM; play/stop; name / save / delete patterns
4. **Instruments** (⌘4) — MIDI virtual instruments, pack downloads, take recording, score view + PDF/MIDI export
5. **Cues** (⌘5) — up to 8 cue points per indexed track; tap to play from cue; set / name / nudge / delete

## 2. Data model (`Studio/StudioModels.swift`, persisted by `StudioStore`)

One versioned lenient document `pocketdj-studio.json` in Application Support
(MixSessionStore shape: schemaVersion, off-main writer, `flush()`, `launchURL()` PDJ_USE_FIXTURE seam,
`reconcileOnLaunch`). Id prefixes minted like CollectionsFactory: `smp_`, `lp_`, `ptn_`, `tk_` + uuid.

- **StudioSample** `{id, name, fileName, wasUserFolder, createdAt, durationMs, source, grid?, edit}`
  - `source`: `.track(songId, startMs, endMs)` | `.mic` | `.take(takeId)`
  - `grid?`: inherited beat grid `{bpm, firstDownbeatMs, beatsMs[]}` — offset-shifted from the
    parent track's `analysis-<songId>.json` so ms are relative to the *sample's* 0:00; nil for mic
    samples unless later tapped
  - `edit` (non-destructive, applied at playback + baked on export/loop-render):
    `{trimStartMs, trimEndMs, gainDb, rate (0.5–2.0), pitchSemitones (±12), reverbWet, delayWet}`
- **StudioLoop** `{id, name, sampleId, anchorMs, beats (LoopBeats enum ½|1|2|4|8|16|32), bpm,
  lengthMs, fileName, wasUserFolder, createdAt}` — rendered to its own audio file at save time
  (edits baked) so it plays standalone/offline and loops seamlessly from a PCM buffer.
- **StudioPattern** `{id, name, bpm (default 120), rows: [{targetId (smp_|lp_), steps: [Bool]×16,
  gainDb}], fileName? (bounce), bounceDirty, wasUserFolder, createdAt}` — bounced to audio on
  demand (collection playback), re-rendered when edited.
- **StudioTake** `{id, name, instrument (InstrumentKey), fileName (audio), bpm (quantize target),
  events: [{onMs, offMs, note, velocity}], wasUserFolder, createdAt, durationMs}`
- **StudioCue** `{id, songId, slot (0–7), positionMs, name?}` — max 8 per songId, enforced by store.
- **InstrumentKey** enum: `piano, violin, bassGuitar, acousticGuitar, trumpet, clarinet, harp`
  (GM programs 0, 40, 33, 25, 56, 71, 46).

## 3. Storage (`Studio/StudioFolders.swift`, Settings ▸ Storage)

SessionFolders generalized: app roots `Application Support/studio/{samples,loops,sequences,takes,instruments}/`;
optional user folders via three new security-scoped bookmarks in SettingsStore —
`samplesFolderBookmark`, `loopsFolderBookmark`, `sequencesFolderBookmark` (optional SettingsData
fields; takes live with samples root; instrument packs are app-managed, re-downloadable).
Every artifact records `wasUserFolder` and resolves against the root it was written to.
Deterministic names: `sample-<id>.m4a`, `loop-<id>.m4a`, `pattern-<id>.m4a`, `take-<id>.m4a`,
`instrument-<packId>.sf2`. StorageView gains: three folder pickers (burn/session-folder section
pattern), usage rows per family, delete-all per family. **User-created studio content is never
auto-pruned** (session-recordings doctrine); open files join `protectedSongIds`-style guards.

## 4. Audio engines (all first-party AVFoundation; MixEngine hardening contract)

Every engine: `@MainActor @Observable`, app-scoped `@State` in PocketDJApp.init, lazy
`ensureEngine()`, canonical 44.1k stereo pinning, `startEngineIfNeeded()` before every
`play()`, interruption/route-change/media-reset observers (iOS) + per-instance
`.AVAudioEngineConfigurationChange`, tick watchdog + zombie-node `pause()+play()` re-prime,
intent-vs-node state split, MixDiag logging, NowPlayingArbiter claim/guard/resign when audible.

- **StudioEngine** (`Studio/StudioEngine.swift`) — one graph, three duties:
  - *Sample audition*: player → timePitch → EQ(globalGain) → reverb → delay → mixer (MixEngine
    deck-chain subset), edit params applied live.
  - *Loop audition*: decode loop file to an exact-frame `AVAudioPCMBuffer`, `scheduleBuffer(...,
    options: .loops)` for seamless looping.
  - *Pattern playback*: per-row voice nodes; steps scheduled sample-accurately with
    `scheduleBuffer(at: AVAudioTime)` against a pattern-start anchor (StemPlayer shared-start
    pattern); step dur = 60/bpm/4 s (16 steps = 4 beats × 16ths… **no**: 16 steps = one bar of
    16ths at 4/4 ⇒ step = beat/4). Loop the 16-step window by scheduling ahead (2-bar horizon).
- **StudioRender** (`Studio/StudioRender.swift`) — greenfield offline bounce:
  `AVAudioEngine.enableManualRenderingMode(.offline)`; bakes sample edits, renders loop regions,
  bounces patterns; writes AAC .m4a via the MixTapSink AVAssetWriter recipe (fragmented, failure
  latched, never retry startWriting).
- **StudioMicRecorder** (`Studio/StudioMicRecorder.swift`) — own small engine; `inputNode` tap →
  deep-copy → private queue → AVAssetWriter .m4a; permission via
  `AVAudioApplication.requestRecordPermission` (Shazam pattern, explicit `.denied` state);
  iOS session `.playAndRecord` **only while recording**, restore `.playback` after; MixRecorder
  lifecycle (activeTake, orphan recovery, RecordingExitBridge finalize, stall watchdog).
  project.yml mic usage string reworded to cover sampling.
- **InstrumentEngine** (`Studio/InstrumentEngine.swift`) — `AVAudioUnitSampler` →
  mixer (+ permanent tap for take capture, flag-gated); loads the downloaded SoundFont with
  `loadSoundBankInstrument(at:program:bankMSB:0x79→melodic 0x00:bankLSB:0)`; CoreMIDI client +
  input port (greenfield; wired/network MIDI, no entitlement needed), note on/off → sampler +
  event log when recording; on-screen piano keys as fallback input (and the UI-test seam);
  take = audio (tap→writer) + timed MIDI events.

## 5. Beat math (`Support/BeatMath.swift`)

Extract MixView's private `lastBeat` binary search + `isDownbeat` (±30 ms) into shared
`nonisolated` statics; add `sliceBoundaries(anchorMs:beats:grid:)` returning `[anchor,
anchor+len]` stepped through real `beatsMs` (constant-grid synthesis fallback from
`bpm + firstDownbeatMs` when the array is empty — BeatPulseView's fallback). Loop length in ms =
sum of the actual inter-beat intervals (handles tempo drift), not `beats × 60000/bpm`, when a
real grid exists. Unit-tested pure functions.

## 6. Virtual-instrument packs on S3

- Layout (public `rips/` prefix is mandatory — bucket policy):
  - `rips/instruments/index.json` — `{version, sharedBanks: [{key, bytes, sha256}], packs:
    [{id, name, instrument, program, bankKey, bytes}]}`
  - `rips/instruments/banks/generaluser-gs-2.0.3.sf2` (32 MB GM bank, GeneralUser GS — license
    permits redistribution; attribution string shown in the Instruments pack screen)
- v1 ships seven packs (one per instrument) all referencing the shared bank; download dedupes by
  `bankKey` so the second pack is instant. Manifest supports per-pack banks later.
- Client (`Studio/InstrumentPacks.swift`): index fetched like CatalogService (explicit file
  cache, offline-first); bank download via **file-based `URLSession.downloadTask`** (never
  in-memory Data — 32 MB), progress published, atomic move into `studio/instruments/`,
  existence-check idempotent (BurnStore stems trio shape: `localBank → bankDownloaded →
  downloadBank`). Delete per pack/bank in Storage + Instruments UI. `Config.instrumentsIndexURL`
  + `Config.instrumentsBase` added next to ripsBase.
- Upload is done from the dev machine (`aws --profile levi`, us-west-2), never from the app.

## 7. Score, replay, export (Instruments)

- **ScoreModel/ScoreQuantizer** (`Studio/ScoreModel.swift`): quantize take events to 16ths at
  `take.bpm` (4/4); durations snapped to {16th, 8th, quarter, half, whole, + dotted}; chords =
  same-onset notes; rests fill gaps; measures paginate. Pure, unit-tested.
- **ScoreView**: SwiftUI Canvas — grand staff for piano/harp, single treble (violin/trumpet/
  clarinet/acoustic guitar; guitar sounds 8vb, notated at pitch v1), bass clef for bass guitar;
  note heads/stems/flags, ledger lines, sharps for black keys. Replay button plays the take's
  events back through InstrumentEngine (not the audio file) so the score and sound line up.
- **SMFWriter** (`Studio/SMFWriter.swift`): type-0 Standard MIDI File, PPQ 480, tempo meta from
  bpm, program-change from InstrumentKey, note on/off from raw (unquantized) events. Pure bytes,
  unit-tested against a hand-decoded fixture.
- **ScorePDF** (`Studio/ScorePDF.swift`): CGContext PDF pagination of the score (not
  ImageRenderer rasters — text stays vector). Both exports via `.fileExporter` (sandbox-safe).
- "Use as sample": one tap creates a `StudioSample(source: .take(id))` from the take's audio.

## 8. Collections integration (schema v5)

- **Mechanism: namespaced ids riding existing string arrays** (`smp_…`/`lp_…`/`ptn_…` inside
  `Pocket.songIds` and `PlaylistNode(kind: .song, songId:)`). Old native builds and the PWA
  degrade to a "missing" row — no decode failure, no data loss. (A new `PlaylistNode.Kind` would
  wipe playlists on older builds: synthesized-Codable trap.)
- Also shipped now (hygiene, enables future kinds): lenient `PlaylistNode.init(from:)` (unknown
  kind ⇒ drop node, not the list), `collectionsSchemaVersion = 5` + no-op migration. Mirror the
  lenient guard note in `src/types/collections.ts` comments (web already degrades).
- `AddToCollectionView.Item` gains `.studio(id, title)`; add-to paths reuse `addSong`-shaped
  string-id plumbing.
- Resolution seams wired in PocketDJApp.init:
  - `SetlistPlayer.playCurrent` branch: studio prefix ⇒ `studio.localURLForPlayback(id)` →
    shared `playLocalFile` (scope release honored).
  - `CollectionsStore.playNow`/`songIds(...)` keep studio ids (injected `isStudioId`/lookup
    closure) instead of dropping non-catalog ids.
  - `CollectionCatalog` gains an optional `extra: [String: (title, lengthMs)]` so counts/runtime
    include studio items.
  - `CollectionsStore.makeCtx()` injects synthetic `IndexSong.minimal` entries for studio items
    that carry bpm (+camelot inherited from parent track) so realize/harmonics can place loops;
    realize contract itself untouched.
  - SetlistDetailView/row UI: kind badge (Sample/Loop/Sequence) derived from id prefix.
- Zips/exports: studio items travel as ids only (like song refs); media stays device-local
  (documented; matches "only metadata + art travel").

## 9. Cue points

- Store: `StudioCue` rows in the studio document (max 8/song; slot-indexed for stable colors).
- UI (`CuesView`): track picker (search field over AppModel songs, recent/burned first);
  timeline with the song's S3 waveform PNG when available (`rips/waveforms/<songId>.png`);
  8 slot buttons — tap = play from cue, ⋯/long-press = set-at-playhead, rename, nudge ±,
  delete. "Set cue at current position" while auditioning.
- Playback: resolves like SongDetail play — burned local file first (analog: cue ms is
  song-relative; add song `startMs` for shared album files), else stream via
  PlaybackCoordinator with initial seek. Uses PlayerEngine (already supports `startMs` +
  end boundaries); no Mix-deck integration in v1.

## 10. Shell / navigation

- `RootView.Section` + icon (`"pianokeys"` SF symbol) + detail case + `Performance-shadow`
  ⌘P button; Playlists-shadow → ⇧⌘P; BrowseView PlayFocused-shadow → ⌥⌘P.
- PDJ_START_SECTION="Performance" works automatically; new UI-test seams:
  `PDJ_SEED_STUDIO=1` (seeds fixture sample/loop/pattern/cue rows + a bundled ~1 s audio
  fixture), StudioFolders.appRootOverride, StudioStore.launchURL.
- iPhone: critical controls in-content (never toolbar-only — overflow lesson); narrow sliders
  use the fixed-width popover pattern.
- a11y ids on leaf controls only: `studio-tab-picker`, `sample-row-<id>`, `sample-new-from-track`,
  `sample-record-mic`, `loop-slice-<beats>`, `seq-step-<row>-<col>`, `seq-play`,
  `instrument-<key>`, `pack-download-<id>`, `score-export-pdf`, `score-export-midi`,
  `cue-slot-<n>`, `storage-samples-folder-choose`, ….

## 11. Out of scope (v1, stated honestly in the books)

Bluetooth-LE MIDI (needs new entitlements), beat-grid analysis of mic samples (tap-tempo only),
Mix-deck cue integration, PWA Studio UI, TransferCoordinator-managed pack downloads (packs are
32 MB; foreground file download is strictly better than the shipped in-memory stems path — the
background-session upgrade path is documented), velocity-sensitive on-screen keys, MusicKit/
Apple-Music-DRM sources for samples (rips-manifest sources only).

## 12. Test plan

Unit: BeatMathTests, StudioStoreTests (CRUD/persist/lenient/reconcile/cue-max-8),
SMFWriterTests, ScoreQuantizerTests, StudioPatternTests (step timing math),
CollectionsStudioTests (v5 migration, lenient node decode, playNow retention, catalog counts),
SettingsStudioTests (bookmark back-compat), InstrumentPacksTests (manifest decode, GM mapping).
UI: PerformanceUITests (tab + sub-tab nav incl. ⌘1..⌘5 on macOS via typeKey, seeded rows,
rename/delete flows, cue slots, storage sections) — iOS-deep, macOS empty-state per convention.
Full matrix run before merge (shell/infra files touched).
