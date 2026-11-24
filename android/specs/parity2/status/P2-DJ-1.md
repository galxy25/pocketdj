state: implemented

## Summary
New pure `playback/dj/AutoTransition.kt` (advancePlan/immediatePlan, equalPowerGains, glideParams, outgoing/incomingRamp,
rollTexture, splitmix64, fxSeed, BeatRef + phaseAlignOffset(Ms), constants) ported from iOS. `MixMath` delegates its
octaveFolded/syncRate/glideRate/glidePitch/glideParams/splitmix64/rollTexture/fxSeed to it (public API unchanged);
`GlideMachine` ramps use outgoingRamp/incomingRamp; `AutoDj` advance/immediate fade-cap + pre-roll fit use the shared plans.

## Tests
21 new tests (AutoTransitionTest, iOS vectors as goldens). Full `:app:testDebugUnitTest :app:assembleDebug` green:
5801 tests, 0 failures (baseline 5780). assembleRelease not run (no manifest/gradle/proguard/library changes).

## Deviations
- PhaseAlignMath (audible-lag-aware Mix math) intentionally unchanged; AutoTransition.phaseAlignOffset is the lag-free
  iOS DJ-mode form. `MixMath.crossfadeFactor` left in double precision (behaviour-preserving); `equalPowerGains` uses Float like iOS cosf.
- Texture effect is `AutoTransition.TextureEffect`, mapped to `mix.model.Effect` in MixMath.
- No files touched outside the owned list.

## Questions for Levi
None.
