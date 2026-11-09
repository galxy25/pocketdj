# Now Playing DJ Mode

Status: **integrated 2026-11-08** on `feat/dj-mode` (building blocks + the integration: tail
deck, conductor, selector wiring, leveling, UI, settings, tests — §9). NOT device-verified.

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
- **Skip** — see "Skip = the Mix tab's Skip" below.
- **Seek** cuts the tail.
- **Stop** cuts everything.

**Skip = the Mix tab's Skip** (Levi 2026-11-09). With DJ Mode active, ⏭ MIXES into the next row
(`SetlistPlayer.skipNext(fast:)` → `djSkipMix`) instead of cutting:
- A tap mixes over Settings ▸ Mixing **Skip fade** (default 15 s); a **double tap** — and the
  lock-screen / CarPlay / widget ⏭ — is the fast **5 s** sweep (`DJMode.fastSkipFadeSeconds`),
  exactly the Mix tab's single / double-tap Skip and its lock-screen ⏭.
- No transition in flight: one starts NOW with `AutoTransition.immediatePlan` (no pre-roll; the
  glide snaps on the outgoing at the fade start and eases out on the incoming over the post-roll;
  FX / tempo / key / leveling as at a song's end). The fade is cut to the outgoing's runway
  (≥ 1 s, 0.5 s spare) so a long Skip fade near a song's end never sweeps up against silence.
- In the **pre-roll** of an end-of-song mix: the pre-roll is dropped and the fade starts now over
  the skip length (cut to the runway at the outgoing's glide tempo, which the fade start pins). The
  pending skip is keyed on the RUN's incoming; if the queue moved under the pre-roll the fade start
  refuses and the skip falls back to the immediate advance. PAUSED in a pre-roll, the mix is dropped
  and the immediate advance skips at once (the fade couldn't start until ▶).
- During the **fade**: ignored (the advance already happened — the Mix tab's rule).
- During the **post-roll**: the glide ends (the listener wins) and the skip mixes out of the new song.
- The advance (at the fade start, ~60 ms after the press) is the listener's skip: `noteTransition(.user)`,
  `noteUserTransport`, DeadAirMeter `cause=skip`; the skip tracker hears it at the press. An explicit
  skip overrides repeat-one / a repeat count and lifts a cascade halt (`djEndReason(forSkip:)`).
- Anything DJ Mode can't mix (DJ off or suspended, the current row not on the DSP, the next row not
  a complete local file, the last row / repeat-all wrap, an album run, Transitions off, a DSP decline)
  is today's immediate advance. A skip mix refused at its fade start still skips (immediate advance).
- ⏮ stays "previous track". The macOS set-list toolbar ⏭ (no double tap in a toolbar) mixes over the
  Skip fade; the Now Playing deck, mini-bar and the iOS set-list cluster take the double tap.

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

## 6. Settings ▸ Mixing

Its own pane (2026-11-09; the toggles first lived under Settings ▸ Storage): **Crossfades** (lead,
crossfade length, Skip fade, Mix Glide length — shared by the Mix tab's Auto mode and DJ Mode),
**Now Playing DJ Mode** (the toggles below), and **Mix tab** (auto-hide played, cue channel, beat
pulse, iOS deck layout). The DJ toggles are on by default:
- Transitions (crossfade)
- Effect sweeps
- Tempo match
- Key/pitch match
- Volume leveling
- Tempo waves
- Pockets (genre, year, collections)

They are optional `SettingsStore` fields, nil = on. The player reads them through a
`djModeSettings` closure, like `mixModeSettings`. The Mix tab's lead, fade, glide and skip-fade
lengths are shared (`djTimings`).

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

## 9. As built (2026-11-08)

| Piece | Where | Notes |
|---|---|---|
| Session state | `SetlistPlayer` "Now Playing DJ MODE"; `DJModeState` (+ optional `planner`) | `setDJMode` / `toggleDJMode`; ON turns Mix Mode on, seeds the selector (`AutoTransition.fxSeed` over the queue), re-plans, and takes the current local row into the DSP; OFF disarms + levels to 0 dB (the playing track carries on). `setMixMode(false)` turns DJ off. Cleared by `play` / `stop`. `djActive` = supported (not tvOS) && on && Mix tab idle && no Remote session attached (`remoteSessionActive`, wired to `RemoteSessionController.isActive`). |
| Snapshot | `PlaybackSessionStore.Snapshot.djMode` + `Row.djPlaced` | Optional, no schema bump. Restored HELD (Mix Mode forced on with it); nothing armed / planned / analysed before ▶. The listener-placed marks ride each row, so they survive a relaunch. |
| Track start | `applyDJOnTrackStart` (last step of `applyLocksOnTrackStart`, so every start path, the swap-on-land and the media-reset hand-back get it; also the album glide / in-place skip, `retargetInPlace`, when DJ is on) | A mixable row is engaged at its start (like the FX Lock), ARMED (`NowPlayingDSP.armDJ(lead:)`), leveled, and the next 2 local rows are queued for loudness analysis. Apple Music / plain streams / live captures play as they are — their end is a normal advance. A vinyl ALBUM-RUN row (it and the next row are neighbouring songs of one shared side) is NOT engaged: the AVPlayer keeps the side and glides; the record's last queued song is engaged at its glide so its end can mix out. |
| The decision | `djBuildTransition` (asked by the DSP's 10 Hz lead-window watch; retried every 1 s while declined) | Declines (logged once per song + reason; ONE list, `djEndReason`, shared with the fade-start re-check and the chip): transitions off, repeat-one / repeat count, cascade halt, last song (repeat-all: "set repeats"), an album run (the side keeps playing), the next row STARTS an album run (the side starts from the record — mixing into its first song would cost a reload at that song's end), next not a complete local file. Then `AutoTransition.advancePlan(secondsLeft × min(1, 1.12/outRate), fade, glide, fxGlide: effectSweeps, mixGlide: tempo‖key)` (a tempo meet faster than the plan's 12 % headroom plans on the runway it really has), `glideParams` (Camelot only with Key on, BPM only with Tempo on — grid BPM preferred, the outgoing's listener rate folded in), the texture run (`rollTexture`, held 3–5 transitions) only with Effect sweeps on, the incoming's leveling gain only with Volume on. |
| Tail deck + conductor | `NowPlayingDSP` "DJ Mode: the TAIL deck" | §3 exactly; see `mix-audio-graph.md` "Now Playing DJ Mode". DSP-side declines: not playing / holding, growing outgoing, stem handover in flight, `stems-muted`, unreadable incoming, < 0.3 s left. |
| Advance at fade start | `djAdvanceAtFadeStart` + `djIncomingEngaged` | Re-checks `djEndReason` (repeat-one / count / cascade halt / Transitions / suspension flipped during the pre-roll refuse). Index, `noteTransition(.naturalEnd)`, repeat counter, generation / start-window / stall bookkeeping, `DeadAirMeter` (`cause=dj`, first audio at once), control reset + FX Lock stamp, then `nowPlaying` (one history play), the DSP card, Stem Lock on the incoming, re-arm, re-plan. A refusal (the queue moved) puts the outgoing back on the main chain; a DSP that can't open the incoming after the advance plays it the plain way. |
| Selector | `djReplan` / `applyDJOrder` | One uid-verified re-order of the next 40 upcoming rows on DJ on, each advance, a membership landing, and queue edits (debounced 1 s; our own re-order never re-triggers; none while a Remote session is attached). Fixed: `plan.pinned`; rows the LISTENER placed (`Item.djPlaced`: insert / add / move / jukebox Surprise Slot / the stall hop's deferred row — persisted); album-run rows (fixed blocks — never re-ordered or split); rows with a playback rip in flight, a lane fetch or a buffer stream downloading (`replaceUpcoming`'s guard — moving them out of the rip window would cancel the capture); rows deferred `djMaxDeferrals` (12) times (aging — each deferral also adds `DJSetPlanner.agingBonus` 0.03 to the row's score); and the next row when local, buffering, mid-transition, or under the 30 s runway rule (or its length unknown). One `replaceSubrange` write; duplicate uids bail (never trap). Features: catalog (`djSongFacts` — BPM, Camelot, album genre, song-else-album year) with the burned item's BPM / key filling gaps; collections from `djMembershipProvider` (the app flattens `collectionsInput` OFF-main with `ListeningPocketsCollections.flattened`, once per DJ-on — an empty answer is remembered too). |
| Leveling | `djLevelDb` / `applyDJLeveling` / `djAnalyze`; `NowPlayingDSP.setLevel(db:ramp:seconds:)` on `levelTrim` | `LoudnessCache.shared` (tests inject one). Keyed song id + byte size + SEGMENT: a song on a shared album side is measured (and cached) as its own slice, never the whole side. ONE analysis per key (a second caller awaits it); a failure is remembered for the launch (no retry loop); only an analysis that STORED a result re-applies the gain (the old busy loop is gone); DJ off / the session ending cancels running analyses (the cancel reaches the decode through a flag). Mono-sum decode (see §5 note). A growing file isn't measured until complete (its completion re-runs it). Unknown ⇒ 0 dB; a landing mid-play ramps 2 s in 20 ms steps; the incoming's gain lands over 150 ms at the fade start; a ramp in flight at a handover carries on on the tail. |
| UI | `NowPlayingMixPanel` (`np-dj-mode` chip left of Mix Mode; the DJ words ride the Mix Mode chip: "Mixing · DJ — next mixes in"), `DJModeMenuToggle` (record + mini-bar menus), macOS Controls ▸ DJ Mode ⌥⌘J, Settings ▸ Mixing (`MixingSettingsView`: the crossfades + the 7 toggles + the Mix tab options), `NPSkipNextButton` (⏭: tap = Skip fade, double tap = fast, with DJ Mode active) | `DJMode.Indicator`: off / suspended (Mix tab) / suspendedRemote ("DJ — paused · SharePlay session") / mixing / nextReady / bufferingNext(n%) / lastTrack / noMix(why) ("DJ — repeating this song", "transitions off", "album plays through", "album side next", "set repeats", "this song ends as is"). Not on tvOS. |
| Tests | `DJModeTests` (32) | Pure (words, membership, snapshot); DSP tail (handover playhead, fade 0/1 + release, pause both, disengage cut, seek cut pre-roll + post-fade, listener touch, host refusal = seamless hand-back + ease, declines incl. muted stems, pause inside the handover defers the fade, a refusal near the end still reports the end, a stem mute after the advance doesn't cut, engine stop while paused cuts); sequencer (DJ⇒Mix / Mix off⇒DJ off / session scope, advance at fade start, non-local next + transitions off = normal advance, snapshot held restore, Mix tab suspends, Remote session suspends + natural-end tag + resumes, selector fixed rows + buffered next + debounced edit re-plan, album run plays through on the glide with DJ on, selector keeps an album run in record order, placements survive restore, honest chip words, leveling lands); analyser (single-flight, remembered failure, per-segment loudness, mono-sum = full sum on correlated channels); planner aging. |

Skip mix + Settings ▸ Mixing (2026-11-09): see §3 "Skip = the Mix tab's Skip" and §6.
`DJModeTests` +8 (skip fade cut to the runway, skip mixes over the Skip fade as a user skip, fast = 5 s, non-local next = immediate,
DJ off unchanged, repeat-one overridden, ignored mid-fade, pre-roll hurried to the fade).
Review fixes (2026-11-09, `DJModeTests` +5): the pending skip is cleared on every start / advance /
⏮ and on EVERY run end (`endDJRun` — load / disengage — now reports `onDJTransitionEnded` too), so it
can't swallow a later ⏭ or tag a later natural mix as a skip; any fade-start refusal while a skip is
pending still skips; the ⏭ view keeps the Button's 44 pt target and dims while pressed.

Review fixes (2026-11-08, after the audio + player reviews) — decisions:
- **Remote / SharePlay**: DJ Mode is SUSPENDED while a Remote session is attached — no DJ
  transitions, no re-ordering, no auto-engage; songs end with the normal advance. Its fade-start
  advance would read as an EARLY natural end to the session (other participants cut ~5 s short, or
  this device held after "end") and two DJ devices would re-order each other's mirrored queue.
  The chip reads "DJ — paused · SharePlay session"; it resumes on the playing row when the session
  ends (like turning DJ Mode on).
- **Vinyl album sides**: DJ never breaks end-to-end album play. An album-run row stays on the
  AVPlayer (glide / in-place skips unchanged), its end never mixes, a DJ transition never mixes
  INTO a row that starts an album run, and the selector treats album-run rows as fixed blocks. The
  record's last queued song is taken into the DSP at its glide so it can mix out.
- **Natural ends**: `handleDSPEnded` tags its advance / repeats `.naturalEnd` exactly like
  `handleEnded` (it was `.autoSkip`, which a Remote session reads as "can't play here").
- **Hand-back instead of restart**: a cut before the advance with the song still playing crosses
  back to the main chain at the tail's playhead (no 60 ms hole, no click, the glide eased out over
  0.5 s); a tail that already ran out reports the end.
- **Mono-sum analysis** (§5's "reduced cost"): channels averaged, one K-weighting chain, energy ×
  channel count. Exact for mono and identical channels; wide uncorrelated stereo reads up to ~3 dB
  low — consistently, so the trim stays a relative leveling at about half the cost.

Deviations from §1–§7, and why:
- **Selector applies a re-order, not `replaceUpcoming`.** `replaceUpcoming` refuses every row with
  `plan == nil` (every row of an ordinary playlist), so it could never move them. `applyDJOrder` is
  the same discipline (uid-verified at apply time, fixed rows re-checked, one queue assignment).
  "Hand-moved / manual" therefore means rows the listener placed in THIS session
  (`djFixedUids`) plus `plan.pinned` — the original play order is the selector's to arrange.
- **Next-row runway rule** is `isReplaceablePosition`'s 30 s rule without its `plan != nil`
  requirement (same reason).
- **Plan window**: 40 upcoming rows per plan (a 26k-row queue keeps its far tail in order).
- **Tail chain includes the compressor** (the spec lists timePitch → filter → reverb → delay): the
  outgoing's own compressor setting must carry or the handover would change its sound. The tail
  gain is its input mixer (like the main chain's `inputMixer`), so it reads player → gain → … .
- **Main leveling** sits on a dedicated `levelTrim` EQ (globalGain only) after the flanger, not the
  filter EQ (whose globalGain is the >100 % volume boost); the tail folds its level into its filter
  EQ's globalGain beside the boost.
- **Listener touch** during ANY phase ends the glide (not only the post-roll); a stem toggle / mute
  BEFORE the advance hands the outgoing back to the main chain (the stem handover can't run on the
  tail; it runs once the hand-back lands); after the advance the stems are the incoming's and the
  fade carries on.
- **Phase align** from the incoming's top: a backward offset is taken one beat later (same phase)
  instead of being clamped away.

Not done / follow-ups: device verification (locked phone + CarPlay across a transition, the
DeadAirMeter on DJ advances, audible handover); the planner `State` is persisted but the texture
run isn't (a restore re-rolls); the Settings toggles apply at the next track / transition (no live
re-level when Volume is flipped mid-song).
