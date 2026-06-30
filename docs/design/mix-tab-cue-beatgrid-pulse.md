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

## 3. Beat pulse

**Opt-in** (Settings ▸ Mix, **default off**): `BeatPulseView` overlays a glowing ring on each deck
container that **flashes on every beat** — downbeats (every 4th beat, 4/4) brighter and longer, in a
different colour (downbeat = `Theme.accent`, off-beats = `Theme.accent2`) — so you can *feel* the
groove and visually **eyeball-align the two decks** while beat-matching. When the setting is off the
overlay isn't created at all (zero cost). Beats are **synthesized** from
`gridBpm (or catalog bpm)` + `firstDownbeatMs` + the playhead: `beat = floor((position − downbeatSec) /
(60/bpm))`. Because `position` is already source/song time, `60/bpm` is the beat period directly (the
deck's tempo `rate` must **not** be applied again). Detection runs off the ~10 Hz playhead; the flash
itself is a smooth SwiftUI animation, so up-to-100 ms detection latency is invisible. No track grid (no
`bpm`) ⇒ `currentBeat()` returns `.min` and the ring stays dark. It's its **own** struct so these
frequent `position` reads re-render only the overlay, never the whole deck (same isolation as
`DeckSeekSlider`).

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
- **SettingsTests** — `cueOutputChannel` defaults / persist-reload / legacy-blob / reset, mirroring the
  auto-mix settings.
- **UI** — `MixSessionsUITests.testCueButtonsRenderOnBothDecks` (cue buttons render in content beside
  Reset); `SettingsUITests` asserts the `settings-mix-cue-channel` picker renders.

The **actual audio routing** (cue truly emerging on the chosen output channel of a real interface) is
only fully verifiable on hardware — the unit test asserts the engine sets the correct node levels/pans;
the beat pulse + BPM readout are best eyeballed on-device with real grid-analyzed tracks.
