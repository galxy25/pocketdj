state: implemented

# MIX-17 Slot modulation (LFO beat-locked + envelope follower) on the FX rack

- [x] ModController.kt: `ModMath` (pure: isLive, effectiveStrength, lfoPhase over the track grid in SOURCE time, clockPosition extrapolation, est./no-grid predicates) + `ModController` (~16 ms TickDriver tick, only while a playing deck has a live modulating slot; phase derived from the playhead each tick; envelope from the deck chain follower with 0.5 s stale = silence; 0.002 dead-band; one-shot snap-back; self-terminating; selecting LFO force-hydrates the beat grid)
- [x] Engine seams (additive, MixEngine.kt/GlideMachine.kt): `slotStrengthProvider` (every write path, incl. Auto-DJ glide via `slotParamList`, composes base + wobble), `onSlotsChanged(deck, modChanged)`, `reapplySlots`
- [x] SlotModSheet.kt + `SlotModSheetRules`: source Off/LFO/Env, rate menu, shape menu, phase quarter-step, signed depth slider, "est." / no-BPM hint, Reverb/Compressor note, envelope note
- [x] Wiring: di/MixGraph `modController` (installed with the engine); MixScreen opens the sheet through the `DeckHost.onMod` seam; FxSlotChip MOD button also closes the strength reveal
- [x] Tests: ModControllerTest (18)

## Tests
JVM suite 4718, 0 failures (+18); assembleDebug green.

## Touched outside owned files (all additive/minimal)
mix/engine/MixEngine.kt, mix/engine/GlideMachine.kt, di/MixGraph.kt, screens/mix/MixScreen.kt, screens/mix/FxSlotChip.kt.

## Notes
- Model (SlotMod, FxParams.modulated), `.effectMod` event, and optional mod* persistence already existed from earlier packages; verified by tests.
- Chip glyph: existing Timeline icon on a modulated slot chip kept (no per-shape glyph).
- Emulator step not run (no emulator per instructions); ledger row left to the integrator.

## Device-only
Audible sweep; mixdiag mod lines.

## Questions for Levi
- None.
