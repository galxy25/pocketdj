state: in-progress

- [x] AutoTransition.kt (plans, gains, glideParams, ramps, texture, splitmix64, fxSeed, BeatRef/phaseAlignOffset)
- [x] MixMath delegates octaveFolded/syncRate/glide*/splitmix64/rollTexture/fxSeed to AutoTransition
- [x] GlideMachine ramps via outgoingRamp/incomingRamp; AutoDj via advancePlan/immediatePlan
- [x] AutoTransitionTest
- [ ] gradle test + assembleDebug verification

Notes: PhaseAlignMath (audible-lag aware Android math) left unchanged; crossfadeFactor left as-is (double precision) to stay behaviour-preserving.
