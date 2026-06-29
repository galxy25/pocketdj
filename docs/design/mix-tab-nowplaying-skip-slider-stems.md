# Mix Tab — Lock-screen Now Playing, Auto-Mix Skip, Slider-freeze fix, Stem-silence fix

> **Status: SHIPPED.** A second batch of Mix-tab work on the first-party `AVAudioEngine` engine
> (`apple/PocketDJ/Mix/MixEngine.swift`) + SwiftUI Mix tab (`Mix/MixView.swift`). Five items:
> (1) fix the playback-position slider freezing after a drag, (2) feed the **iOS/macOS lock-screen
> Now Playing** card from the Mix, (3) an Auto-Mix **Skip** button (single-tap = configurable fade,
> double-tap = fast 5 s sweep), (4) keep an Auto-Mix running across tab switches, (5) fix stem mode
> going **silent** when toggled after interrupting an auto-mix. Builds on
> [mix-switchboard-engine] + [mix-stem-playback] + [mix-sessions-and-controls-spec].

## 1. Playback-position slider freeze (bug)

`DeckSeekSlider` (`MixView.swift`) showed `scrubbing ?? engine.position(deck)`. Because Swift `??`
**short-circuits**, whenever a scrub value was held the observed `engine.position(deck)` was never
read during `body` evaluation — so SwiftUI **Observation dropped the dependency** on `positionA/B`
and the slider stopped following playback. It only recovered when the view was destroyed/rebuilt —
which is exactly why *switching tabs "fixed" it*. The inline `scrubbing = nil` on drag-end was also
unreliable: SwiftUI can deliver one more binding `set(_:)` **after** `onEditingChanged(false)`,
re-stamping the sentinel and freezing it permanently.

**Fix:** always read the playhead, and gate the drag value behind an explicit `editing` flag:

```swift
let live = engine.position(deck)        // ALWAYS read → the Observation dependency never drops
let shown = editing ? scrub : live
Slider(value: Binding(get: { … shown … }, set: { scrub = $0 }),
       onEditingChanged: { began in
           if began { editing = true; scrub = live }
           else { editing = false; engine.seek(deck, toSeconds: scrub) }   // a late set() lands in
       })                                                                   // scrub, ignored (!editing)
```

## 2. Lock-screen Now Playing (`MPNowPlayingInfoCenter`)

The Mix now drives the system Now Playing card (lock screen / Control Center / Mac menu bar).

- **Which track** (`MixEngine.nowPlayingDeck` / `nowPlaying`): if exactly ONE deck is actively
  **playing**, that deck ("the only active track"); otherwise (zero or both playing) **Deck A**
  regardless of play state — falling to Deck B only when A is empty; nil when neither is loaded.
- **The card** (`updateSystemNowPlaying`) sets title/artist/duration, the elapsed time, and the
  **playback rate = the deck's tempo** (so the lock-screen scrubber moves at the audible speed). It's
  pushed on every transport change — `setPlaying`, `seek`, `load`, and the auto-mix deck switch — and
  the system interpolates elapsed in between.
- **Arbitration** (`NowPlayingArbiter`, `Playback/NowPlayingArbiter.swift`): the standalone
  `PlayerEngine` (row / set-list / background-audio) and the `MixEngine` both write the one global
  card and both register handlers on the one shared `MPRemoteCommandCenter`. A tiny single-owner
  arbiter (whoever last **started** audio owns it) gates every card write and command handler with
  `isActive(self)`, so the two never stomp each other and the lock-screen transport drives whichever
  source you're actually hearing. PlayerEngine's existing background-audio behaviour is preserved —
  it reclaims ownership whenever it plays.
- **Scope (v1):** the lock-screen **play / pause / toggle** drive the Mix while it owns the card.
  The lock-screen **⏭ (next)** handler is wired to the auto-mix skip but only surfaces if the shared
  `nextTrackCommand` is enabled (PlayerEngine disables it by default for its set-list logic), so in
  practice the in-app Skip button (item 3) is the primary skip control.

## 3. Auto-Mix Skip button

Under "Play both decks", visible only while `engine.autoMixing`: **single tap** = advance to the
next track crossfading over the configurable `Settings ▸ Mix ▸ Skip fade` (default **15 s**);
**double tap** = a fast **5 s** sweep. It is a plain tappable view (NOT a `Button`, whose primary
action fires on the first tap) with two `.onTapGesture(count:)` — `count: 2` declared first so a
double tap disambiguates to the fast path.

Engine: `skipToNext(fadeSeconds:)` reuses the automatic crossfade machine — it just sets the fade
length and calls `beginAutoCrossfade(now:)`; the tick's existing ramp + `finishAutoCrossfade` advance
the queue and pre-load the next track. It's ignored mid-fade (no double-advance) and ends the mix on
the last track. A `pendingFadeRestore` puts the baseline `autoFadeSeconds` back when the crossfade
finishes, so a one-off fast skip never shortens the next **automatic** crossfade.

New setting `skipFadeSeconds` (default 15) is a **duration** like `autoMixFadeSeconds` — deliberately
distinct from `autoMixLeadSeconds` (a trigger threshold that happens to also default to 15). Optional
on `SettingsData` for backward-compatible decode.

## 4. Auto-Mix survives tab switches

The `MixEngine` is app-scoped (`@Observable` env object), its ~10 Hz tick is an engine-owned
unstructured `Task`, and the audio graph is engine-owned — so a running auto-mix's **audio +
crossfade automation already continue** when you leave the Mix tab (nothing tears them down;
`MixView` has no `.onDisappear` and `teardown()` has no tab-switch caller — a load-bearing omission
now commented in `MixView`). The only thing lost on the view rebuild was the view-local `autoSource`
picker, which made the toolbar label blank back to "Collection". Fixed by stashing the source name on
the engine (`autoSourceLabel`, set in `startAutoMix`, cleared in `endAutoLoop`) and reading it back in
the toolbar.

## 5. Stem mode silence after interrupting an auto-mix (bug)

`setStemMode(true)` muted the main player and set `stemMode = true` **before** confirming the stems
scheduled — `_ = scheduleStems(…)` discarded its `Bool`. `scheduleStems` schedules zero frames when
the playhead is at/after the stem file's end, which the **auto-mix tick provokes** by pinning a deck's
playhead at its `duration`. So after interrupting an auto-mix near a track's end and toggling stems,
the deck went **silent** (main stopped AND stems unscheduled) until you toggled stem mode back off.
S3 was ruled out: the stems for the reported tracks (Herbie Mann *Memphis Underground*, Roy Ayers
*Better Days* / *Searching*) are present and **non-silent** (mean −24…−47 dB, 4 distinct stems each).

**Fix:** make the ON path transactional — schedule **before** muting, clamp the position to just
inside the shortest stem (`maxStemSeconds`), and **bail (keep the main playing) if nothing
scheduled**. Plus a `stemsScheduled` flag so `play()`/`playBoth()` re-schedule stems that a prior
`stop()` cleared (end-of-track / auto-mix retirement) instead of starting silent nodes, while a
`pause()`-kept schedule still resumes from position.

## Tests

`MixEngineTests`: `nowPlayingDeck` selection (only-playing → that deck; zero/both → Deck A; only-B
loaded → B; none → nil); `skipToNext` starts a fade & stays mixing, ends the mix on the last track,
no-ops outside an auto-mix. `SettingsStoreTests`: `skipFadeSeconds` default / persist-reload /
legacy-blob coalesce / reset. `SettingsUITests`: the Mix section renders the three crossfade steppers
incl. the new Skip-fade. (470 unit tests pass; iOS + macOS build clean.) The runtime feel of the
slider follow, tab persistence, the lock-screen card, and stem audio are best confirmed on device.
