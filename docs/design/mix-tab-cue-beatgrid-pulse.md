# Mix tab — Cue / PFL, beat-grid BPM & beat pulse

Third Mix-tab batch for the native app. Three deck features, built on the two-deck DJ engine
([architecture ch.4 §7](../architecture/04-performance-engine.md)): a **cue (pre-fade listen)** button,
the **measured beat-grid BPM** on each deck, and a per-beat **visual pulse**. Touches `MixEngine.swift`,
`MixView.swift`, `SettingsStore.swift`, `SettingsView.swift`, and the unit/UI tests. No audio-indexer
change — the analyzer already emits `beatGridBpm` / `firstDownbeatMs`, which already reach `LoadedTrack`.

## 1. Cue / PFL — the standard DJ channel strip

The driving goal was to follow **conventional mixer signal flow** so the feature is easy to extend and
read. Before, each deck's crossfade gain was baked onto the player's `volume`, and the master was a
single stereo sum. Now each deck is a real **channel strip**: after the effect chain its post-FX output
(`flanger[d]`) **splits** into two sends, both summing at `mainMixerNode`:

```
flanger[d] ─┬─→ mainGains[d] (AVAudioMixerNode)   the CHANNEL FADER → main/house mix
            │      outputVolume = min(vol,1) × equal-power crossfade
            └─→ cueGains[d]  (AVAudioMixerNode)    a PRE-FADER PFL send → cue/monitor bus
                   outputVolume = cued ? cueVol : 0      (independent of the fader/crossfader)
```

- **The player now runs at unity.** The deck's main volume (≤1) and the equal-power crossfade moved
  downstream onto `mainGains.outputVolume`; the >unity boost (100–200%) still rides the deck's EQ
  `globalGain` (in-chain). This is what makes the cue tap **pre-fader**: the cue send is taken after the
  effects but before the channel fader, so its level is set only by the per-deck **`cueVol`**, untouched
  by the Vol slider or crossfader. That's true PFL — you can monitor the next track at full while the
  crossfader still sits on the current one.
- **Additive, not a split.** A cued deck **keeps** playing to the house at its fader level *and* is sent
  to the cue bus. (An earlier idea — pull the cued deck *off* main — was rejected in favour of standard
  PFL.)
- **Stems ride for free.** The 4 stem nodes merge at `inputMixer`, upstream of the split, so stem-mode
  audio flows to both the main and cue sends with no extra wiring.
- **Channel routing.** While **any** deck is cued, `mainGains` pan to the house side and `cueGains` to
  the cue side, so a stereo interface carries house on one channel and cue on the other (the
  `main on left / cue on right` booth wiring). When nothing is cued both sends are centered, so an
  un-cued mix is **bit-identical normal stereo** (no surprise mono for casual listening). The
  `masterLimiter` still catches the summed peak.

`applyCueRouting()` is the single place that writes these four values; `applyMixGains` /
`applyCrossfader` / `setVolume` / `setCued` / `setCueVolume` / `setCueOnRight` all funnel through it.

**UI.** A headphones **cue button** sits just left of Reset on each deck's transport row (a plain
tappable view, not a `Button`, so the long-press isn't swallowed — same reason as `EffectButton`):

- **Tap** → `toggleCue(deck)` (the house mix is untouched).
- **Long-press / right-click** → a fixed-width **cue-volume popover** (reusing `ChipStrengthPopover`),
  because the cue *level* is independent of the main Vol fader and deserves its own control.
- Disabled (dimmed) until a track is loaded, so cueing an empty deck can't pan the *other* deck to mono.

**Which channel is cue** is a **Settings-tab** choice (`CueChannel`, default `.right` → main on left),
not a per-deck menu — it's a property of your booth wiring, set once. `MixView` pushes it into the
engine via `engine.setCueOnRight(settings.cueOutputChannel.onRight)` on appear and on change.

## 2. Beat-grid BPM on the deck

Beside the camelot **KeyChip**, each deck now shows the **measured beat-grid BPM** — the exact value the
engine beat-matches on (`gridBpm`, one decimal), falling back to the rounded catalog `bpm`. The grid BPM
+ `firstDownbeatMs` come from the rips analyzer (`analyze-beatgrid.py`) via the manifest →
`BurnStore.beatGrid(forSong:)` → `LoadedTrack`, which the engine already loads — so this is a pure UI
read (`keyOrBpm`), no new data plumbing.

## 3. Beat pulse — phase-locked to the audio, on the real grid

**Opt-in** (Settings ▸ Mix, **default off**): `BeatPulseView` overlays a glowing ring on each deck that
**flashes on every beat** — downbeats (bar starts) brighter and longer, in a different colour (downbeat
= `Theme.accent`, off-beats = `Theme.accent2`) — so you can *feel* the groove and **eyeball-align the
two decks**. Off ⇒ the overlay isn't created at all (zero cost).

Two things make it tight rather than theoretical:

- **Phase-locked to the true audio clock.** It's driven by a 60 fps `TimelineView(.animation)` reading
  **`MixEngine.truePlayhead(deck)`** — the deck's `AVAudioPlayerNode.playerTime`, not the ~10 Hz
  wall-clock accumulator. `playerTime.sampleTime` is in the file's sample rate and **resets to 0 on
  every `scheduleSegment`**, so `truePlayhead` adds back **`segmentStartSeconds`** (0 on load/restart,
  the seek target on seek, the resume point on stem-mode exit) to recover absolute source position. The
  time-stretch rate is already baked into how fast `sampleTime` advances, so the pulse **speeds up with
  the tempo** automatically; the flash decay is in wall-clock (`(playhead − lastBeatSec) / rate`) so it
  *looks* the same at any tempo. `truePlayhead` returns nil before the first render / in stem mode /
  just after a seek → the view falls back to `position`.
- **On the real measured grid.** When the per-beat sidecar is present (`LoadedTrack.beatsMs` /
  `downbeatsMs`, §4), the pulse binary-searches the actual beat timestamps — so a **tempo-drifting**
  track pulses on its real beats, and downbeats are the analyzer's real bar starts (near-membership in
  `downbeatsMs`). Absent a sidecar it **synthesizes** a constant grid from `gridBpm` (or catalog `bpm`)
  + `firstDownbeatMs`, downbeat every 4th beat (4/4). No grid at all ⇒ the ring stays dark.

Computing intensity directly each frame (no peak/decay state) means the pulse can never get "stuck". The
view is its own struct so the 60 fps reads never re-render the rest of the deck.

## 4. Beat grid as a burnable artifact (offline) + dynamic fetch

The analyzer already ships a per-beat **sidecar** to S3 (`rips/analysis/<songId>.json` with `beatsMs[]`
/ `downbeatsMs[]`), and the manifest carries its key (`beatgrid`) — but nothing fetched it. Now it's a
first-class burnable artifact that **mirrors stems exactly**:

- **Burn.** A collection/setlist burn runs `burnCollectionBeatgrids` right after the stem pass: for each
  song the indexer has analyzed (`rips.hasBeatgridSidecar` = `manifest.beatgrid != nil`), it downloads
  `analysis-<id>.json` into the burn folder if absent — **idempotent** (skips present), **STOP-aware**,
  **best-effort** (a sidecar failure never fails the burn), and the JSON is **validated before it's
  cached**. Re-burning a setlist only pulls grids that became available since (`BurnResult.beatGridded`,
  surfaced as "N with beat grids"). Like stems, burning *fetches* an existing grid — it never triggers
  analysis.
- **Dynamic fetch on load, gated on the pulse.** `MixEngine.load` attaches the **local** sidecar
  synchronously (offline, no network). If it's absent **and the beat pulse is enabled**,
  `hydrateBeatGrid` downloads it in the background (`BurnStore.burnBeatGrid`) and patches the deck's
  `LoadedTrack` (guarded by `songId`, so a deck that moved on is left alone) — the pulse upgrades from
  synthesized to real grid in place. **Pulse off ⇒ no download** for a track that lacks a grid. Toggling
  the pulse on re-hydrates whatever's already loaded. The engine mirrors the setting via
  `setBeatPulseEnabled`, pushed from `MixView`.

## Settings

Two new Mix settings, both following the backward-compatible pattern of `skipFadeSeconds` (Optional in
`SettingsData`, coalesced at the read sites so a legacy `pdj.settings.v1` blob still decodes):
- **`cueOutputChannel`** (`CueChannel: String, CaseIterable { right, left }`, default `.right`) — a
  `Picker` (`settings-mix-cue-channel`); pushed into the engine via `setCueOnRight`.
- **`beatPulseEnabled`** (`Bool`, **default false**) — a `Toggle` (`settings-mix-beat-pulse`); gates
  the `BeatPulseView` overlay in `DeckView` (read via `@Environment(SettingsStore.self)`).

## Tests

- **MixEngineTests** — `testCueToggleVolumeAndChannel` (no audio: toggle/anyCued/cue-vol clamp/channel
  pref) and `testCueRoutingIsPreFaderPFLAndPansToTheCueChannel` (real graph: cueing sends a deck to the
  cue channel at full *despite the crossfader on the other deck*, leaves its main send untouched, pans
  main/cue to opposite sides, reverts on un-cue, and flips with the channel preference).
- **MixEngineTests (beat grid)** — `testTruePlayheadReadsAudioClockAndHonorsSeekOffset` (real graph: the
  playhead reads the audio clock and, after a seek to 2 s, reports ~2 s rather than the segment-relative
  0 — proving the `segmentStartSeconds` add-back) and `testEnablingPulseHydratesLocalBeatGrid` (enabling
  the pulse attaches a burned local sidecar's `beatsMs`/`downbeatsMs`, no network).
- **BurnStoreTests (beat grid)** — fetch on burn (`beatGridded`), re-burn picks up newly-available grids,
  skip un-analyzed songs, the dynamic `burnBeatGrid` parses + caches + is idempotent, and returns nil
  (no network) when there's no sidecar — mirroring the stem-burn tests.
- **SettingsTests** — `cueOutputChannel` and `beatPulseEnabled` defaults / persist-reload / legacy-blob /
  reset, mirroring the auto-mix settings.
- **UI** — `MixSessionsUITests.testCueButtonsRenderOnBothDecks` (cue buttons render in content beside
  Reset); `SettingsUITests` asserts the `settings-mix-cue-channel` picker + `settings-mix-beat-pulse`
  toggle render.

## On-device

The unit tests assert the engine sets the right node levels/pans/playhead and that grids burn + parse;
the **felt** behaviour — cue truly on the chosen output channel of a real interface, and the pulse
phase-locked to real grid-analyzed tracks (and speeding up with the tempo fader) — is best confirmed on
device. A track only pulses on its *real* grid once its sidecar exists server-side (`/backfill-beatgrids`)
and has been burned or dynamically fetched; otherwise it falls back to the synthesized grid.

The **actual audio routing** (cue truly emerging on the chosen output channel of a real interface) is
only fully verifiable on hardware — the unit test asserts the engine sets the correct node levels/pans;
the beat pulse + BPM readout are best eyeballed on-device with real grid-analyzed tracks.
