# Mix Tab — On-Device Tempo / Pitch / Beat-Match Prototype Spec

> **⚠️ UPDATE (2026-06-26): SHIPPED.** Real tempo-shift, pitch-shift, sample-accurate seek, and
> grid-aware beat-matching now ship on the Mix tab — built on a **first-party `AVAudioEngine`
> graph** (`apple/PocketDJ/Mix/MixEngine.swift`), NOT the vendored Switchboard SDK (which was
> removed). The beat-grid indexer this spec calls for also shipped. Per-deck **stem decks** were
> added on top. For the as-built system see the Architecture Book
> [Ch. 4 §7 "The Mix engine"](../architecture/04-performance-engine.md). The text below is
> preserved as the original research plan; the shipped implementation differs (e.g. node order,
> first-party vs. Switchboard) — follow the architecture book + code for current reality.

> **Status: research / not yet built.** Captured 2026-06-25 from the `mix-dsp-prototype`
> multi-agent workflow (5 agents, ~384k tokens). The Mix tab currently ships the *controllable
> subset* only (load · play/pause · volume · crossfader · effects · rewind) because the vendored
> Switchboard 3.2.3 `AdvancedAudioPlayer` exposes no tempo/pitch/seek/sync through its string API.
> This is the build-ready plan for bringing real tempo-shift, pitch-shift, and beat-matching back,
> backed by a beat-grid indexer over the rip corpus. Revisit when we choose to invest in it.

On-device tempo-shift, pitch-shift, and beat-matching for the Mix tab, backed by a beat-grid
mix-analysis indexer over the rip corpus.

## 1. Verdict & recommended architecture

**Primary path: replace the Switchboard player backend with a first-party two-deck `AVAudioEngine`
graph that does tempo/pitch/seek/beat-phase LIVE.** Keep `MixEngine`'s public API identical so
`MixView` / `MixResolver` / `MixWaveform` / `BurnStore` are untouched; only the Switchboard string
calls inside the engine are swapped for typed nodes.

Justification against the hard constraints:

- The constraints prove the Switchboard 3.2.3 player is a dead end for the goal:
  `tempo`/`playbackRate`/`pitchShiftCents`/`position`/`setBeatGridInformation`/`playSynchronized`
  all return "not a valid key/action"; the C++ `setPlaybackRate`/`setSyncModeTempoAndBeat` exist
  but are unbridged; newer SDKs are 403/gated. So **whatever we build, the actual tempo/pitch/seek
  DSP has to come from outside the Switchboard player.** Every research path agrees on this.
- Given that, the decisive question is: do we keep Switchboard for transport and bake tempo into
  files **offline** (runner-up), or do we use `AVAudioEngine` for **live** transport and drop
  Switchboard? Both paths require writing an `AVAudioEngine` + `AVAudioUnitTimePitch` pipeline. The
  live path's only marginal cost over the offline path is the transport/graph wiring — and in
  exchange it **deletes an entire SDK** (no Superpowered license key, no
  `switchboard-credentials.json`, no string-bridge fragility, no `MixAudioGraph.json`, no
  `fetch-switchboard.sh` universal-xcframework merge).
- The live path delivers the **whole goal directly**, where offline degrades each piece:
  - **Arbitrary seek** — `playerNode.scheduleSegment(file, startingFrame:…)` is sample-accurate.
    This also fixes two existing bugs for free: the `restart()` re-open-to-0:00 hack, and the
    analog shared-album `startMs` window (currently impossible without seek).
  - **Live tempo/pitch** — `AVAudioUnitTimePitch.rate`/`.pitch` re-stretch smoothly mid-play with
    the playhead preserved. Offline must re-render + re-open on every change, which resets the deck
    to 0:00 and **loses beat phase** on every lead-tempo drag.
  - **Sample-accurate beat-phase** — both decks share one render clock; scheduling the follower at
    `AVAudioTime(sampleTime: targetDownbeatSampleTime)` locks downbeats to the sample. Offline is
    only ~one-render-quantum accurate (~10 ms) for any mid-song drop-in and relies on nudge cleanup.
- Effects survive natively: Reverb→`AVAudioUnitReverb`, Filter→`AVAudioUnitEQ` single-band,
  Compressor→`AVAudioUnitEffect`(DynamicsProcessor). The crossfader/volume equal-power law ports
  1:1 onto `AVAudioPlayerNode.volume`.

**Runner-up: offline pre-render** (server-side via a rip-server `/render` endpoint, or on-device
`AVAudioEngine.enableManualRenderingMode(.offline)` → `TimePitch` → temp file → load). It produces
a higher-quality stretch (can use RubberBand / high `overlap`) and offloads CPU. **Switch to it if**
on-device validation shows (a) audible `AVAudioUnitTimePitch` artifacts in the tempo range Levi
actually mixes, or (b) two live `TimePitch` chains can't sustain low-latency playback on the oldest
target device. The offline path can also serve as the **PoC shortcut** to hear beats lock before
committing to the full live-graph rewrite. Trade-off accepted in that mode: no live lead-tempo
tracking (static match + manual re-sync), render latency + temp-file churn before each play.

**Distant third: newer Switchboard SDK (3.2.4+/4.x).** Requires a licensed Synervoz dashboard
credential (public S3 is 403), a new Superpowered license arrangement, and re-deriving the macOS
`Versions/Current` symlink fix-up. Even in the best case it just "lights up" the existing no-op
string calls. Not worth the licensing dependency when AVFoundation is free and sandbox-friendly.
Only revisit if Apple's DSP quality becomes a blocker AND a license is already in hand.

The beat-grid indexer (Section 3) is **path-independent** — both live and offline need the same
`firstDownbeatMs`/`beatGridBpm`/`steady` data — so build it regardless of which engine path ships.

## 2. Architecture diagram

```
                      ┌─────────────────────── OFFLINE (indexer, once per rip) ──────────────────────┐
   rip corpus         │  rips/<id>.mp3 (digital)  /  per-song CUT (analog, cutKey)                   │
   (S3 public)  ──────┤        │                                                                     │
                      │        ▼  Docker pocketdj-audio  →  analyze-beatgrid.py (madmom DBN)         │
                      │   { firstDownbeatMs, beatGridBpm, beatsPerBar, steady, tempoConf, beatsMs[] }│
                      │        │                                                                     │
                      │   scalars → rips/manifest.json entry      arrays → rips/analysis/<id>.json   │
                      └────────┼───────────────────────────────────────────┼─────────────────────-─┘
                               ▼                                            ▼ (lazy, on deck load)
   ┌──────────────────────────────────────────────────────────────────────────────────────────────┐
   │ APP (MixEngine, AVAudioEngine backend)                                                          │
   │                                                                                                 │
   │  songId ──BurnStore.localURLForPlaybackPreferringCut──► AVAudioFile  (mp3→PCM, proven)          │
   │   │                                                         │                                   │
   │   └─RipsStore.ManifestEntry: bpm,firstDownbeatMs,beatGridBpm,steady──┐                          │
   │                                                                      ▼                          │
   │   Lead BPM e_L = B_L·r_L ──► r_F = e_L/B_F (octave-fold, clamp 0.5–2.0)                          │
   │                                                                      │ set TimePitch.rate_F     │
   │  DECK A:  playerNode──TimePitch(rate,pitch)──EQ(filter)──Reverb──Dynamics──┐                    │
   │  DECK B:  playerNode──TimePitch(rate,pitch)──EQ(filter)──Reverb──Dynamics──┤──mainMixer──►out   │
   │             │  scheduleSegment(file, startingFrame=downbeatFrame,          │  (equal-power      │
   │             │                  at: AVAudioTime(sampleTime=T_downbeat))      │   crossfader on    │
   │             ▼                                                              ▼   playerNode.vol)  │
   │     position set = sample-accurate SEEK        beat-locked playback on ONE shared render clock   │
   └──────────────────────────────────────────────────────────────────────────────────────────────┘
```

## 3. The mix-analysis indexer

**Where it goes:** extend the per-song rip path, not the album segmenter. The Mix tab only plays
burned files (one mp3 per digital song, one cut per analog song), and that corpus already flows
through `scripts/lib/audio-analyze.mjs::analyzeAudio()` (Docker `pocketdj-audio` → `analyze-one.py`)
→ rip-server `analyzeManifestSong` → S3 manifest. The album `audio_index.py` stays untouched.

**What it computes** (new `analyze-beatgrid.py` mode, or `--beatgrid` flag on `analyze-one.py`;
**lazy-import madmom** so it can't destabilize the proven key/BPM path):

- Per-beat + downbeat timestamps via madmom `RNNDownBeatProcessor` →
  `DBNDownBeatTrackingProcessor(beats_per_bar=[3,4], fps=100)`. (librosa, line 52 today, gives beats
  but **no** downbeat — madmom is the only joint beat+bar-position option in-image.)
- `beatsMs[]`, `downbeatsMs[]` (subset where bar-position==1), `firstBeatMs = beatsMs[0]`,
  `firstDownbeatMs = downbeatsMs[0]` (the phase reference), `beatsPerBar` (default 4).
- `beatGridBpm` = median of `60000/IBI` (robust to stray detections); least-squares fit
  `beat_n ≈ firstBeatMs + n·period`, report `gridResidualMs` (RMS).
- `tempoVar` = std-dev of instantaneous BPM. `tempoConfidence` = blend of madmom-vs-librosa BPM
  agreement + low residual. `steady = (gridResidualMs < ~25 && tempoVar < ~1.5)`. Octave-fold into
  a DJ range (70–180) using downbeat spacing to kill 2×/0.5× errors.
- Key/camelot: reuse the existing Krumhansl-Schmuckler chroma path unchanged.

**Output — two tiers** (mirrors the existing waveform-PNG sidecar so `manifest.json`, which every
client downloads whole and the server holds in memory and rewrites on every rip, stays lean):

- **Manifest scalars** added to `ManifestEntry`: `firstBeatMs:int`, `firstDownbeatMs:int`,
  `beatGridBpm:double`, `beatsPerBar:int`, `tempoConfidence:double`, `tempoVar:double`,
  `steady:bool`, `beatgrid:string` (sidecar key), `analysisVersion:int`. Keep existing
  bpm/musicalKey/camelot/waveform/startMs/durationMs.
- **Sidecar** `rips/analysis/<id>.json` on the public bucket:
  `{ version, analyzer, beatsMs[], downbeatsMs[], beatPhase[], …scalars }`. Fetched **lazily** when
  a deck loads, exactly like `rips/waveforms/<id>.png`. A `steady` song needs only the manifest
  scalars; the sidecar is for per-beat overlay or live tracks.

**Wiring (all additive):**

- `scripts/lib/audio-analyze.mjs`: add a `withBeatgrid` opt → run the beatgrid script, upload
  `rips/analysis/<id>.json`, return the scalars + sidecar key alongside today's
  `{ bpm, musicalKey, camelot, waveform }`.
- `scripts/rip-server.mjs::analyzeManifestSong`: copy the scalars onto every manifest entry sharing
  `ent.key` (it already loops); bump `analysisVersion`. **Analog: run the grid on the per-song CUT
  (`cutKey`), not the whole-side mp3**, so `firstDownbeatMs` is cut-relative == the burned file the
  deck opens. This couples beat-grid backfill to cuts existing (`/backfill-cuts`).
- `POST /analysis`: accept + merge the new fields, so the `analyze-rip.mjs` batch tool passes them
  through for free.
- New `POST /backfill-beatgrids`: re-enqueue every entry with `analysisVersion < CURRENT` through
  the existing durable conc-1 queue (download mp3/cut, run grid only, skip re-uploading the
  waveform) — mirror `/backfill-cuts`, idempotent/resumable. New rips need zero change:
  `enqueueAnalysis` already fires after every rip.

**App ingestion:** add the optional fields to `RipsStore.ManifestEntry` (all-optional `Decodable` =
back-compat). In the Mix path, **prefer the rips manifest grid over the catalog** (it's measured on
the exact burned file the deck opens), falling back to catalog `bpm`. Feed the real `firstDownbeatMs`
into the engine instead of the hardcoded `0.0`. Lazily fetch the sidecar on load for a beat-tick
overlay on `MixWaveform`.

## 4. The on-device engine

**Per-deck graph** (one shared `AVAudioEngine`, deck ∈ {A, B}):

```
AVAudioPlayerNode → AVAudioUnitTimePitch → AVAudioUnitEQ(1-band filter)
                  → AVAudioUnitReverb → AVAudioUnitEffect(DynamicsProcessor)
                  → engine.mainMixerNode → engine.outputNode
```

**Concrete APIs / types:**

- `AVAudioFile(forReading: handle.url)` — `.processingFormat` is PCM, already proven decoding burned
  mp3s in `MixWaveform.swift`. Source the URL via `BurnStore.localURLForPlaybackPreferringCut` (held
  security scope; mirror `releaseA`/`releaseB`/`pathA`/`pathB`).
- `AVAudioPlayerNode.scheduleSegment(_:startingFrame:frameCount:at:completionHandler:)` — the
  linchpin. `startingFrame = ms/1000 * sampleRate` = arbitrary seek. `at: AVAudioTime(sampleTime:
  atRate:)` = shared-clock scheduling.
- `AVAudioUnitTimePitch` — `.rate` (independent time-stretch, default 1.0), `.pitch` (cents =
  semitones·100), `.overlap` (quality knob). The default for BPM matching (pitch held).
  `AVAudioUnitVarispeed` kept available only as an optional "vinyl mode" (rate+pitch coupled).
- `AVAudioPlayerNode.playerTime(forNodeTime:)` / `engine.outputNode.lastRenderTime` — read the lead
  playhead in engine-timeline samples.
- Effects toggle via `node.bypass`. `AVAudioUnitEQ` single band with `.lowPass`/`.highPass`/
  `.bandPass` for the DJ filter sweep. Compressor via `AVAudioUnit.instantiate(with:
  AudioComponentDescription(kAudioUnitSubType_DynamicsProcessor))`.

**Control realization (each maps to an existing `MixEngine` method body — signatures unchanged):**

| Control | Realization |
|---|---|
| Tempo (`setRate`, 0.5–2.0) | write `timePitch[deck].rate` — live, smooth |
| Pitch (`setPitch`, semitones) | write `timePitch[deck].pitch = semitones * 100` |
| Volume + Crossfader (`setCrossfader`/`applyMixGains`) | port the equal-power cosine law verbatim onto `playerNode[deck].volume` (AVAudioMixing) |
| Effect toggle (`setEffect`) | `node.bypass = !enabled` on Reverb / EQ / Dynamics |
| Load / seek (`load`) | `AVAudioFile` + `scheduleSegment(startingFrame: startMsFrame, frameCount: lengthFrames)` — fixes the analog `startMs` window TODO |
| Restart (`restart`) | re-`scheduleSegment(startingFrame: downbeatFrame)` — no re-open hack |
| Loop | re-schedule in the completion handler (avoids a 40–60 MB/deck full-song PCM buffer) |

**MixEngine changes:** drop `import SwitchboardSDK`/`SwitchboardSuperpowered`, the
`SwitchboardRuntime` bootstrap, `MixAudioGraph.json`, and the credentials/fetch-switchboard
dependency. Replace the Switchboard string calls inside each method with the typed-node operations
above. Re-add the Lead/Sync/rate/pitch scaffolding that the current file's NOTE says is intentionally
absent — `leadDeck`/`setLead`/`isLead`, `syncToLead`/`rematchFollower`/`followActive`,
`rateRange`/`setRate`(lead-aware)/`applyRate`, `pitchRange`/`setPitch`/`applyPitch` — but wire them
to the nodes, not to no-op `setValue`. Threading: scheduling is thread-safe but completion handlers
fire on an internal queue — mirror `PlayerEngine`'s `MainActor.assumeIsolated`. iOS only:
`AVAudioSession(.playback)` + `preferredIOBufferDuration` (already configured in `PlayerEngine`);
macOS needs none. **Flanger is the one gap** (no stock AU): approximate with `AVAudioUnitDelay`
(static comb), build a tiny AUv3 LFO, or drop it (1 of 4 effects).

## 5. Beat-matching

**Notation (per deck X):** `B_X` = grid BPM (manifest `beatGridBpm`, fall back to catalog), `r_X` =
tempo multiplier, `e_X = B_X·r_X` = effective BPM, period `p_X = 60000/e_X` ms,
`bar_X = beatsPerBar·p_X`, `f_X = firstDownbeatMs`, `sr` = sample rate.

**(a) Tempo match** follower F to lead L:
```
r_F = e_L / B_F = (B_L · r_L) / B_F
```
Clamp to `rateRange` 0.5…2.0; if outside, octave-fold `B_F` (×2 or ÷2) until in range = half/double-
time match. After this `e_F == e_L` → equal beat periods.

**(b) Phase-align downbeats (the live win — no head-trim, no re-render):**
1. Read lead playhead: `leadSample = playerL.playerTime(forNodeTime: lastRenderTime).sampleTime`
   (engine-timeline samples).
2. Map lead song-position → engine time. Lead downbeats are at song-position `d_n = f_L + n·bar_L`
   ms. Because `TimePitch.rate = r_L` makes output advance `r_L×` faster, a source interval `Δm`
   maps to `Δm/r_L` of engine time. Convert `leadSample` back to a lead song-position, find the
   **next** downbeat `d_k` strictly in the future, and compute its engine `sampleTime` `T`.
3. Schedule the follower from its own downbeat at that instant:
```swift
playerF.scheduleSegment(fileF,
    startingFrame: AVAudioFramePosition(f_F/1000 * sr),
    frameCount: …,
    at: AVAudioTime(sampleTime: T, atRate: sr))   // rate_F already = r_F
```
Equal periods + coincident downbeat-0 on the shared render clock ⇒ **every later downbeat coincides,
sample-accurate** — including a true mid-song drop-in, which the offline path cannot do.

**(c) Stay locked as the lead tempo changes:** on a lead-rate drag while `followActive`, recompute
`r_F' = (B_L·r_L')/B_F` and **write `timePitch[F].rate = r_F'` live** — `TimePitch` re-stretches
without resetting the playhead, so phase is preserved smoothly. (This is the regime the offline path
can't reach; it would have to re-render + re-cue and lose phase.) Optionally re-issue a small phase
correction if drift accrues.

**(d) Nudge (manual drift trim):** momentary rate trim — holding `+ε` for `τ` ms advances the
follower by `≈ε·τ` ms (retard with `-ε`); to correct a measured drift `d`, hold `τ = d/ε` (e.g.
`d=40ms, ε=0.04 → 1s`). Ship a one-shot `±10–20 ms` pulse (briefly perturb `rate_F` then restore)
plus a hold-to-bend. For a sample-exact correction, re-`scheduleSegment` the follower with a shifted
`startingFrame` at a buffer boundary.

**UX flow:** designate **Lead** (exclusive, `setLead`) → load decks in any order → **Sync** computes
`r_F` (octave-fold + clamp), writes the rate, phase-aligns via `scheduleSegment(at:)` → **Lead · Sync
· Nudge± · Reset** row (re-add `MixView` `tempoControls`/`rateSlider`/`pitchSlider`, a11y ids
`deck-A-lead/-sync/-restart/-rate/-pitch`). **Gate Sync on `steady`** — for non-steady (live/rubato)
tracks, disable or show a "drift likely" warning (single-ratio match only holds on click-track-steady
material). Offer a **manual tap-downbeat** as the fallback when the grid lands on the wrong
beat-of-bar or octave.

## 6. Smallest end-to-end PoC

Minimal vertical slice: **one deck pair, one transform (tempo-match), two tracks — hear the beats
lock.** No EQ/reverb/compressor/crossfader/loop. To avoid the indexer blocking engine work, hardcode
`firstDownbeatMs`/`beatGridBpm` for two known steady test tracks first, then wire the real indexer.

File-by-file:

1. **`.claude/skills/analog-indexer/audio/analyze-beatgrid.py`** *(new)* — madmom DBN (or
   librosa-beat + spectral-flux downbeat fallback) printing `{ firstDownbeatMs, beatGridBpm,
   beatsPerBar, steady }` for one input file. For the PoC, run it manually on the two test mp3s; no
   Docker/queue wiring required yet.
2. **`apple/PocketDJ/Mix/MixDeckEngine.swift`** *(new, throwaway)* — one `AVAudioEngine`; two
   `(AVAudioPlayerNode → AVAudioUnitTimePitch) → mainMixerNode`. Methods: `load(_ deck, url,
   startFrame)`, `setRate(_ deck, _ rate)`, `playBothLocked(leadDownbeatFrame:followDownbeatFrame:)`
   using the shared-clock `scheduleSegment(at:)` from §5(b). ~120 lines; copy the
   `AVAudioFile`/`AVAudioPCMBuffer` decode loop from `MixWaveform.swift`.
3. **`apple/PocketDJ/State/RipsStore.swift`** — add optional `firstDownbeatMs`, `beatGridBpm`,
   `steady` to `ManifestEntry` (or, for the very first cut, pass them as launch-arg constants and
   skip this).
4. **`apple/PocketDJ/Mix/MixView.swift`** — a temporary "Lock & Play" debug button bound to two
   hardcoded loadable song ids, calling `MixDeckEngine.load(A)`, `load(B)`, `setRate(B, bpmA/bpmB)`,
   `playBothLocked(...)`.

**Proof of success:** A and B play with B time-stretched to A's BPM, both scheduled from their
`firstDownbeatFrame` on the shared clock → audibly phase-locked. Validate by ear and/or a
click/metronome overlay on `MixWaveform`. This isolates the one risky claim (shared-render-clock
sample-accurate beat-phase) before the full graph + indexer build.

## 7. Effort & risks

**Effort (S/M/L):**

| Component | Size |
|---|---|
| Beat-grid indexer: madmom script + `withBeatgrid` in audio-analyze.mjs + ~8 manifest fields + `analyzeManifestSong` copy + `/backfill-beatgrids` | **M** (S if librosa-fallback; madmom install is the variable) |
| Native two-deck graph: transport + tempo/pitch/seek + crossfader + 3 effects behind the unchanged `MixEngine` API | **M** |
| Sample-accurate beat-phase sync (shared-clock `scheduleSegment(at:)` math + lead-tempo live re-match) | **M–L** |
| Swift ingest: `ManifestEntry` fields → `MixLoadable`/`LoadedTrack` grid sourcing + lazy sidecar fetch + beat-tick overlay | **S–M** |
| Lead/Sync/Nudge UX (re-add scaffolding + controls) | **S** |
| Flanger native (delay approx) | **S** (or drop) |
| Remove Switchboard SDK/credentials/graph json | **S** |

Overall **L**, but incrementally shippable: tempo+pitch+seek first (immediately beats Switchboard
3.2.x and fixes the seek bugs), beat-phase sync + flanger after.

**Top risks:**

1. **Beat-grid octave/downbeat errors** corrupt the match ratio and `steady`. Mitigate:
   madmom-vs-librosa BPM cross-check, octave-fold into the DJ range using downbeat spacing, manual
   tap-downbeat fallback.
2. **madmom licensing** — its pretrained models are non-commercial/academic; a shipping-app risk.
   Fallback: librosa `beat_track` + spectral-flux downbeat heuristic (lower downbeat accuracy). The
   DBN tracker is the *only* madmom dependency, so it's swappable.
3. **`AVAudioUnitTimePitch` quality/CPU** — two live TimePitch chains are the heaviest nodes;
   validate on the oldest target device early. Escape hatch: the offline-render runner-up.
4. **MainActor / completion-handler threading** — scheduling is thread-safe but completions fire on
   an internal queue; mirror `PlayerEngine`'s `MainActor.assumeIsolated`.
5. **Engine-internals rewrite with identical public API** — every `MixEngine` body changes; the
   existing Mix UI tests (a11y ids) are the safety net against regressing crossfader/effects. Don't
   put a11y ids on button containers (per prior toolbar-overflow lesson).
6. **`firstDownbeatMs` timeline mismatch** for analog — must be measured on the per-song cut, not the
   whole side; couples to `/backfill-cuts`. Digital lines up since the burned file == `rips/<id>.mp3`.

## 8. Open questions for Levi

- Drop Switchboard from the Mix tab entirely, or keep it as the shipping player and gate the native
  engine behind a flag until validated? (Recommend: commit to native, but land tempo/pitch/seek
  before beat-sync.)
- **Flanger**: delay-based approximation, a small AUv3 LFO, or drop it?
- **madmom acceptable** given the non-commercial model license, or require a librosa-only downbeat
  heuristic from day one?
- Is the **shared-start** lock (both decks from downbeat-0) enough for v1, or is **mid-song drop-in**
  (sync the follower onto the lead's *next* downbeat while the lead is already playing) required?
- Oldest **target device** to validate two live TimePitch chains against?
- Want a **"vinyl mode"** (Varispeed, tempo+pitch coupled) as a toggle, or pure independent
  time-stretch only?
