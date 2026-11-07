# Mix tab — the audio graph

The Mix decks' `AVAudioEngine` graph as built by `MixEngine.ensureEngine()`
(`apple/PocketDJ/Mix/MixEngine.swift`). Built **once**, never rewired at runtime — the FX rack
changes sounds by flipping node bypass flags, never by reconnecting (see
`mix-sessions-and-controls-spec.md` §1a). A slick SVG rendering of this diagram lives beside this
file (`mix-audio-graph.svg`).

**Build vs start (playback-bulletproof P0-3).** `ensureEngine(startNow:)` builds the graph below
(attach, connect, `prepare()`, taps, observers, remote targets). `startNow: false` — used by a
restore's `materializeNow` and by the Mix tab's `prepare()` warm-up — is INERT: no
`AVAudioSession` category/activation and no `engine.start()`, so a parked mix never grabs a
non-mixable session under an out-of-process Apple Music player. The first real transport goes
through `startEngineIfNeeded(by:)`, which sets the `.playback` category on first use, activates the
session and starts the engine (`[session] activate by=mix.start|mix.recover` in the diag log).
Topology is identical either way.

```
                                DECK A (identical for DECK B)
┌──────────────────────────────────────────────────────────────────────────────────┐
│                                                                                  │
│  player ────────────┐    ← AVAudioPlayerNode; player→inputMixer is the ONLY      │
│  (main file)        │      link reconnected per load (at the FILE's format)      │
│   ⇅ HANDOVER: main ↔ stems cross at ONE sample time (60 ms linear fade, voice    │
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
| Envelope follower | `inputMixer` output | `MixDeckEnvelope.value` | **Pre-FX** (a filter driven by it can't hear itself and feed back), post-stem-merge. 1024-frame buffers (~23 ms) with time-constant ballistics (8 ms attack / 180 ms release) so the host's delivered buffer size can't change the follower's speed. Drives the FX modulation's audio-reactive source. The same callback feeds `MixDeckCapture` (a test seam: raw samples while armed, for sample-resolution dead-air / alignment probes). |
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
  voice is scheduled from the OUTGOING voice's source position at a SAMPLE time ~60 ms out on the
  deck's render clock (`stemStartTime`; read off the outgoing player's own clock at that frame),
  started there with `play(at:)` at gain 0, and the two cross linearly over 60 ms (linear, not
  equal-power: stems sum back to the mix, so the voices are coherent). Only then is the outgoing
  voice stopped. A silent deck (paused, cued, or HELD for bytes) switches outright. Every
  transport path that stops/re-schedules voices `settleStemFade`s first.
- **One fade at a time.** While a handover crossfade is in flight `advanceStemHandover` does
  nothing: a toggle (or a pump / seek event) only moves the intent, and the fade's landing re-runs
  the decision. Superseding a fade early — what rapid toggling used to do — settled it first,
  stopping its OUTGOING voice while the incoming one could still be inside its 60 ms start lead:
  up to 60 ms of dead air (`testRapidTogglesLandOnTheLastIntentWithoutDeadAir` now judges this at
  sample resolution, > 2 ms of silence fails). A fade cut short by a transport action (pause, seek,
  stop) re-checks a moved intent once that action finishes (`settleStemFade` defers an
  `advanceStemHandover`), so it is never stranded.
- **Four stems, one frame.** Every stem start (`startStems`, the handover) is ONE sample-time
  `AVAudioTime` for all four nodes — `StemSync.startTogether` / `StemSync.sampleStart`
  (`apple/PocketDJ/Playback/StemSync.swift`, shared by every engine that starts a node group). A host-time start is converted by each node on its own and
  lands them samples apart (measured on a bare engine: node pairs at r 0.80–0.96 instead of 1.0;
  hundreds of samples in the simulator) — four copies summed out of step comb-filter for the
  rest of the song.
- **Encoder priming.** The Demucs stems are lameenc mp3s with no Xing/Info tag, so Core Audio
  can't trim LAME's 576-sample priming granule: they decode 576 samples (13 ms) late against the
  tagged full mix (measured on real stem sets, r 0.9998). `mp3PrimingFrames` reads it off the
  first frame at wiring; every stem frame↔second mapping (`stemFrame` → `StemSync.frame`) skips it.
- **Sources across streaming:** stems not on disk STREAM (`MixStreamLoader.openStems`, public
  objects, all four together, adopted into the burn folder when done) or are fetched whole
  (`stemFetcher`). A streaming source that runs dry hands over to the other one when it has audio:
  partial stems hand back to the full mix `stemUnderrunLead` (1 s) before their frontier and
  re-engage with 4 s of runway; a HELD full mix is rescued by stems that have runway. A deck HOLDS
  (Buffering…) only when neither source has audio at the playhead AND one of them can still grow
  — the pump of whichever grows first resumes it.
- **A dead full-mix stream under stems** is TRUNCATED, not complete (`mainTruncated`): its last
  frame is final, a handover onto it needs real runway, and `mainUnderrun` hands back to the
  stems (or holds for them) before it runs out. Once neither voice can grow
  (`settleDeadSources`), the song ends where the longer one's audio does — the old truncate path,
  so the auto-mix moves on instead of a playhead running over silence.
- **Streaming stems' opens.** The pump re-opens the four parts only on real byte growth (a whole
  append chunk past the scheduled end while on air; 15 s while looping), and ALWAYS keeps the
  newest opens: `stemFrontier` never runs ahead of the files in `stemFiles`, and
  `stemEndSeconds` is the end all four parts really reached. A loop on streaming stems needs the
  whole window inside their frontier. A set adopted into the burn folder is opened there under
  the folder's scope; adoption is all-or-nothing.
- **Transfers nobody wants are cancelled.** A stem stream is cancelled (`cancelStems`) the moment
  no deck wants it — toggled off (or the `.toFullMix` handover landed), track change, eject — and
  runs at low task priority under the song streams. A set is CLAIMED per engine (`openStems` /
  `cancelStems` take an `owner`: `mixStemOwner`, `nowPlayingStemOwner`): when the Mix deck and
  Now Playing joined the same song's set, one letting go only drops its claim — the transfer stops
  when the last holder lets go (a cancel notifies no one, so the other engine would otherwise wait
  on "Loading stems…" forever). A restored stem-mode deck streams/fetches its
  stems only on its first play.
- **Generations:** `stemIntentGen` is bumped by every request, track change and eject; a fetch
  completing for a superseded request touches nothing. Fade steps check `stemFadeGen`.
- **Shared, not copied.** The pure pieces — sample-frame start, voice playhead at a handover
  moment, mp3 priming, the frame↔second map, handover readiness, a partial part's playable
  seconds, fresh opens of a streaming set, the linear crossfade stepper — live in `StemSync`;
  `MixEngine` forwards its old names (`handoverReady`, `mp3PrimingFrames`, …) there. The stem
  stream itself is the one `MixStreamLoader`: Mix listens via `onStemProgress`, any other engine
  via `addStemListener`.

## Zero dead air at the song boundary — Auto-DJ readiness

No graph change: these rules live in the auto machine (`autoFire` / `skipToNext`) and decide
WHEN a crossfade may sweep the fader. Field origin: CarPlay on cellular with a streaming
(ripped-union) mix — the machine crossfaded on the wall clock alone, into a deck still
Buffering…, and a Skip landed on the next buffering song (2026-10-12).

- **Readiness.** `deckReadyToAir` (strict): an on-disk file, a finished stream, or a stream with
  `autoReadyRunway` (15 s) downloaded past its playhead. `deckCanAir` (lenient): not holding.
- **Natural transition.** At the lead window the standby deck must be strictly ready; else an
  unplayed ON-DEVICE upcoming song is PROMOTED into the slot (`promoteReadyUpcoming` — the
  buffering song stays queued right behind it); else the machine waits, the live song playing on.
  With `autoExtendAtSecondsLeft` (0.5 s) left, a lenient-ready standby still goes; with nothing
  able to air, the live song is REPLAYED (`extendLive`) and the transition fires the moment the
  next can air.
- **Frozen fade.** A crossfade whose incoming deck is holding does not advance (the outgoing
  stays fully audible); it resumes, re-timed, when the incoming has runway. The outgoing running
  out meanwhile ⇒ back out (`abandonTransition`) and extend. An incoming deck EJECTED mid-fade
  (its stream died before audio) ⇒ back out; the idle lane picks the next song.
- **Skip.** Prefers a ready song (same promotion). A Skip during a frozen fade is not swallowed:
  it backs out, defers the buffering song to the queue's end, and targets the next one.
- **Stalled live deck.** A live stream frozen on an underrun for `autoStallSkipSeconds` (8 s)
  hands over to a song that can air (1 s fade). Held seconds don't burn the deck's end clock.
- **Stream gate.** A ripped song `canStream` refuses right now (offline / rip-server cooldown /
  recent failure) is DEFERRED, not dropped from the queue (`transientlyUnloadable`); with only
  such songs left, the natural end and Skip keep the live song playing instead of ending the mix.
- **Shuffled start** opens on an on-device song when the queue has one.
- **Trace:** every wait / promote / extend / freeze / abandon / stall-skip / defer decision logs
  one `mixadvance` DiagLog line (always-on lane).

## Now Playing — the same rule on one deck (`NowPlayingDSP`)

The Now Playing mix mini-panel's engine (`apple/PocketDJ/Playback/NowPlayingDSP.swift`) is a
single-deck fork of this deck chain — `player` + 4 stem nodes → `inputMixer` → TimePitch →
comp → EQ → reverb → flanger → limiter — and its stems toggle now follows the same zero-dead-air
handover (`advanceStemHandover` / `cutToStems` / `cutToFullMix`, built on `StemSync`):

- **Intent first.** `setStemMode(true)` refuses (returns false, touches nothing) only when the
  track has no stems anywhere — not burned, not a profile item's, not in the catalog
  (`BurnStore.stemsRemote`). Otherwise it records `.toStems`; stems on disk switch at once (paused)
  or cross over at the playhead (playing); stems not on disk STREAM through the shared
  `MixStreamLoader` stem lane (the panel shows "Loading stems…" next to the toggle) or are
  fetched whole (`stemFetcher` → `BurnStore.burnStems`). The full song plays on meanwhile.
- **The switch** is the Mix deck's: incoming voice scheduled from the outgoing one's exact source
  position, started on one sample frame ~60 ms out at gain 0, 60 ms LINEAR crossfade, outgoing
  stopped when it lands. Paused / not yet rendering: an outright switch.
- **One fade at a time.** While a crossfade is in flight a new toggle only moves the intent; the
  fade's landing re-runs the decision (the Mix deck does the same). A fade cut short by a pause
  re-checks the moved intent right after (an outright switch on the paused song).
- **Streaming stems on air** are appended to all four nodes in lockstep as bytes land (the Mix
  pump's re-open throttle); a 10 Hz monitor (only while partial stems are on air or a handover is
  pending) hands back to the full song `underrunLead` (1 s) before their frontier, keeping the
  request so they re-engage with 4 s of runway. A failed stem stream drops a pending request or
  hands on-air stems back. The full song is a complete local file — OR, in Mix Mode (np-mix-mode
  phase 3), a GROWING one (see "The full song while it downloads" below), so the full song can
  HOLD for bytes too, and the `.toFullMix` path's runway check is live code (a stems → full song
  handover waits for the growing song's runway exactly like the Mix deck's).
- **The full song while it downloads** (`NowPlayingDSP.engageStreaming`, phase 3): the player
  plays a `MixStreamLoader` buffer stream's growing mp3 with the Mix deck's rules, SHARED through
  `GrowingFileSchedule` (`apple/PocketDJ/Playback/GrowingFileSchedule.swift`, beside `StemSync` —
  `MixEngine.pumpStream` and the tick's underrun check call the same functions):
  - unattached until the header is readable (provisional catalog duration), then `player →
    inputMixer` is reconnected ONCE at the file's format (the deck's per-load rule);
  - the voice is NEVER scheduled past the frontier (bytes → frames at the header's byte rate −
    the 1.5 s torn-frame margin); every schedule re-opens the file (an open sees only the bytes
    present at open time) and only a segment that reaches the window's END arms the end handler;
  - a start / resume / seek without runway HOLDS (`isBuffering`: nothing scheduled, playhead
    frozen at `pausedAt`, play intent kept, the ENGINE kept running so the session — and a locked
    phone — stay alive); the loader's song fan-in (`MixStreamLoader.addProgressListener` →
    `pumpMain`) resumes it with 2 s of runway at a track start, 4 s after an underrun / seek;
  - the voice on air gets the next stretch APPENDED from a fresh open (1 s chunks while the runway
    is short, 15 s once comfortable); the 10 Hz monitor also watches a growing song on air and
    holds it `underrunLead` (50 ms) before the end of what it could schedule;
  - a pending stems handover may carry a held song (complete stems start at once);
  - complete: the adopted burn (re-acquired under its scope) replaces the partial — an ordinary
    local file from then on (`onMainStreamFinished`);
  - dead (`failed`): what arrived is FINAL (`mainTruncated`). Stems on air keep carrying (a
    "back to the full song" request is dropped); a full song on air plays to its last frame and a
    held one stops at once — then the row goes back to the host (`onMainStreamFailed`, the plain
    stream) instead of a fake end.
  Every hold / resume stops / reschedules through `stopVoices` (generation first), so a flushed
  frontier segment can never fake an end.
- **The end-of-track generation** (`generation`, guarding `handleReachedEnd` →
  `SetlistPlayer.handleDSPEnded` → advance) is bumped ONLY at a handover's COMMIT — before the
  incoming voice is scheduled (so it captures the new generation), after the outgoing one is known
  to have a successor. Pending requests never touch it, so a request that never lands can't
  swallow the song's real end, and the outgoing voice's flushed completion (stop() fires it) is
  always stale — a toggle can never fake an end and skip the song. Only a stem segment that runs
  to the parts' real end arms the lead stem's end handler; a streaming segment's end is just the
  frontier. Track change (`disengage`) bumps `stemIntentGen`, cancels the fetch/stream/monitor,
  lands any fade.
- **The system stopping the engine.** A route change / sample-rate flip
  (`.AVAudioEngineConfigurationChange`) restarts the song AT its playhead; an interruption
  `.began` pauses there and `.ended` + `.shouldResume` resumes what it paused. With the engine
  stopped `lastRenderTime` is nil, so the playhead is carried by `playAnchor` (the last live
  reading + its host time, projected at the deck's rate) — before, `currentTime` fell back to the
  current segment's START, so a resume (or a pending stem handover acting meanwhile) replayed the
  song from there. A media-services reset (iOS / visionOS) RECREATES the engine and every node
  (`NowPlayingDSP.rebuildAfterMediaReset`, driven by `SetlistPlayer.handleMediaServicesReset`
  after it put the track back on the AVPlayer); the fresh graph builds lazily on the next engage —
  without it, every later engage (each Stem Lock track start) "played" into an orphaned graph.
- **Seek** (`NowPlayingDSP.seek(toSongSeconds:)`): the card / CarPlay / inline scrubber reach the
  DSP through `PlayerEngine`'s external `seek` closure (before, a scrub while engaged hit the idle
  AVPlayer and did nothing). Playing: rescheduled from the target on whichever voice the intent
  asks for and can carry it; past a growing file's frontier it HOLDS at the target.
- **Test seams:** `captureForTesting()` taps `inputMixer` (installed on first use only),
  `stemStartFramesForTesting()`, `setMainFrontierForTesting` / `releaseMainFrontierForTesting`,
  `mainFrontierSecondsForTesting` / `mainScheduledEndSecondsForTesting`,
  `simulateEngineStopForTesting`, `simulateInterruptionForTesting`.

### Stem Lock — carrying the stem set across tracks (Now Playing only)

The lock button (🔒, `np-mix-stem-lock`) beside the panel's Stems toggle turns on **Stem Lock** for
the current playback SESSION (`SetlistPlayer.stemLock`, model in
`apple/PocketDJ/Playback/StemLock.swift`, download lane in `Playback/NowPlayingPrefetch.swift`). No graph topology changes; the Mix tab is untouched.

- **Session scope.** A session is one `SetlistPlayer` run — one `sessionId`. A fresh
  `SetlistPlayer.play(...)` (any new playlist / queue / collection play) mints a new id and clears
  the lock; `stop()` / end-of-set clears it too. Live-queue edits, play-now, skips, jumps, repeats,
  restore and the first ▶ after a restore keep it. Persisted in the durable snapshot
  (`PlaybackSessionStore.Snapshot.stemLock`, optional — no schema bump). Off by default.
- **What carries.** Stems on/off, the muted parts and the per-part gains. The carry is updated
  ONLY by user stem actions (`NowPlayingDSP.onUserStemChange` — the toggle, a pad's mute, a pad's
  gain; the lock's own calls go through `applyStemMode` / `applyCarriedStemControls`, which don't
  notify). Turning the lock on snapshots the current track's state; a mid-track change is what
  carries; turning stems OFF while locked carries "stems off" (the next track plays the plain
  AVPlayer path, as if unlocked). A track that can't do stems never overwrites the carry.
- **Applying it at a track start** (`SetlistPlayer.applyStemLockOnTrackStart`, called right after
  the AVPlayer is handed the new local file — same turn): engage the DSP at the song's top
  (`engageMix(atSeconds:play:)` — the AVPlayer clock hasn't moved yet), set the carried mutes/gains,
  `stemPartsRequired` = the carried ENABLED parts, then `applyStemMode(true)`. Everything after is
  the ordinary zero-dead-air handover above: the FULL MIX plays from the first second; enabled parts
  on disk → crossfade at once; otherwise stream/fetch while "Loading stems…" shows, then cross over.
- **Partial sets.** With `stemPartsRequired` set, the burned-on-disk lane may wire only the enabled
  parts (`BurnStore.localStemPartURLs`), so the switch never waits on a muted part. A part that lands
  later JOINS (`NowPlayingDSP.stemPartsLanded`): on air it's scheduled from the stems' exact playhead
  and started on one sample frame against the rendering group (no `generation` bump — the joining
  node had nothing armed); the pads show a not-yet-landed un-muted part dimmed ("Loading"). A set
  that has to STREAM still streams and waits for all four parts (the stem stream lane is all-or-
  nothing).
- **Unavailable.** Not a local file (a cloud stream, Apple Music, a live capture), no stems
  anywhere, or the DSP refused the file → the full mix plays, `stemLockIndicator == .unavailable`
  (a one-line "Stem Lock · no stems for this track — full mix" under the panel, or in its place when
  the panel is hidden), and the lock carries on to the next track.
- **Download/stream order** (`NowPlayingPrefetcher` in `Playback/NowPlayingPrefetch.swift`, one fetch at a time, only while the lock carries
  stems): ① the playing track's missing ENABLED parts when a partial set is on air; ② the next
  track's WHOLE SONG (through the shared `MixStreamLoader` — a finished stream is adopted as a burn,
  so the boundary plays a local file the DSP can take over; never in device mode); ③ its enabled
  stems in priority **vocals → drums → other → bass** (`BurnStore.burnStemPart`, the same file names
  as a whole-set burn / streamed adoption); ④ the further tracks of the existing 3-track prefetch
  window, each song-then-stems; ⑤ LAST, every MUTED part. Network: Wi-Fi = the whole window;
  cellular = the next track only; Low Data Mode = the next track's song + enabled stems only (muted
  parts skipped); offline = nothing. Each step holds a `PlaybackRunway`. A next track with no stems
  gets one fire-and-forget cloud separation request (`RipsStore.stemify`, owner installs only,
  deduped per song id) — playback never waits on it. A finished analog per-song CUT stream (not
  adopted into the ledger) is played from its local file when the lock wants stems. Lock off →
  nothing beyond the ordinary presign prefetch (no speculative stem fetch).
- **DiagLog** `[stemlock]` lines (also on the `nowplaying` NPLog trace): lock on/off + carry, the
  per-track carry decision (`→ on air` / `full mix first, stems loading` / `UNAVAILABLE (…)`),
  `carry updated mid-track`, `prefetch order net=… a → b → …`, each `prefetch <step> ok|FAILED ms=`,
  cancels, `stemify request`, and `handover song=… full mix → stems after Nms`.
- **Surfaces.** CarPlay / lock screen / widgets show the DSP's card as for any engaged track (one
  card writer). tvOS gets the same lock button (its Now Playing tab reuses `NowPlayingPanel` whole).

### FX Lock — carrying the effects across tracks (Now Playing only)

The 🔒 in the panel's Effects header (`np-mix-fx-lock`, upper right of the header line — placed like the Stem Lock in the Stems header) turns on **FX Lock**
for the session (`SetlistPlayer.fxLock`, `apple/PocketDJ/Playback/FXLock.swift`; full write-up in
`np-mix-mode.md` §10). **No topology change**; it changes PARAMETER SCHEDULING at an engage:

- The carried effects (each effect's on/off + strength) are stamped as the IDLE DSP's control state
  after every `endMixEngagement` (tempo / pitch / gain / stems reset as before), and every engage
  (`engage` / `engageStreaming`) RAMPS the ON effects in: the applied strength is `strength × k`, k
  0 → 1 in 12 main-actor steps over `NowPlayingDSP.fxRampSeconds` (250 ms). At k = 0 every effect is
  transparent (reverb / flanger wet 0, comp threshold 0 dB + makeup 0, LP cutoff ≈ 18 kHz), so the
  node can be un-bypassed at the first sample with no click. A user touch on an effect lands it at
  once; `disengage` / `resetControls` cancel the ramp (landing every effect at its set value).
- With an effect ON, a mixable track ENGAGES AT ITS START (like the Stem Lock), on every start path
  (and after a media-services reset's hand-back); Apple Music / plain streams / a live Mix tab leave
  it dry (indicator `.waiting` / `.dormant`) and the lock carries on.

## Now Playing Mix Mode (`docs/design/np-mix-mode.md`)

Phases 1–3 are BUILT (no graph change — phase 3 changed SCHEDULING only); phases 4–5 below are
still planned. Keep this section in step with the phases as they land.

- **Phases 1–2 changed no graph.** Mix Mode (`SetlistPlayer.mixMode`, the `np-mix-mode` switch on
  the panel header) buffers the current + upcoming rows into local files (TEMPORARY burns, phase-1
  holds) through the same one-at-a-time lane the Stem Lock uses (`NowPlayingPrefetcher`), so the
  `NowPlayingDSP` chain above can take any track. Engagement stays swap-on-touch (Q2); the Stem
  Lock still engages at track start. (Phases 1–2: the full song is a COMPLETE local file when the
  DSP opens it; phase 3 below adds the growing one.)
- **Swap-on-land is a source switch outside the graph.** A current row streaming from its
  presigned rip URL moves onto the identical local file at the same song position when the buffer
  lands (`SetlistPlayer.handOffCurrentToLocal`) — an AVPlayer reload whose render is held until
  the seek lands (`PlayerEngine.load(deferPlayUntilSeeked:)`); the DSP is not involved unless the
  Stem Lock carries stems (then it engages at that position, as at a track start).
- **Media-services reset** while the DSP owns a track: the engagement is torn down and the track
  goes back to the AVPlayer at the DSP's position (`SetlistPlayer.handleMediaServicesReset`), then
  the orphaned graph is recreated (`NowPlayingDSP.rebuildAfterMediaReset`, engaged or not) and
  rebuilt on the next engage.
- **One DSP surface at a time** still holds: a live Mix-tab session tears the engagement down (F4)
  AND suspends Mix Mode's buffering until it stops.
- **Phase 3 (BUILT) changed scheduling, not topology.** The Mix deck's growing-file decisions
  (attach window, byte frontier, hold → resume runway, append chunking, underrun) are the shared
  `GrowingFileSchedule` used by both `MixEngine` and `NowPlayingDSP` (see "The full song while it
  downloads" above). With Mix Mode on, a ripped row that isn't local STARTS in the DSP on its
  buffer stream (`SetlistPlayer.startOnGrowingFile` — no presigned AVPlayer download of the same
  bytes); a row already on its presigned stream moves onto the growing file on the first control
  TOUCH once the buffer covers the playhead (`engageGrowingFromStream`, the DSP probes first and
  refuses touching nothing). A Now Playing main can now hold for bytes exactly like a streaming
  Mix deck. Backstops outside the graph: the start watchdog (no first audio ⇒ hop / advance) and a
  mid-song hold > 20 s / a dead stream ⇒ the row back on its plain stream at the same position.
- **Phase 4 changes no graph.** An Apple Music → local hand-off starts the DSP at MusicKit's
  position. It is a source switch outside the graph (MusicKit is out of process).
- **Phase 5 (optional) is the only topology change:** a 3-band `eq3` (`AVAudioUnitEQ`, the Mix
  channel-strip shape: Low shelf 320 Hz / Mid peak 1 kHz / High shelf 3.2 kHz) between `flanger` and
  `mainMixerNode`, attached at build time like every other node (the graph stays write-once):

  ```
  player + 4 stems → inputMixer → timePitch → comp → filter → reverb → flanger → eq3 (NEW) → mainMixerNode → limiter → output
  ```

  The SVG beside this file draws the Mix deck graph only, so it needs no change for any of these phases.

## Multiplayer Mix (SharePlay) — `Remote/MixSync.swift`

**No graph change.** Several DJs mix the same two decks over a Remote (SharePlay Listen
Together) session; EVERY device renders both decks through its own graph above, from shared
STATE. Audio is never streamed between devices. The 4-deck engine is a later, separate release —
the deck model (`Deck { a, b }`) is unchanged.

- **What is synced** (wire kinds `mix.snapshot`, `mix.event`, `mix.request`, `mix.ready`,
  `mix.beat`, `mix.reject`, `mix.handover` on the Phase-1 envelope): deck loads (song id +
  title/artist + Apple Music id + bpm/key — each device resolves the song against ITS OWN library
  via `MixResolver`; never a rip URL or token), eject, play / pause / seek / ↺ reset (each with an
  anchor), tempo, pitch, volume, crossfader, EQ, every FX-rack slot event (toggle / strength /
  family / variety / modulation), stem mode / mute / level, lead, sync, loop on/off + length +
  the EXACT window, deck ownership, and the session on/off. A session starts from the host's
  WHOLE board (`MixEngine.syncDeckStateEvents`, built from the same `DeckSnapshot` the durable
  deck session persists), and every reconcile (join, snapshot, a stray local change on a deck you
  don't own, a system resume) drives the deck to EXACTLY the model: `MixEngine.syncSetControls`
  folds the model's controls over a fresh deck's defaults and touches only what differs — an
  unlisted control goes back to default, a joiner's own pre-session board never survives the
  session's load.
- **What stays local:** cue / PFL and its level (it's this device's headphones), the VU meter
  source, recording (the house-sum tap), the session log (`MixSessionStore` — a remote DJ's
  gestures are applied under `MixEngine.applyingRemote`, which neither taps nor records them),
  the durable deck session (SUSPENDED while a session runs — `MixEngine.syncSessionActive`: the
  file on disk stays the user's own pre-session mix, crash or not, a parked launch restore is
  discarded and never materialized onto session decks; writes resume when the session ends), and
  Auto-DJ (DISABLED while a mix session is active — `MixEngine.setAutoDJBlocked`; a running one
  ends, decks keep playing; Siri / TV / pocket-run starts are refused WITH the reason; the user's
  Auto toggle comes back as it was when the session ends).
- **System causes stay local.** Every tapped gesture carries a cause
  (`MixEngine.Gesture.Cause`): `.user` (a hand on this device's Mix UI) is the only one ever
  proposed. `.system` — the lock screen / AirPods / CarPlay / Siri / the TV transport seam, an
  audio-session interruption (`remotePause` / `remotePlay` / `remoteSkip` run under
  `caused(.system)`) — silences or resumes THIS device only: the deck is held (no repair, no
  heartbeat from it, no drift fix) until the system resumes it, then it rejoins the session at
  the anchored position. `.engine` (watchdog stops, a media-services rebuild, teardown) is
  ignored outright.
- **Authority + ordering.** The session host orders everything: a participant's gesture is
  applied locally at once and PROPOSED; the host checks deck ownership (only a deck's owner may
  drive it; the crossfader is shared), assigns a host sequence number and rebroadcasts; every
  device applies ordered events strictly in host order (holes buffered, a stale hole ⇒
  snapshot). A sender skips its own echo, and its un-echoed proposal on a control shadows another
  sender's earlier-ordered value on the same control, so simultaneous hands converge on host order.
  The host drops a proposal older than the sender's last on that control (a reordered send); an
  un-echoed proposal older than 2 s is presumed lost — the sender stops shadowing and re-syncs
  from a snapshot. Continuous surfaces (sliders, knobs, the crossfader) are coalesced to ~20 Hz
  and scrubs to ~4 Hz per control, each with a trailing send of the final value; views observe
  only `MixSync.owners`, never the hot model. Snapshot requests back off (3, 6, 12, 24 s) and stop
  after 5 (a Phase-1 host never answers). Every device mirrors the authoritative model, so any
  device can answer a joiner or take over — and a live mix is never ended or rolled back by a host
  that lacks it: a snapshot from another epoch that is inactive or behind is refused and the
  refusing device sends its mirror (`mix.handover`, anchors on its own clock); a host whose model
  is inactive or older adopts it under its own epoch.
- **Timing.** Transport events carry `{positionMs, atSharedTime, isPlaying}` on the host's
  `SharedClock` timeline. The host anchors a start / seek **300 ms** in the future; each device
  converts the shared instant to its own wall clock and then to a host time
  (`MixEngine.hostTime(forLocalMs:…)`), and starts the deck with the **scheduled start**
  `MixEngine.play(_:fromMs:atHostTime:)` — the single file, or the deck's 4 stems together on ONE
  sample frame (`StemSync.startTogether` with the wait as its lead). An instant too close / past is
  pushed to the 60 ms stem lead with the cue moved forward by the gap × rate. Streams,
  mid-handover stems, STREAMING stems whose frontier doesn't reach the cue, and any schedule that
  comes up empty fall back to seek + play NOW from where the deck must be (never a silent
  "playing" node; `rescheduleFile` clears `fileScheduled` when it schedules nothing). A LOOPING
  deck starts now at the loop phase it must have, inside its existing window
  (`startLoopedNow` — the window is never re-derived and no lead is subtracted out of it). The
  start instant is when the frame must be HEARD: `syncPlay` fires early by the output path's
  latency (`outputLatencySeconds` = `AVAudioSession.outputLatency + ioBufferDuration` on
  iOS / visionOS / tvOS, the output node's `presentationLatency` on macOS), so AirPods and a
  wired speaker sound together. ↺ reset is anchored too: every device rewinds at one shared
  instant. An owner proposes ▶ only once its deck can SOUND (a buffering deck's start waits for
  its bytes, then goes out with an anchor off the moving playhead); the host still waits for the
  owner's READY report (`mix.ready`, sent the moment a load lands in the mirror), at most 4 s;
  late devices are position-corrected.
- **Loops.** A `loop` event carries the owner's window (`loopStartMs` / `loopEndMs`, re-sent on
  every length / edge change and before a scrub on a looping deck); receivers place EXACTLY that
  window (`MixEngine.syncSetLoop`) keeping their phase inside it. A reconcile seeks to the anchor
  FIRST, then places the window (never a loop near 0:00). Anchors and heartbeats on a looping
  deck are folded into the window, and drift compares the PHASE inside it (the short way round).
- **Drift.** The deck owner sends a heartbeat (`mix.beat`, every 2 s, best-effort) with its
  AUDIBLE playhead (`audiblePlayhead`: the render clock of the file or the stems projected to now,
  minus the output latency × rate, folded into a loop window) and its own clock uncertainty
  (best RTT / 2). EVERY device folds the beat into its anchor for the deck (repairs and joiner
  snapshots start from where it really is). Another device corrects only past
  `max(40 ms, my uncertainty + the owner's + 20 ms)` — a relayed 200 ms RTT makes 40 ms pure noise
  — seen on **2 consecutive** beats, against a clock measured on the current host, never on a beat
  older than 1.5 s, at most once per 4 s. Under **250 ms** it NUDGES: the deck's time-stretch runs
  ×0.99 / ×1.01 (a multiplier on the user's tempo, never a replacement — `syncNudgeRate`) for
  exactly as long as closes the gap, then the tempo is restored exactly; above it (or on a ▶/⏸
  mismatch) it re-seeks with a scheduled start.
- **Unavailable songs.** A device that can't mix a deck's song (not burned / streamable there, or
  Apple-Music-only — never mixable) leaves that deck EMPTY (silent for it), shows "not available
  on this device", and reports it (`mix.ready` = unavailable) so others see who is silent.
- **Ownership.** The host takes Deck A; Deck B goes to the first joiner that can own a deck —
  one advertising `MixCapability.deckOwner` in its hello `caps` (a Phase-1-only build sends none;
  an Apple TV renders the mix but has no deck board and never advertises it — its Mix controls are
  read-only for decks it doesn't own).
- **Hand-over.** When the host leaves, the Remote controller elects the lowest id; its mirror is
  re-anchored from the old host's timeline onto its own clock, departed owners' decks are freed,
  the sequence continues, and a fresh snapshot goes out. Everyone else keeps their deck.

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
- **A growing Now Playing song that starts deep into the file waits for the bytes** (a held
  start), so a restore-resume past 15 s the buffer doesn't cover yet, and an analog song with no
  per-song cut (its side streams from byte 0), start on the plain AVPlayer stream instead (it
  range-seeks); the touch hand-off moves them later.
- **Streaming decks are file decks with a moving end.** While a deck streams, `endFrames` is the
  downloaded frontier, so seek/loop/restart/stems-off can only reach audio that has landed (a seek
  past it holds at the target until the bytes arrive). The frame↔byte map trusts the LAME/Xing
  full-length header of our 256 kbps CBR rips; a headerless file (no Xing/VBRI/TLEN — a user
  digital file) plays only once complete: its partial open's length is an ESTIMATE from the bytes
  present, so the deck stays UNATTACHED (`streamHeaderless`, held, Buffering…, on the provisional
  catalog length, not ready to air) until the download completes, then attaches the whole song —
  the Now Playing DSP's `pumpMain` rule, mirrored (attaching the partial made a 12 s song "end" at
  3.6 s). Detection is the shared `GrowingFileSchedule.bytesPerSecond` 320 kbps bound, so a
  LOW-bitrate headerless file (128 kbps past ~40 % downloaded) can still pass as header-claimed. When a stream
  attaches, the real window also replaces the auto machine's catalog `durationMs`
  (`autoDeckDurationMs`, re-stamped; `loadAuto` reads `streamAttachedWindowMs` for an attach
  during its own load), so the crossfade is timed off the real length. An analog song without a
  fetchable per-song cut streams its whole album side up to `startMs`.
- **Handover alignment is sample-locked only on one render clock.** When the outgoing and
  incoming voices render at the same rate (both 44.1 kHz — every Demucs stem set against a
  44.1 kHz rip) the incoming voice starts on the outgoing one's exact frame. A full mix at another
  rate (a 48 kHz rip) falls back to a host-time projection: expect a few samples of error, hidden
  under the 60 ms crossfade. A handover on a LOOPING deck re-arms the loop on the new voices
  (the pre-handover re-schedule, a brief gap) instead of crossfading.
- **Every synced node group starts on one sample frame** (`StemSync.startTogether`): the Mix
  deck stems, `NowPlayingDSP`, `StemPlayer` (SongDetail stem audition, which also skips the stems'
  mp3 priming now) and the Studio step sequencer's pattern rows (`StudioEngine
  .restartPatternFromTop`; its steps are scheduled on each row player's own timeline). Measured
  with `StemSync.startFrame` (the render frame a node's player time 0 fell on): a shared host time
  lands nodes 1–2 frames apart on the simulator, the sample time 0. Deliberately left alone: the
  OFFLINE renderers (`StudioRender`, manual rendering mode — every player starts on render frame 0
  by construction) and `InstrumentEngine`'s click (one node anchored to a host-time beat grid,
  not a group). A group whose nodes run at different sample rates can't share a sample timeline
  and falls back to one host time.
- **Stem streams are not range-windowed.** Stems stream whole (≈4 × 8 MB for a 4-minute song)
  alongside the deck's own stream. They run at low task priority and are cancelled once unwanted,
  but on a slow link a WANTED set still shares the pipe with the on-air full mix, whose runway can
  shrink while they download.
- **Multiplayer Mix is two decks, state-synced, v1.** Sync's phase-align seek is anchored like
  any seek, but the tempo half lands on arrival. A looping STEM deck reports its accumulator
  playhead (its per-pass segment origin isn't tracked), so its drift reading is ~a tick coarse. A
  joiner whose clock isn't measured yet starts from the snapshot's anchor as-is and is corrected
  by the heartbeats after its clock syncs. A `mix.handover` maps anchors with the one-way latency
  ignored (the next heartbeat trims it). Master ▶ is disabled while mixing together; any other
  USER gesture on a deck you don't own is undone from the mirror on the next tick (a system
  pause is not — it is this device's own, see "System causes stay local").
