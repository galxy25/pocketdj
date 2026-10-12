# Mix tab — the audio graph

The Mix decks' `AVAudioEngine` graph as built by `MixEngine.ensureEngine()`
(`apple/PocketDJ/Mix/MixEngine.swift`). Built **once**, never rewired at runtime — the FX rack
changes sounds by flipping node bypass flags, never by reconnecting (see
`mix-sessions-and-controls-spec.md` §1a). A slick SVG rendering of this diagram lives beside this
file (`mix-audio-graph.svg`).

```
                                DECK A (identical for DECK B)
┌──────────────────────────────────────────────────────────────────────────────────┐
│                                                                                  │
│  player ────────────┐    ← AVAudioPlayerNode; player→inputMixer is the ONLY      │
│  (main file)        │      link reconnected per load (at the FILE's format)      │
│   ⇅ HANDOVER: main ↔ stems cross at ONE host time (60 ms linear fade, voice      │
│     gains on the source nodes) — never a stop-then-start; see "Zero dead air"    │
│                     ▼                                                            │
│  stem "vocals" ─→ inputMixer ─→ timePitch ─→ SLOT 0 ─→ SLOT 1 ─→ SLOT 2 ─→ SLOT 3│
│  stem "drums"  ─→   (mixer      (tempo/     ┌─────────────────────────┐          │
│  stem "bass"   ─→    up/down-    pitch)     │ each slot = 4 nodes,    │          │
│  stem "other"  ─→    mixes to               │ wired in series:        │          │
│                      canonical              │  comp → filter →        │          │
│                      44.1k stereo)          │  reverb → mod(delay)    │          │
│                                             │ at most ONE un-bypassed │          │
│                                             └─────────────────────────┘          │
│                                                        │                         │
│                                                        ▼                         │
│                                    eq3 (3-band Low/Mid/High, always active)      │
│                                                        │                         │
│                                                        ▼                         │
│                                    trim (band bypassed; carries the >100%        │
│                                          volume boost as globalGain)             │
│                                          ├── VU tap: PRE-fader ──→ MixDeckLevels │
│                                     ┌────┴────┐                                  │
│                                     ▼         ▼                                  │
│                                 mainGain    cueGain   ← the channel-strip split  │
│                                 (vol ×      (cueVol,                             │
│                                  crossfade)  only while cued)                    │
│                                  ├─ VU tap: POST-fader → MixDeckLevels           │
└─────────────────────────────────┼────────────┼──────────────────────────────────┘
                                  │            │
              deck B mainGain ──→ │            │ ←── deck B cueGain
                                  ▼            │
                               houseSum        │      ← recording tap here (clean
                                  │            │        stereo house, pre-pan)
                                  ▼            │
                               housePan        │      ← pans house L/R only while
                                  │            │        a deck is cued (PFL split)
                                  ▼            ▼
                               mainMixerNode ◄─┘
                                  │
                                  ▼
                               limiter (PeakLimiter — catches 2×200% decks)
                                  │
                                  ▼
                               outputNode (device)
```

## Stage-by-stage

| Stage | Node type | What it does |
|---|---|---|
| **player** | `AVAudioPlayerNode` | Plays the deck's single burned file — or, in STREAMING mode, the same file while it is still downloading (`MixStreamLoader` → `loadStreaming`/`pumpStream`): segments up to the byte frontier, each appended from a fresh `AVAudioFile` open of the growing mp3 (bit-identical to one segment), with the playhead HELD at the frontier on an underrun. `player → inputMixer` is the ONLY link ever reconnected (per load — for a stream, when its header first lands — at the file's real format), so a mono / 48 kHz / odd file never reconfigures a live AU downstream — which AVAudioEngine asserts-and-crashes on. |
| **stem players ×4** | `AVAudioPlayerNode` | vocals / drums / bass / other, summing into the SAME `inputMixer` so stems ride the deck's whole chain (tempo, pitch, FX, fader, cue) exactly like the main file. Idle unless stem mode wires real files — burned stems, or (STREAMING) four growing part files from `MixStreamLoader.openStems`, appended in lockstep (the same seconds range on every part) up to the shortest part's frontier. Each node's `volume` = per-stem balance × the handover voice gain. |
| **inputMixer** | `AVAudioMixerNode` | The format normalizer: up/down-mixes and resamples whatever arrives into canonical 44.1 kHz stereo. Everything downstream is pinned at canonical FOR LIFE. |
| **timePitch** | `AVAudioUnitTimePitch` | Tempo (0.5–2.0×, pitch preserved) and pitch (±12 st, tempo preserved). The last pre-FX point in the chain — the natural place for a pre-FX analysis tap. |
| **slots 0–3** | 4 × `SlotNodes` | The FX rack. Each slot pre-allocates one node of every effect type — `comp` (DynamicsProcessor AU), `filter` (1-band `AVAudioUnitEQ`), `reverb` (`AVAudioUnitReverb`), `mod` (`AVAudioUnitDelay`) — wired in series with at most ONE un-bypassed. Swapping a slot's effect = bypass flips only. Duplicates across slots are legal (two filters, etc.). 16 FX nodes per deck. |
| **eq3** | `AVAudioUnitEQ` (3 bands) | The always-active channel-strip EQ (Low shelf 320 Hz / Mid peak 1 kHz / High shelf 3.2 kHz, ±12 dB knobs under the pitch slider). Not part of the rack — never bypassed, never swapped. |
| **trim** | `AVAudioUnitEQ` (1 band, band bypassed) | Exists purely to carry the >100% volume boost as `globalGain` (0 dB at ≤100% → +6 dB at 200%). Upstream of the main/cue split so the cue monitor's boost divide-out stays exact. Pre-rack this gain rode the filter node; the rack made that impossible (a rack may hold no filter). |
| **mainGain** | `AVAudioMixerNode` | The channel fader: deck volume (clamped ≤1.0) × the equal-power crossfade factor. What the audience hears. |
| **cueGain** | `AVAudioMixerNode` | The PFL send: full-strength copy at the independent `cueVol`, non-zero only while the deck is cued. Divides the trim boost back out so the monitor level is exactly `cueVol`. |
| **houseSum** | `AVAudioMixerNode` | Both decks' main sends summed — the clean stereo house mix. The recording tap lives HERE, before any cue panning, so captures are always normal stereo even mid-PFL. |
| **housePan** | `AVAudioMixerNode` | Pans the house hard left/right only while a deck is cued (the physical monitor split); centered otherwise, so an un-cued mix is bit-identical stereo. |
| **mainMixerNode** | engine main mixer | House (via housePan) + both cue sends merge here. |
| **limiter** | PeakLimiter AU | Master safety net: two decks at up to 200% plus compressor makeup can sum past 0 dBFS; the limiter catches those peaks so the boost feature can't hard-clip. Transparent below threshold. |

### Taps (read-only observers; never modify audio)

| Tap | On | Feeds | Notes |
|---|---|---|---|
| Pre-fader VU | `trim` output | `MixDeckLevels.prePeak/preRMS` | 4096-frame buffers (~10 Hz); peak + RMS ballistics run on the tap thread. **Post-FX** despite the "pre-fader" name. |
| Post-fader VU | `mainGain` output | `MixDeckLevels.postPeak/postRMS` | Same shape, after volume × crossfade. |
| Envelope follower | `inputMixer` output | `MixDeckEnvelope.value` | **Pre-FX** (a filter driven by it can't hear itself and feed back), post-stem-merge. 1024-frame buffers (~23 ms) with time-constant ballistics (8 ms attack / 180 ms release) so the host's delivered buffer size can't change the follower's speed. Drives the FX modulation's audio-reactive source. |
| Recording | `houseSum` output | `MixTapSink` + `MixTapPulse` liveness | Installed once at build, never per-recording — adding/removing a tap on a live node pauses the decks on-device. |

## Zero dead air — the stem handover

**Cardinal rule:** the on-air deck never goes silent because of an *engine* transition. Which of
a deck's two sources renders — the full-mix `player` or the 4 stem players — is a HANDOVER,
decided in one place (`MixEngine.advanceStemHandover`):

```
                 setStemMode(true)                       stems wired + runway ≥ 4 s
   FULL MIX ─────────────────────────▶ PENDING .toStems ─────────────────────────────▶ STEMS
  (player)   ◀── toggle off / fetch      ("Loading stems…";   (or complete files        (4 nodes)
     ▲            fails / new track /     full mix plays on)   covering the playhead)       │
     │            eject: request drops                                                      │
     │                                                                                      │
     │        full mix has runway at the playhead           setStemMode(false)              │
     └──────────────────────────────── PENDING .toFullMix ◀─────────────────────────────────┘
                                         ("Loading full mix…"; stems play on)
```

- **The switch itself** (`cutToStems` / `cutToFullMix`): on an audibly-playing deck the incoming
  voice is scheduled from the OUTGOING voice's render-clock position projected to a host time
  ~60 ms out, started there with `play(at:)` at gain 0, and the two cross linearly over 60 ms
  (linear, not equal-power: stems sum back to the mix, so the voices are coherent). Only then is
  the outgoing voice stopped. A silent deck (paused, cued, or HELD for bytes) switches outright.
  Every transport path that stops/re-schedules voices `settleStemFade`s first.
- **Sources across streaming:** stems not on disk STREAM (`MixStreamLoader.openStems`, public
  objects, all four together, adopted into the burn folder when done) or are fetched whole
  (`stemFetcher`). A streaming source that runs dry hands over to the other one when it has audio:
  partial stems hand back to the full mix `stemUnderrunLead` (1 s) before their frontier and
  re-engage with 4 s of runway; a HELD full mix is rescued by stems that have runway. A deck HOLDS
  (Buffering…) only when neither source has audio at the playhead.
- **Generations:** `stemIntentGen` is bumped by every request, track change and eject; a fetch
  completing for a superseded request touches nothing. Fade steps check `stemFadeGen`.

## Known limitations

- **The graph is write-once.** No node is ever attached/detached/reconnected while running; the
  only full-rebuild path is the iOS media-services-reset recovery, which stops playback first.
  Anything needing new topology (new taps, new nodes) must be added at build time.
- **One tap per node bus.** `trim`, `mainGain`, and (since the FX modulation) `inputMixer` each
  carry theirs; a new consumer of those points must share the existing callback, not add a
  second tap. `timePitch`'s output remains the one untapped per-deck point.
- **The "pre-fader" VU tap is post-FX.** Fine for metering; wrong as a source for anything that
  *drives* the effects. The envelope follower therefore taps `inputMixer` (pre-FX) instead.
- **All parameter changes are host-rate one-shot sets** from the main actor (`applySlot` /
  `writeSlotParams`, the ~10 Hz Auto-DJ glide tick, the ~60 Hz modulation tick). No
  `AudioUnitScheduleParameters`, no sample-accurate ramps. With the default IO buffer this caps
  effective modulation at ~45 updates/s — the reason LFO rates stop at 1/8. Fast modulation of
  most params is fine, but **`AVAudioUnitDelay.delayTime` never moves at tick rate** (un-ramped
  read-pointer jump = clicks; `writeSlotParams` derives it from the BASE strength only) — so
  Flanger/Chorus remain static combs whose *wet/feedback* pump rhythmically; a true swept
  flanger still needs audio-rate DSP.
- **No custom real-time node in the Mix graph.** The app's only custom RT DSP lives behind the
  Studio arranger's `AVAudioSourceNode` (`MultitrackPlayer.swift`). A custom v3 `AUAudioUnit` was
  tried there and FAILED to instantiate on device ("only gain worked", removed in c6dfc926) — do
  not reach for that again. A source node can't be dropped into this player-push chain without
  rearchitecting deck playback.
- **`loadFactoryPreset` rebuilds the reverb tail** — call it only on an actual variant change,
  never per tick.
- **Beat-grid coverage is partial**: measured grids (`beatsMs`/`downbeatsMs`) come from the rips
  sidecars and are only auto-downloaded when Beat pulse is on (or a loop forces it); Studio items
  have beats but no downbeats; profile items have neither (catalog BPM only). Anything beat-locked
  needs the synthesized-lattice fallback (`60/bpm` anchored at `firstDownbeatMs`).
- **Streaming decks are file decks with a moving end.** While a deck streams, `endFrames` is the
  downloaded frontier, so seek/loop/restart/stems-off can only reach audio that has landed (a seek
  past it holds at the target until the bytes arrive). The frame↔byte map trusts the LAME/Xing
  full-length header of our 256 kbps CBR rips; a headerless file plays only once complete. An
  analog song without a fetchable per-song cut streams its whole album side up to `startMs`.
- **Handover alignment is render-clock accurate, not sample-locked.** The incoming voice starts
  at the outgoing voice's projected source position for the start host time; at a non-1.0×
  tempo the projection rides the time-stretch's rate, so expect sub-buffer (≈ms) error, hidden
  under the 60 ms crossfade. A handover on a LOOPING deck re-arms the loop on the new voices
  (the pre-handover re-schedule, a brief gap) instead of crossfading.
- **Stem streams are not range-windowed.** Stems stream whole (≈4 × 8 MB for a 4-minute song)
  alongside the deck's own stream; on a slow link they compete for bandwidth with the on-air
  full mix. The full mix still plays first-come (the handover waits), but its own runway can
  shrink while stems download.
