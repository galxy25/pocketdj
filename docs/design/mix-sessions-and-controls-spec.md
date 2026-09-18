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
careful stepping never dismisses mid-adjust — except where the reveal hosts more than a slider (the
FX rack's two menus, below), where browsing reads as idle and the timer is opt-out (`autoDismiss:
false`); those close on an outside tap.

### 1a. The FX rack (4 slots)

The deck's 2×2 FX grid is a **rack of four positional slots**, not four fixed effects. Each slot
holds any effect FAMILY plus a VARIETY of it, and **duplicates are legal** — a low-pass in one slot
and a high-pass in another, or two compressors, is a valid board.

| Family | Varieties |
|--------|-----------|
| Filter | Low-pass · High-pass · Band-pass |
| Reverb | Room · Hall · Plate · Cathedral |
| Modulation (`flanger`) | Flanger · Chorus · Echo |
| Compressor | Punch · Glue · Limit |

- **Default layout** = the pre-rack grid (Comp, Reverb, Flanger, Filter) at the varieties that
  reproduce the pre-rack sound exactly (Punch / Hall / Flanger / Low-pass), so nothing changes for an
  existing user until they touch it.
- **UI**: the chip shows icon + variety ("Hall", "HP", "Glue"). Tap toggles. Long-press /
  right-click reveals the strength control flanked by the **effect** menu (left) and the **variety**
  menu (right).
- **Audio**: every slot pre-allocates one node of every effect type and un-bypasses only the one it
  holds, so a swap is a bypass flip — the graph is wired once at build and **never** rewired, and
  changing effects mid-mix can't gap playback. Cost: 16 FX nodes per deck (≈ +14 MB with both decks
  fully engaged).
- **↺ Reset** silences the rack (every slot off, strength re-centred) but **keeps its layout** — the
  board is configuration, like the loaded track and the Lead role.
- **Other surfaces** (CarPlay, TV, Now Playing mini-panel) follow whatever the rack holds — on/off
  (and strength where they had it) per slot — but don't build it; swapping lives on the Mix deck.
  Their effect-keyed calls resolve **first-match** within a family.
- **Auto-DJ FX glide** resolves its rolled texture to a slot per deck (first of that family, else the
  first sweepable one, else none — an all-compressor rack sits the glide out) and sweeps only that
  slot's on/off + strength, never its family or variety.

## 2. Gain boost to 200%

Deck volume now ranges `0…2.0`. The graph keeps the documented 0…1 `volume` on the player + stem
source nodes and adds the **>unity** portion as a separate gain stage:

- `deckGain` clamps the deck volume to `min(v, 1.0)` × the equal-power crossfade factor — the shared
  value feeding both the main `player.volume` and every stem node, so neither exceeds 1.0.
- `applyBoost(deck)` puts the boost on the deck's dedicated **trim** node's `AVAudioUnitEQ.globalGain`
  = `20·log10(max(v, 1.0))` dB (0 dB at ≤100%, +6 dB at 200%). Trim sits downstream of the deck's
  `inputMixer`, so the boost lifts the main file **and** all four stems uniformly, and UPSTREAM of the
  main/cue split, so the cue monitor's boost divide-out stays valid. Its single band is permanently
  bypassed — the node exists purely to carry this gain. `applyBoost` runs on volume-change / reset /
  build only — **never** the crossfader path — so an equal-power fade doesn't re-write the boost.
  *(Pre-FX-rack this rode the deck's filter EQ; once "filter" became a swappable slot effect that a
  rack may not contain at all, the boost needed a node that is always present.)*
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
  effectStrength, eq, effectSlot, effectVariant, stemMode, stemMute, stemVolume, lead, sync,
  resetDeck` (+ legacy `filterMode`, decoded but no longer emitted) + an `unknown(raw)`
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

### Session name & rename
The session **name** is a pill **in the Mix content** (centered, just under the nav bar), NOT a toolbar
item — **tap/click** renames, **right-click (macOS) / long-press (iOS)** opens the session menu
(Rename / New / All Sessions) via `.contextMenu`. It deliberately lives in the content because macOS
reserves a *toolbar* item's right-click for its own "Icon Only / Icon & Text" menu, so a toolbar title
can never host a right-click → Rename. The same right-click / long-press → **Rename** is also on every
**Sessions-list row** (swipe or context menu). The nav bar just shows the screen name ("Mix"); the
discrete **Sessions** (history) and **Reset (X)** buttons sit on the leading edge.

## 4. Replay (`Views/MixSessionsView.swift`)

The Sessions screen lists every session (name, date, duration, track/action counts, a "Current"
badge, swipe-to-delete, and **swipe / context-menu Rename**). Opening one shows a **replayable
timeline**: actions laid out **vertically**
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
