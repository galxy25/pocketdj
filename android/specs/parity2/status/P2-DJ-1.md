state: reviewed

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

## Review
- GlideMachine.begin skip floor hand-rolled -> fixed: now routes through AutoTransition.immediatePlan with real fxGlide/mixGlide flags.
- MixMath.crossfadeFactor own cosine law -> fixed: delegates to AutoTransition.equalPowerGains; test asserts exact agreement (5802 tests, 0 failures, +1).
- AutoDj import order/blank line (NIT) -> fixed.
- splitmix64 iOS goldens (NIT) -> not done: port compared line-for-line against Swift; published vectors kept.

fixes applied
