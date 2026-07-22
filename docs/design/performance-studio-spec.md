# Performance tab ("Studio") — samples, loops, step sequencer, virtual instruments, cue points

**Status: SHIPPED on `feat/performance-tab` (2026-07-05). The code is authoritative; this spec is the design record (Appendix #30 doctrine).**

A new top-level **Performance** tab in the native app (iPhone / iPad / macOS) for making and
performing with your own material: record **samples** from any indexed track or the microphone,
slice beat-grid-synced **loops**, program a 16-step **sequencer**, play seven **virtual
instruments** from a MIDI keyboard (with recorded takes rendered to a musical score you can
replay or export as PDF/MIDI), and set per-track **cue points** that start playback where you
tapped. Samples, loops, and sequences become collection items (pockets / playlists), and each
family gets its own configurable storage location in Settings ▸ Storage. Instrument sound banks
download from S3 for offline use.

This is a **native-only** feature (like Mix). The PWA degrades gracefully (see §8).

Rev 2 incorporates a three-lens adversarial design review (audio engineering, data safety,
product). Where this spec is prescriptive about mechanisms, the prescription is load-bearing —
each one closes a reviewed defect.

---

## 0. Naming — the collision table

The obvious names are all taken. These choices are deliberate; do not "fix" them:

| Concept | NOT this (taken) | Use this |
|---|---|---|
| Feature folder | `PocketDJ/Performance/` (realize engine) | `PocketDJ/Studio/` |
| Tab enum case | — | `RootView.Section.performance = "Performance"` (rawValue persisted; never rename) |
| A type called `Performance` | taken by RealizeEngine.swift:44 | `Studio*` prefix on all new types |
| 16-step sequence | `sequence` = playlist chapter (PlaylistNode.Kind); `sequencer` = RootView's SetlistPlayer env name | **`StudioPattern`** in code/schema; user-facing label "Sequencer" |
| Instrument recording | `performance` = reserved PocketKind (AI crate) | **`StudioTake`** |
| Keyboard shortcut ⌘P | Playlists (RootView:239), Browse play-focused (BrowseView:307) | ⌘P → Performance. Browse play-focused → **⌥⌘P**. (The Collections tab — formerly Playlists, ⇧⌘P — has since moved to its own **⌘C**.) |

Sub-tab shortcuts ⌘1–⌘5 are **scoped inside PerformanceView** (BrowseView shadow-button
pattern, mounted-only) so they never fight Browse's ⌘1/⌘2.

## 1. Sub-tabs

`PerformanceView` hosts a segmented `Picker` (a11y id `studio-tab-picker`) + hidden shadow
buttons, persisted in `SettingsStore.studioTab` (optional String). On compact width (iPhone
portrait) segments are **SF-symbol-only** (waveform / repeat / square.grid.4x3.fill / pianokeys /
flag) — five text labels truncate; regular width shows symbol + text.

1. **Samples** (⌘1) — create from track region or mic; rename / delete / trim / FX / tempo / pitch / volume
2. **Loops** (⌘2) — beat-grid-synced slices of samples at ½,1,2,4,8,16,32 beats; save / rename / delete; looped audition
3. **Sequencer** (⌘3) — 16-step grid over sample/loop rows; BPM; play/stop; name / save / delete patterns
4. **Instruments** (⌘4) — MIDI virtual instruments, pack downloads, take recording (click + count-in), score view + PDF/MIDI export
5. **Cues** (⌘5) — up to 8 cue points per indexed track; tap to play from cue; set / name / nudge / delete

## 2. Data model (`Studio/StudioModels.swift`, persisted by `StudioStore`)

One versioned lenient document `pocketdj-studio.json` in Application Support. Store shape:
schemaVersion + off-main versioned writer + `flush()` + `launchURL()` PDJ_USE_FIXTURE seam
(MixSessionStore persistence shape) **plus** a `reconcileOnLaunch` whose semantics come from
**BurnStore.reconcileOnLaunch (BurnStore.swift:765)**: resolve every artifact against the root
it was *actually written to* (`wasUserFolder`), drop a record only when its file is **provably**
gone from a **reachable** root; when a user root is unreachable (unplugged drive / offline
provider), **skip — never prune**. Dangling cross-references are flagged, never deleted.
Id prefixes minted like CollectionsFactory: `smp_`, `lp_`, `ptn_`, `tk_` + uuid.

- **StudioSample** `{id, name, fileName, wasUserFolder, createdAt, durationMs, source, grid?, edit}`
  - `source`: `.track(songId, startMs, endMs)` | `.mic` | `.take(takeId)` — **"Use as sample"
    from a take COPIES the audio file**; the sample never depends on the take file existing.
  - `grid?`: `{bpm, firstDownbeatMs, beatsMs[]}` — track samples inherit it offset-shifted from
    the parent track's `analysis-<songId>.json` (ms relative to the *sample's* 0:00); take
    samples inherit a constant grid from `take.bpm` with `firstDownbeatMs = 0` (recording starts
    on beat 1 after count-in); mic samples start nil and gain a constant grid via the
    **tap-tempo / manual-BPM affordance** (sample detail + Loops empty state, a11y ids
    `sample-tap-tempo`, `sample-bpm-field`).
  - `edit` (non-destructive, applied at audition + baked on render):
    `{trimStartMs, trimEndMs, gainDb, rate (0.5–2.0), pitchSemitones (±12), reverbWet, delayWet}`
- **StudioLoop** `{id, name, sampleId, anchorMs, beats (LoopBeats ½|1|2|4|8|16|32), bpm,
  lengthMs, frames (Int64, authoritative), fileName, wasUserFolder, createdAt}` — rendered at
  save time to **LPCM CAF** (`loop-<id>.caf`) with edits baked, so it plays standalone/offline
  and loops seamlessly (AAC priming/padding makes m4a loop files tick at the seam — hence CAF +
  authoritative frame count; audition trims/pads the decoded buffer to exactly `frames`).
  Loops are **self-contained after render**: deleting the parent sample leaves the loop playable
  (re-slicing is disabled and the row shows a "source removed" note).
- **StudioPattern** `{id, name, bpm (default 120), rows: [{targetId (smp_|lp_), steps: [Bool]×16,
  gainDb}], fileName? (bounce, `pattern-<id>.m4a`), bounceDirty, wasUserFolder, createdAt}` —
  bounced on demand; re-marked dirty on any edit. Rows whose target was deleted render as muted
  "missing" rows and are **skipped by playback and bounce** (never a throw). A pattern with zero
  sounding steps refuses to bounce/play with an inline notice (zero-frame schedules crash).
- **StudioTake** `{id, name, instrument (InstrumentKey), fileName (audio, app-managed),
  bpm (click/quantize target), events: [{onMs, offMs, note, velocity}] (ms from beat 1 =
  end of count-in), durationMs, createdAt}`
- **StudioCue** `{id, songId, slot (0–7), positionMs, name?}` — max 8 per songId, store-enforced.
- **InstrumentKey** enum: `piano, violin, bassGuitar, acousticGuitar, trumpet, clarinet, harp`
  (GM programs 0, 40, 33, 25, 56, 71, 46).

Deleting a sample shows a confirmation that lists referencing loops ("N loops keep playing but
can't be re-sliced") and pattern rows ("M pattern rows will be muted"). StudioStoreTests cover
delete-with-referrers, cue max-8, lenient decode, and reconcile-with-unreachable-root.

## 3. Storage (`Studio/StudioFolders.swift`, Settings ▸ Storage)

SessionFolders generalized. App-managed roots: `Application Support/studio/{samples,loops,
sequences,takes,instruments}/`. Three user-relocatable families via new optional security-scoped
bookmarks in SettingsStore — `samplesFolderBookmark`, `loopsFolderBookmark`,
`sequencesFolderBookmark` (optional SettingsData fields, back-compat decode). **Takes and
instrument packs are always app-managed** (takes under `studio/takes/`, packs under
`studio/instruments/`) — no bookmark, no ambiguity about which root a take resolves against.
Every artifact records `wasUserFolder` and resolves against the root it was written to.

Deterministic names: `sample-<id>.m4a`, `loop-<id>.caf`, `pattern-<id>.m4a`, `take-<id>.m4a`,
`instrument-<slug>.sf2`. Per-family usage/delete operations filter **strictly** by the family's
exact filename shape AND a document-known id (BurnStore.ownsAuxFile discipline) so co-located or
user files are never counted or swept. Delete-all per family: runs mic-take orphan recovery
first, skips the recorder's active take, keeps records whose user root is unreachable
(MixSessionStore.deleteAllRecordings doctrine).

StorageView gains: three folder pickers (burn/session-folder section pattern), usage rows per
family (samples / loops / sequences / takes / instrument packs), delete-all per family.
**User-created studio content is never auto-pruned** (session-recordings doctrine); files an
engine holds open join the `protectedSongIds`-style guards. Packs are re-downloadable but still
not LRP-pruned in v1 (delete via UI only).

## 4. Audio engines (first-party AVFoundation; MixEngine hardening contract)

Every engine: `@MainActor @Observable`, app-scoped `@State` in PocketDJApp.init, lazy
`ensureEngine()`, `startEngineIfNeeded()` before every `play()`, interruption/route-change/
media-reset observers (iOS) + per-instance `.AVAudioEngineConfigurationChange`, tick watchdog +
zombie-node `pause()+play()` re-prime, intent-vs-node state split, MixDiag logging,
NowPlayingArbiter claim/guard/resign when audible. Canonical-format pinning applies to
**playback graphs downstream of their normalizer mixers** — explicitly NOT to the mic engine's
input side (see below).

- **StudioEngine** (`Studio/StudioEngine.swift`) — one graph, three duties:
  - *Sample audition*: `player → inputMixer (AVAudioMixerNode format normalizer) → timePitch →
    EQ(globalGain) → reverb → delay → mainMixer`. Everything downstream of inputMixer is
    connected **once** at canonical 44.1k stereo for life; only the player→inputMixer link is
    reconnected per load at the file's processingFormat, with the player stopped (MixEngine
    loadFile contract — studio files are guaranteed heterogeneous: mic captures are hw-format,
    typically 48 kHz mono).
  - *Loop audition*: decode `loop-<id>.caf` fully to PCM, trim/pad to the authoritative
    `frames`, `scheduleBuffer(..., options: .loops)`.
  - *Pattern playback*: each row's sounding buffer is **pre-rendered by StudioRender with edits
    baked** (like loop files) so the scheduled path is plain `rowPlayer → rowGain → mainMixer`
    with **no live AU latency**. One player node per row with
    `scheduleBuffer(at:options:.interrupts)` = classic mono-choke step-sequencer semantics
    (a retrigger cuts the ringing hit). Steps scheduled sample-accurately against a pattern-start
    `AVAudioTime` anchor; step duration = 60/bpm/4 s (one bar of 16ths in 4/4); a 1-bar
    scheduling horizon re-armed each loop pass. Covered by StudioPatternTests (step-time math,
    choke, missing-target skip).
- **StudioRender** (`Studio/StudioRender.swift`) — greenfield offline bounce via
  `AVAudioEngine.enableManualRenderingMode(.offline)`. **Output is written with
  `AVAudioFile(forWriting:settings:)`** (blocking writes — no backpressure; AAC .m4a for
  samples/takes/bounces, LPCM CAF for loops). The MixTapSink AVAssetWriter recipe is
  realtime-only (it drops buffers when the encoder is busy — the common case offline) and MUST
  NOT be used here; only its failure-latch discipline carries over. Render rules:
  - render length = ceil(sourceFrames / rate) **+ FX tail drain** (keep rendering until output
    falls below −60 dBFS or a 3 s cap) for samples/bounces;
  - **loops render to exactly the beat-window frame count** (tails truncated — seams stay clean);
  - the timePitch/AU **priming-latency head is trimmed** so frame 0 of the written file is
    musical frame 0 (otherwise every baked loop starts with silence and beat-sync dies).
- **StudioMicRecorder** (`Studio/StudioMicRecorder.swift`) — own small engine; session
  configured **and activated before** `inputNode` format is read or tapped (0 Hz input format
  ⇒ installTap raises uncatchably); tap runs at the **hardware input format**; deep-copy →
  private queue → AVAssetWriter .m4a (realtime recipe is correct here). iOS session:
  `.playAndRecord, options: [.defaultToSpeaker, .allowBluetoothA2DP]` only while recording,
  restore `.playback` after. **Session coexistence rule**: a process-wide
  `AudioSessionPolicy.micCaptureActive` flag (nonisolated atomic) is set for the take's
  duration; every existing `setCategory(.playback)` call site (MixEngine, PlayerEngine,
  StemPlayer, MixSessionsView's RecordingAudioPlayer) is guarded on it so a playback load /
  setlist auto-advance can't yank the category out from under the live input tap. Permission via
  `AVAudioApplication.requestRecordPermission` (Shazam pattern, explicit `.denied` state).
  MixRecorder lifecycle: activeTake, orphan recovery, RecordingExitBridge finalize, stall
  watchdog. project.yml mic usage string reworded to cover sampling.
- **InstrumentEngine** (`Studio/InstrumentEngine.swift`) — `AVAudioUnitSampler → instrumentMix
  (take-capture tap here, flag-gated) → mainMixer`; a separate **click player joins at
  mainMixer, downstream of the tap**, so the metronome is never recorded into takes. SoundFont
  loading uses `loadSoundBankInstrument(at: bankURL, program: p,
  bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB) /* 0x79 */,
  bankLSB: UInt8(kAUSampler_DefaultBankLSB) /* 0x00 */)` and runs **off the main actor**
  (background task touching only the sampler node) with a visible loading state — the 32 MB bank
  parse would otherwise freeze the UI, including on the media-reset rebuild path.
  - **MIDI threading (load-bearing)**: CoreMIDI receive blocks fire on a CoreMIDI-owned thread.
    The receive block calls `sampler.startNote/stopNote` **directly on that thread** via a
    nonisolated Sendable reference (the AU enqueues events safely) and appends
    packet-timestamped events into an `NSLock`-protected buffer owned by the recorder, gated on
    a pre-latched atomic "recording" flag. `@MainActor` state (key highlights, UI) updates via
    coalesced hops only. Never `Task { @MainActor }` per note (jitter + reordering corrupts the
    event log the score is quantized from).
  - **v1 MIDI scope: wired/USB MIDI devices + the on-screen keys.** Network MIDI (needs
    NSLocalNetworkUsageDescription + NSBonjourServices) and BLE MIDI (new entitlements) are out
    of scope and documented as such.
  - Take recording: click + **1-bar count-in** (both default on, toggleable); event `onMs` is
    measured from beat 1 = end of count-in, which is also ScoreQuantizer's anchor.

## 5. Beat math (`Support/BeatMath.swift`)

Extract MixView's private `lastBeat` binary search + `isDownbeat` (±30 ms) into shared
`nonisolated` statics; add `sliceBoundaries(anchorMs:beats:grid:)` stepping through real
`beatsMs` (constant-grid synthesis fallback from `bpm + firstDownbeatMs` when the array is
empty). Loop length = sum of actual inter-beat intervals when a real grid exists (handles tempo
drift), else `beats × 60000/bpm`. Unit-tested pure functions.

## 6. Virtual-instrument packs on S3

- Layout (public `rips/` prefix is mandatory — bucket policy):
  - `rips/instruments/index.json` — `{version, attribution, sharedBanks: [{key, bytes, sha256}],
    packs: [{id, name, instrument, program, bankKey, bytes}]}`
  - `rips/instruments/banks/generaluser-gs-2.0.3.sf2` (32 MB GM bank, GeneralUser GS — license
    permits free use/distribution; attribution shown in the packs screen)
- v1 ships seven packs (one per instrument) referencing the shared bank; download dedupes by
  `bankKey` so the second pack is instant. Manifest supports per-pack banks later.
- Client (`Studio/InstrumentPacks.swift`): index fetched like CatalogService (explicit file
  cache, offline-first); bank download via **file-based `URLSession.downloadTask`** (never
  in-memory Data), progress published, atomic move into `studio/instruments/`, existence-check
  idempotent (BurnStore stems-trio shape). Delete per bank in Storage + Instruments UI.
  `Config.instrumentsIndexURL` + `Config.instrumentsBase` added next to ripsBase.
- Upload from the dev machine (`aws --profile levi`, us-west-2); the app never writes S3.

## 7. Score, replay, export (Instruments)

- **ScoreQuantizer** (`Studio/ScoreModel.swift`): anchor = beat 1 (end of count-in); quantize
  onsets to 16ths at `take.bpm` (4/4); durations snapped to {16th, 8th, quarter, half, whole,
  dotted variants}; same-onset notes = chords; rests fill gaps; measures paginate. Pure,
  unit-tested.
- **ScoreView**: SwiftUI Canvas — grand staff for piano/harp, single treble for violin/trumpet/
  clarinet/acoustic guitar, bass clef for bass guitar; note heads/stems/flags, ledger lines,
  sharps. Replay plays the take's **events** back through InstrumentEngine (score and sound
  always agree).
- **SMFWriter** (`Studio/SMFWriter.swift`): type-0 SMF, PPQ 480, tempo meta from bpm,
  program-change from InstrumentKey, note on/off from the **raw unquantized** events. Pure
  bytes, unit-tested against a hand-decoded fixture.
- **ScorePDF** (`Studio/ScorePDF.swift`): CGContext PDF pagination (vector, not rasters).
  Both exports via `.fileExporter`.
- "Use as sample": copies the take's audio into a new `StudioSample(source: .take(id))` with a
  constant grid from `take.bpm` — the promised take → sample → loop path.

## 8. Collections integration (schema v5)

- **Mechanism: namespaced ids riding existing string arrays** (`smp_…`/`lp_…`/`ptn_…` inside
  `Pocket.songIds` and `PlaylistNode(kind: .song, songId:)`). No new node kind (a new Kind wipes
  playlists on older builds — synthesized-Codable trap).
- **Lossy lenient decoding, shipped now** (the insurance that makes future kinds safe): a
  per-element lossy array decoder (decode each element into a failable box; failures dropped) at
  **every** `[PlaylistNode]` site — chapter children AND nested `children` recursion — and at
  the `[Playlist]` list itself, so one unknown-kind node drops that node only, never a chapter,
  list, or document. `collectionsSchemaVersion = 5` + no-op migration. Unit tests: unknown kind
  at top level, as a chapter child, and as a nested grandchild — siblings and other playlists
  must survive a decode+save round trip.
- **Per-consumer resolution policy** (the load-bearing table — studio ids behave like text
  nodes for every consumer that talks to money/infra):

  | Consumer | Studio ids |
  |---|---|
  | SetlistPlayer playback, playNow (Now Playing) | **resolved** via StudioStore (local file, scope release) |
  | Counts / runtime subtitles (CollectionCatalog stats) | **included** (title + real lengthMs) |
  | Realize (playlist ▶): node placement | **placed** via synthetic pseudo-songs in ctx.songsById (real lengthMs, bpm/camelot when known) |
  | Realize autofill candidate pool (ctx.candidates) | **never included** — user loops must not appear as harmonic bridges in arbitrary setlists |
  | Rip / Stemify / Burn (collection + setlist buttons) | **excluded** (text-node precedent) — filtered at the consumer boundary |
  | Tracklist CSV export | **excluded** |
  | Browse membership filters, StorageCollectionsView | **excluded** (catalog-only, unchanged) |
  | Zip export/import | ids travel as-is (media stays device-local, documented); import remint leaves unknown-prefix ids untouched |

  Implementation: `CollectionsStore.songIds(...)` keeps catalog-only semantics; a new
  `playableIds(...)` companion (and a CollectionCatalog `studio:` lookup injection for
  `songs(forNode:)`-driven paths) feeds playback/stats. `songIds(forSetlist:)` (currently a raw
  passthrough) gains a studio-prefix exclusion so realized setlists can't leak studio ids into
  Rip/CSV.
- **Defense in depth against the rip-on-demand leak** (old builds + shared server):
  `RipsStore.ripCollection/requestRip/stemify` skip studio-prefixed ids, AND
  `scripts/rip-server.mjs` rejects `smp_|lp_|ptn_|tk_` ids at `/rip`, `/rip-collection`,
  `/stemify` — the server is shared infrastructure across app versions, and an old build's
  play-through-coordinator on a studio row must not trigger a live-search rip into the public
  bucket.
- Realize specifics: synthetic entries are built by a studio-aware helper (IndexSong.minimal
  only takes id/name/artist — it is extended or wrapped to carry **lengthMs (mandatory)**, bpm,
  camelot) so a 4-second loop doesn't realize as 210 s. Engine code is untouched; its
  dedupe-by-songId applies (the same loop appears once per realized set — duplicate hits belong
  in patterns). Known, documented divergence: the PWA's realize drops studio ids (not in its
  catalog), so a seed reproduces different sets on web for playlists containing studio items —
  acceptable for a native-only feature, noted in the books.
- `AddToCollectionView.Item` gains `.studio(id, title)`; add-to paths reuse the string-id
  plumbing. SetlistDetailView rows show a kind badge (Sample/Loop/Sequence) from the id prefix.

## 9. Cue points

- Store: `StudioCue` rows in the studio document (max 8/song; slot-indexed stable colors).
- UI (`CuesView`): track picker (search over AppModel songs; burned first); timeline; 8 slot
  buttons — tap = play from cue, ⋯/long-press = set-at-playhead, rename, nudge ±, delete.
- **Waveform**: digital songs use `entry.waveform` PNG as-is; **analog songs' PNG is the whole
  album side** — crop/scale it horizontally to the song's `[startMs, startMs+durationMs]` window
  (ManifestEntry has both), preferring local peak extraction via the existing MixWaveform
  extractor when the song is burned; no waveform ⇒ plain timeline.
- **Playback plumbing (new, explicit)**: `startMs:` (cue offset) threads through
  `PlaybackCoordinator.play → TrackPlaybackProvider.tryPlay` into both providers:
  - RipServerPlaybackProvider → `rips.play(..., startMs: cue + song.startMs-for-shared-analog)`
    → PlayerEngine.load (already applies startMs to non-live items);
  - AppleMusicPlaybackProvider → play-then-seek via `ApplicationMusicPlayer.playbackTime` once
    playback starts (documented imprecision ~<1 s);
  - a song whose rip is **in flight (live HLS)** cannot seek — cue buttons show a "still
    ripping" disabled state for it.
  - Burned local files (the common case) play exactly: cue ms + `startMs(forSong:)` for shared
    analog album files.

## 10. Samples — creation flows (explicit)

- **From a track** (`sample-new-from-track`): pick a song (search; burned badge shown), then the
  region editor: waveform (local peak extraction when a local file exists), start/end handles,
  in/out mark buttons while auditioning, fine nudge (±10 ms / ±1 beat when grid known); iPhone
  portrait uses the fixed-width-popover pattern for fine controls. Source resolution ladder:
  1. `BurnStore.localURLForPlaybackPreferringCut` (burned) — carve directly;
  2. in rips manifest but not burned — **burn-on-demand** with the StemAuditionPanel phase
     pattern (burning → ready → failed + Retry);
  3. Apple-Music-only (no manifest entry) — explicit "Rip first" state pointing at the existing
     rip flows (stream-through-rip); never a silent dead end.
  Carving = StudioRender trim render (edits start neutral); the sample inherits the beat grid
  window (offset-shifted, only beats inside the region).
- **From the microphone** (`sample-record-mic`): permission → level meter → record/stop →
  named sample; grid nil until tap-tempo/BPM set (§2).
- Sample editor: rename, trim handles, gain, rate, pitch, reverb/delay wets; audition through
  the live chain; **Save bakes nothing** (non-destructive) — rendering happens at loop save,
  pattern use, or collection playback (rendered cache `sample-<id>.m4a`, re-rendered when edits
  change, i.e. an edit-revision stamp on the render).

## 11. Shell / navigation

- `RootView.Section` + icon (`pianokeys`) + detail case + `Performance-shadow` ⌘P;
  Playlists-shadow (the Collections tab) → ⌘C; BrowseView PlayFocused-shadow → ⌥⌘P.
- PDJ_START_SECTION="Performance" works automatically; new seams: `PDJ_SEED_STUDIO=1` (seeds
  fixture sample/loop/pattern/cue rows + bundled ~1 s audio fixture), StudioFolders.appRootOverride,
  StudioStore.launchURL.
- iPhone: critical controls in-content (toolbar-overflow lesson); 16-step grid renders as
  **two rows of 8 steps** on compact width (beat-group separators every 4; single row of 16 on
  regular width) with stable `seq-step-<row>-<col>` ids.
- a11y ids on leaf controls only: `studio-tab-picker`, `sample-row-<id>`, `sample-new-from-track`,
  `sample-record-mic`, `sample-tap-tempo`, `loop-slice-<beats>`, `seq-step-<row>-<col>`,
  `seq-play`, `instrument-<key>`, `pack-download-<id>`, `score-export-pdf`, `score-export-midi`,
  `cue-slot-<n>`, `storage-samples-folder-choose`, ….

## 12. Out of scope (v1, stated honestly in the books)

Network/BLE MIDI, beat-grid *analysis* of mic samples (tap-tempo/manual BPM only), Mix-deck cue
integration, PWA Studio UI, TransferCoordinator-managed pack downloads (32 MB foreground
file-download is strictly better than the shipped in-memory stems path; upgrade path documented),
velocity curves for on-screen keys, sampling Apple-Music-DRM streams (rips-manifest sources
only), LRP-pruning of instrument packs.

## 13. Test plan

Unit: BeatMathTests, StudioStoreTests (CRUD/persist/lossy-decode ×3 depths/reconcile-unreachable/
cue-max-8/delete-with-referrers), SMFWriterTests, ScoreQuantizerTests (anchor + 16th snapping),
StudioPatternTests (step timing, choke policy, missing-target skip, zero-content refusal),
CollectionsStudioTests (v5 migration, per-consumer policy: playable vs songIds vs setlist
exclusion, synthetic-entry lengths, autofill fencing), SettingsStudioTests (bookmark back-compat),
InstrumentPacksTests (manifest decode, GM mapping, bank dedupe). UI: PerformanceUITests (tab +
sub-tab nav incl. ⌘1..⌘5 via typeKey on macOS, seeded rows, rename/delete flows, cue slots,
storage sections) — iOS-deep, macOS empty-state per convention. Full matrix before merge
(shell/infra files touched).
