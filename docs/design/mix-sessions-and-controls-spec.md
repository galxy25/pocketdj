# Mix Tab — Sessions, Fine-Adjust Steppers & Gain Boost

> **Status: SHIPPED.** Built on the first-party `AVAudioEngine` Mix engine
> (`apple/PocketDJ/Mix/MixEngine.swift`) and the SwiftUI Mix tab (`Mix/MixView.swift`). Adds three
> things: (1) −/＋ fine-adjust steppers on every Mix slider, (2) deck gain up to **200%**, and
> (3) **mix sessions** — a recorded, replayable, persisted log of everything you do in a mixing
> sitting, intended both for human replay and as a training corpus for a future auto-mix model.
> See the as-built engine in [Architecture Ch. 4 §7](../architecture/04-performance-engine.md).

## 1. Fine-adjust steppers

Every Mix slider is flanked by `[−]` / `[+]` buttons (`StepButton` in `MixView.swift`) that nudge the
value by a fixed fine step, for adjustment finer than a drag affords:

| Control            | Range        | Step |
|--------------------|--------------|------|
| Tempo              | 0.5…2.0×     | 0.01×|
| Pitch              | −12…+12 st   | 0.1  |
| Vol (gain)         | 0…200%       | 0.05 |
| Effect strength    | 0…100%       | 0.05 |
| Stem volume        | 0…100%       | 0.05 |

Placement honours the existing chip-flip design (`native-portrait-slider-popover`): the deck
Tempo/Pitch/Vol sliders carry steppers inline; the effect/stem chips show steppers in their
**reveal** surface — the in-place flip on iPad/macOS (regular width) and the fixed-width **popover**
on **all** compact iPhone widths (portrait *and* landscape, so the cramped landscape chip never hosts
an in-place slider). Each stepper tap also restarts the chip/popover's 3 s idle-revert timer so
careful stepping never dismisses mid-adjust.

## 2. Gain boost to 200%

Deck volume now ranges `0…2.0`. The graph keeps the documented 0…1 `volume` on the player + stem
source nodes and adds the **>unity** portion as a separate gain stage:

- `deckGain` clamps the deck volume to `min(v, 1.0)` × the equal-power crossfade factor — the shared
  value feeding both the main `player.volume` and every stem node, so neither exceeds 1.0.
- `applyBoost(deck)` puts the boost on the deck's filter `AVAudioUnitEQ.globalGain` =
  `20·log10(max(v, 1.0))` dB (0 dB at ≤100%, +6 dB at 200%). The EQ sits downstream of the deck's
  `inputMixer`, so the boost lifts the main file **and** all four stems uniformly. The filter EQ
  **node** is now always active (only its *band* is bypassed when the Filter effect is off), so
  `globalGain` keeps applying; at unity + filter-off it's a transparent passthrough. `applyBoost`
  runs on volume-change / reset / build only — **never** the crossfader path — so an equal-power fade
  doesn't re-write the boost.
- A master **`AVAudioUnitEffect(PeakLimiter)`** sits on the output bus (`mainMixer → limiter →
  output`) so two decks at 200% (plus the compressor's makeup gain) can't hard-clip the device.

The Vol readout shows `150% · +3.5dB` in gold when boosted (a non-color cue + a spoken
`accessibilityValue`), and a drag snaps to unity (0 dB) within a small epsilon.

The split is verified by `MixEngineTests.testGainSplitIdentity`: `min(v,1) · 10^(20·log10(max(v,1))/20)
== v` for all v, with the source-node factor never exceeding 1.0.

## 3. Mix sessions

A **session** records what you play + every mix action, time-stamped relative to the session start.
It lasts until you hit **Reset (X)**, which finalizes it and starts a fresh one. Sessions persist
app-side and are browsable + replayable on a Sessions screen.

### Data model (`Models/MixSession.swift`)
- `MixSessionEvent { id, tMs, kind, deck?, songId/title/artist?, bpm/camelot? (load), param? (fx/stem
  name), value?, flag?, posMs? (deck playhead) }`. The schema is rich enough to **reconstruct** a mix
  for training — a `.load` carries the track's bpm/camelot, and every deck event carries the deck's
  playhead at that instant.
- `MixEventKind`: `load, play, pause, seek, tempo, pitch, volume, crossfader, effectToggle,
  effectStrength, stemMode, stemMute, stemVolume, lead, sync, resetDeck` + an `unknown(raw)`
  lenient-decode sink (a future build's kind never throws away the corpus). It **carries** the original
  rawValue, so an older build that loads then re-saves a newer file preserves that kind rather than
  flattening it to `"unknown"`.
- `MixSession { id, name, startedAt, endedAt?, events[], playedSongIds[] }`; persisted in a versioned
  `MixSessionsDocument { schemaVersion, sessions[], currentId, counter }`.

### Recording (engine → store)
`MixEngine` holds a weak `recorder: MixSessionRecorder?` (the app-side `MixSessionStore`). Every deck
setter emits one event via a `rec()` helper; a single `setPlaying(deck:_:)` funnel records `.play`
(+ marks the song played) / `.pause` only on an actual transition — so manual, master, auto-DJ, and
natural track-end starts/stops are each logged exactly once, and an idempotent re-issue (seek/restart
while already playing) records nothing. The iOS interruption-resume path deliberately bypasses the
funnel (no spurious `.play`). `syncToLead` records its real `.tempo`/`.seek` plus a `.sync` marker;
`resetDeck` records one semantic `.resetDeck` (not a burst of per-parameter resets). The auto-DJ's own
crossfader automation uses a **non-recording** `applyCrossfader`, so a machine sweep never pollutes the
corpus as user `.crossfader` gestures (and a bare Manual→Auto→Manual toggle records nothing at all).

### Store (`State/MixSessionStore.swift`, `@Observable`)
- **Hot path off the observed surface.** The current session's live events/played-set are
  `@ObservationIgnored` buffers, so the ~8 Hz fader stream during a live mix invalidates **no** view.
  Only low-frequency, user-visible state is observed: the current session `name` (toolbar title), the
  `sessions` list (only the Sessions screen reads it), and a `playedRevision` tick (loader checkmarks).
- **Coalescing.** Continuous kinds (tempo/pitch/volume/crossfader/effectStrength/stemVolume) collapse
  to ≤1 event per 120 ms bucket — when the last event is the same kind+deck+param and still inside the
  bucket, its value is updated in place (keeping the bucket-start `tMs`), so a drag downsamples to
  ~8 Hz while preserving the trajectory and the final resting value; a discrete event breaks the run.
- **Persistence.** Discrete events + `notePlayed` save immediately; continuous events ride a 0.6 s
  debounce. Writes are off-main + **version-guarded** (a late stale snapshot can never clobber a newer
  one). `init` LOADS the persisted document and RESUMES the previously-current session (a session
  survives relaunch — it ends only on Reset); on the first action after a relaunch it **rebases the
  timeline t0** so the new event lands just after the last saved one — the hours the app was closed are
  never embedded as dead air in `tMs`/`durationMs`. `flush()` (scene → background) writes
  **synchronously** so an OS suspension can't drop the last events, then bumps the writer's watermark.
- **Lifecycle.** Always exactly one current session (seeded "Session 1" on first launch). Reset on an
  empty session is a no-op (no empty pile-up). Deleting the current session re-establishes one. The
  `counter` is monotonic across rename/delete/relaunch, so "Session N" never collides.

### Played tracks → checkmark / auto-hide
A song is marked **played** when its playback starts on a deck. In the deck's track loader, played
tracks carry a ✓; the **Settings ▸ Mix ▸ Auto-hide played tracks** toggle (default on) hides them
instead, with an in-loader "Show N played" reveal. Auto-DJ-played tracks count too.

### Toolbar
The nav title shows the current session **name** (centered on all three platforms), and tapping it
opens a title menu (Rename… / New Session / All Sessions…) — the reliable cross-platform way to make
the name interactive. Discrete **Sessions** (history) and **Reset (X)** buttons sit on the leading
edge (off the already-crowded trailing auto-mix group).

## 4. Replay (`Views/MixSessionsView.swift`)

The Sessions screen lists every session (name, date, duration, track/action counts, a "Current"
badge, swipe-to-delete). Opening one shows a **replayable timeline**: actions laid out **vertically**
(top→bottom) on iPhone and **horizontally** (left→right) on iPad/macOS, each a color-coded card (deck
A/B chip, kind icon, human sentence, relative `m:ss.S` stamp). A real-time replay clock (play/pause,
0.5–4× speed, scrub) advances a wall-clock-driven `replayMs`, highlights the current event (found by
binary search over `tMs`), and auto-scrolls to it (only while playing, not while the user scrubs).
Tapping a card jumps the playhead.

Replay is **visual** in this version — it does not re-drive the audio decks. Re-performing a recorded
mix on the live engine (and exporting the corpus to train an auto-mix model) is the planned follow-up;
the captured events are already the training data.

## 5. Tests

`MixEngineTests` covers the gain identity + 0…2 clamp + the recorder instrumentation (every setter
emits its event; load→play records + marks played once; a bare Auto on→off records no crossfader;
no-recorder is a no-op). `MixSessionStoreTests` covers naming/reset/rename/delete lifecycle, the
played-set, coalescing (keeps the final value; a discrete event breaks the run; different params don't
merge), lenient decode **+ round-trip**, the **resume re-anchor** (no offline gap baked into `tMs`),
and a persistence round-trip. `MixSessionsUITests` walks Mix → Sessions → replay on iOS + macOS and
asserts the controls render (with screenshots).
