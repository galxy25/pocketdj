state: merged

# MIX-0 Mix models, FX rack types, pure math

- [x] Camelot.kt (parse/rank/signedSteps/hue)
- [x] MixModels.kt (Deck, MeterSource, Effect, FilterMode, EQBand, AutoRepeatMode, MixSource, MixLoadable, LoadedTrack, AutoMixItem, MixRanges)
- [x] FxRack.kt (EffectVariant, ModSource/Rate/Shape, SlotMod, FXSlot, FxRack defaults, FxParams curves + modulation math)
- [x] BeatMath.kt (lastBeat/isDownbeat/sliceBoundaries/sliceStarts/cyclePhase)
- [x] MixMath.kt (crossfade, octaveFolded, syncRate, loop, glide, splitmix64/rollTexture/fxSeed, stream math, handover, ThroughputWindow, ETA)
- [x] Tests: CamelotTest, BeatMathTest, MixMathTest, FxRackTest, FxParamsTest

## Notes
- Test count 275 -> 392 (+117), 0 failures. assembleDebug green.
- FXSlot is an immutable class (mutators return new slots) so the variant/effect invariant cannot be bypassed via copy().
- PRNG uses ULong (SplitMix64 holder); verified against the published seed-0 splitmix64 vectors and FNV-1a("a").
- Reverb preset / filter type are Android-neutral enums (no AVAudioUnit); the DSP packages map them.
- No files touched outside owned set (Camelot.kt and FxParamsTest/CamelotTest per roadmap files list; FxRackTest per audit unit_tests).

## Review
- MINOR ARCHITECTURE-ANDROID.md ledger row -> fixed (set to "In progress (parity/MIX-0)"; flip to Merged/DONE at merge time).
- MINOR SlotMod unvalidated via FXSlot constructor -> fixed (FXSlot normalises `mod` in every construction path; test primaryConstructorNormalisesMod added).
- NIT Camelot trim -> fixed (trims only space/tab like iOS .whitespaces).
- NIT ThroughputWindow thread-safety -> fixed (KDoc: single-thread confined, owner serializes).

fixes applied. Tests 392 -> 393, 0 failures; assembleDebug green.
