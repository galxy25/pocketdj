state: in-progress

# P2-DJ-8: DJ conductor

- [x] DjDecline (one decline list), DjConductor (track-start arm, decision/plan, fade-start advance, hand-back, plain fallback)
- [x] SetlistSequencer.advanceAtDjFadeStart + meterCause + currentPlaysRemaining; PlayerPort.adoptDsp (Media3Port: claimForDsp + idle/clear)
- [x] Host/MixGraph seams (djAdvanceFor locks carry, djAdoptMeta card writer), DjModeWiring production Env, ParityFlags.DJ_MODE = true
- [ ] Tests (DjDeclineTest, DjConductorTest), full suite + assembleDebug
