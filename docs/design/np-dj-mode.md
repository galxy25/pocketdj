# Now Playing DJ Mode

Status: **building 2026-11-09** on `feat/dj-mode`.

Levi, 2026-11-09, verbatim:

> add a new mode dj mode that enables those track transitions, effect sweep, tempo and pitch
> matching with an intelligent pocketdj to gradually build up the tempo of the playback session in
> 10 bpm ranges (min 3 songs in a bpm range) and selecting songs up next that are closest in tempo
> and key to make the mix smooth with waves of 2-3 that build up and slow down the tempo,
> degrading gracefully when that metadata isn't available or incomplete, and choose songs to play
> in a pocket of 3-4 songs that are of similar genre, year and collection membership or near
> adjacent. The key thing here is making it so more information is used by the autodj engine as
> it is available but we at least always get (once we have the next track bufferred and the
> current track is buffered until the end) the current transition orchestration that the
> dedicated mixer has - this dj mode goes on the now playing ui where we have mix mode, to the
> left of mix mode as a similar ui chip, with settings in settings for controlling what dj
> effects are defaulted to on with all set to on by default, pitch, tempo, volume (this is new we
> should add to normalize the audio volume between tracks to keep the mix at a consistent
> volume), "pocket" (genre, year, collection membership)

## 1. What DJ Mode is

DJ Mode is session state on `SetlistPlayer`, a sibling of Mix Mode (`NPMixModeState`). It is
persisted in the snapshot as optional `djMode`, restored held, and cleared by `stop()` and by a
new `play`. While it is on, three things happen:

1. **Buffering.** DJ Mode implies Mix Mode buffering: current + next rows become local files.
   Turning DJ on turns Mix Mode on. Turning Mix Mode off turns DJ off.
2. **Transitions.** When the current row plays in the DSP from a file that is complete to its
   end, AND the next row is a complete local file (`rowWillPlayLocally`), the advance is a DJ
   transition. It uses the Mix tab Auto-DJ's orchestration: lead, crossfade, glide pre-roll and
   post-roll, tempo meet-in-the-middle, ±1 key pitch bend, FX texture sweep, and downbeat phase
   align. If either condition fails, the advance is today's normal advance. That never blocks or
   delays playback; it just isn't mixed.
3. **The PocketDJ selector.** It re-orders the session's own upcoming rows (§4) into tempo waves
   and genre/year/collection pockets. It uses whatever metadata exists and degrades to the queue's
   own order when there is none.

Plus **volume leveling** (§5) on every track the DSP plays while DJ Mode is on.

DJ Mode is iOS, iPadOS, macOS and visionOS only, like Mix Mode (`mixModeSupported`). There is no
tvOS v1. It is suspended while a Mix-tab session is live, same rule as Mix Mode.

## 2. One orchestration, two engines

The Mix tab's state machine lives inside `MixEngine`. The parts that decide what a transition
*is* move to a shared pure type `AutoTransition` (`Playback/AutoTransition.swift`), and both
engines call it.

- **Timing.** `lead` = Settings `autoMixLeadSeconds` (15). `fade` = `autoMixFadeSeconds` (3),
  capped to `max(0.5, secondsLeft)`. Glide pre-roll is
  `min(glideSeconds, secondsLeft/headroom - fade - 0.3)`, headroom 1.12. Post-roll is
  `mixGlideSeconds` (10).
- **Tempo and pitch.** `glideParams`, `signedCamelotSteps`, `glideRate`, `glidePitch`,
  `octaveFolded`.
- **FX texture.** `rollTexture`, `fxSeed`, `splitmix64`: filter / reverb / flanger, strength
  0.5–0.8, the same texture held for 3–5 transitions.
- **Phase align.** The incoming start is offset by at most ½ beat from BPM + `firstDownbeatMs` +
  beat grid.
- **Curve.** Equal-power cosine.

`MixEngine` is refactored to call these, behavior-preserving; its existing tests guard that.
DJ Mode uses the SAME settings values. The DJ toggles (§6) mask parts off: no tempo → rate
targets 1; no pitch → pitch 0; no effects → no texture; no transitions → normal advance.

## 3. The Now Playing tail deck

`NowPlayingDSP` stays single-deck for everything the listener touches. It gains a
**tail deck**: one `AVAudioPlayerNode` → `AVAudioUnitTimePitch` → filter EQ → reverb → delay
(flanger) → tail gain → the engine's main mixer, ahead of the shared PeakLimiter.

The deck is built lazily and lives only for the length of a transition.

1. **Transition start** (pre-roll start, or fade start when there's no glide).
   - The outgoing song moves sample-accurately from the main chain to the tail deck: the same file
     from the same frame at a shared future host time.
   - It carries the outgoing rate, pitch, effect and leveling gain.
   - If the outgoing has muted stems, the DJ transition is declined (normal advance) and
     `[dj] declined stems-muted` is logged. Full-mix stem mode with nothing muted is fine; the
     tail plays the full-mix file.
2. **Pre-roll.** The tail deck ramps rate, pitch and FX toward the glide targets.
3. **Fade start.**
   - `SetlistPlayer` advances: the card, queue index and DeadAirMeter say the next song.
   - The main chain engages the incoming file at its phase-aligned start, gain 0, with rate and
     pitch pinned to the incoming glide targets.
   - The equal-power fade runs: tail out, main in.
4. **Fade end.** The tail deck stops and is released.
5. **Post-roll.** The main chain eases rate and pitch back to the listener's settings, and the FX
   back off.

A listener touch on any control during post-roll ends the glide at once; the listener wins.
Transport during a transition:
- **Pause** pauses both decks.
- **Skip** cuts the tail.
- **Seek** cuts the tail.
- **Stop** cuts everything.

## 4. The PocketDJ selector (`Playback/DJSetPlanner.swift`, pure)

**Pool.** The session's upcoming rows. These stay where they are:
- pinned or hand-moved rows (`PlanTag.pinned`, `moveUpcoming`)
- jukebox inserts

The NEXT row stays where it is once it is local or buffering, or no longer
`isReplaceablePosition`. The planner never throws away a buffered next track. Shuffle order is
superseded while DJ Mode is on.

**Features**, all optional:
- folded BPM (`InThePocketScorer.foldBpm`, 80–160)
- Camelot
- `Genre.category(album.genre)`
- year (song, else album)
- collection membership set (`CollectionFlattener` / the app's `collectionsInput`)

**Tempo waves** (Tempo setting on).
- Bands are 10 BPM wide (`floor(bpm/10)*10`).
- The set stays in a band for at least 3 songs, counting the songs already played in that band.
- Then it steps one band in the wave direction. After 2–3 band steps (deterministic per session
  seed) the direction flips: build up, then come down.
- At the top or bottom of the pool, or when the next band in the wave direction has no
  candidates, it flips early. A band with too few songs is skipped toward the nearest populated
  band in the same direction.
- Songs with no BPM don't count toward a band. They are placed by pocket and key fit and never
  break a wave's count.

**Pockets** (Pocket setting on).
- Runs of 3–4 songs (seeded) share genre, era and collections.
- Inside a pocket, similarity to the pocket's anchor:
  - genre: same category 1, else 0
  - year: `exp(-|Δy|/6)`
  - collections: Jaccard
- The next pocket's anchor is "near adjacent": the best candidate whose similarity to the last
  pocket is between 0.3 and 0.8. Failing that, the best overall.

**Next-song score.** A weighted sum over the parts that are known; weights renormalize over the
parts present, so missing data never counts against a song:

| Part | Weight | Formula |
|---|---|---|
| Target-band fit | 0.35 | 1 in band, 0.4 adjacent, else 0 |
| BPM closeness to the current song | 0.2 | `exp(-|Δ|/10)` |
| Key | 0.2 | `SimilarityFamilies.camelotRelatedness` |
| Pocket similarity | 0.25 | as above |

- A tiny original-order bonus (`0.02 * (1 - i/n)`) breaks ties and keeps a no-metadata queue in
  its own order.
- The search is greedy, one song at a time, simulating the wave and pocket state forward.

**Re-plans** happen when DJ turns on, on each advance, and on any queue edit (debounced 1 s). Each
re-plan is a single `replaceUpcoming` (uid-verified, pin-respecting), so buffering replans once.

## 5. Volume leveling (new)

**Analysis.** `LoudnessAnalyzer` (pure DSP over PCM) estimates integrated loudness:
- K-weighting (BS.1770 two-stage biquad)
- 400 ms blocks
- absolute gate −70 LUFS and relative gate −10 LU

It runs on a utility-priority background task when a local file completes (burn, cut or
prefetch). It decodes at a reduced cost (mono sum, every block), with one analysis per
songId + file size. Results are cached in `Application Support/loudness.json`.

**Gain.** Target −14 LUFS; gain = target − measured, clamped to −12…+6 dB.
- It is applied on the DSP's trim (main) and carried onto the tail.
- An unknown loudness gets 0 dB until analysis lands. Then it ramps over 2 s, never as a step.
- The PeakLimiter catches positive-gain peaks.

Leveling applies only while DJ Mode is on and Volume is on. The listener's volume slider sits on
top.

## 6. Settings ▸ DJ Mode

All toggles are on by default:
- Transitions (crossfade)
- Effect sweeps
- Tempo match
- Key/pitch match
- Volume leveling
- Tempo waves
- Pockets (genre, year, collections)

They are optional `SettingsStore` fields, nil = on. The player reads them through a
`djModeSettings` closure, like `mixModeSettings`. The Mix tab's lead, fade and glide lengths are
shared and edited where they already are.

## 7. UI

- **Now Playing Mix panel header.** A `DJ` capsule chip LEFT of the Mix Mode switch. It has the
  same style (`mixModeSwitch`) and a11y id `np-dj-mode`, with the glyph
  `dial.medium` / `music.note.list`.
- **Status chip.** While DJ is on it reads:
  - "DJ — next mixes in" when the next is local
  - "DJ — buffering next n%" otherwise
  - "DJ — mixing" during a transition
- **Menus.** `MixModeMenuToggle`'s sibling `DJModeMenuToggle` goes in the record and mini-bar menus.
  On macOS: Controls ▸ DJ Mode (⌥⌘J).
- **Diagnostics.** A `[dj]` DiagLog lane logs plan, transition start/decline reasons and leveling
  gains. It logs song ids only.

## 8. Tests

- `DJSetPlannerTests`:
  - waves build and fall
  - minimum 3 per band
  - early flip at pool edge
  - no-metadata keeps order
  - pins hold
  - buffered next holds
  - pocket length 3–4
  - near-adjacent anchor
  - partial metadata
- `AutoTransitionTests` (timing and caps), plus the existing MixEngine Auto-DJ tests stay green.
- `LoudnessAnalyzerTests` on synthesized sine and noise at known RMS. The −14 target and clamp.
- `NowPlayingDSP` tail-deck tests:
  - handover keeps the playhead
  - fade reaches 0/1
  - tail released
  - pause, skip and seek mid-transition
  - decline paths
- `SetlistPlayer` DJ tests:
  - advance at fade start
  - snapshot round-trip
  - DJ ⇒ Mix Mode
  - suspended by the Mix tab
