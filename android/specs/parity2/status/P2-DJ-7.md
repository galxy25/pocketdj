state: in-progress

# P2-DJ-7: NP DSP two-deck transition engine

- [x] RenderParams.kt: `ParamsComposer.setLevelDb/levelDb` (per-deck leveling added to the boost trim; crossfader moves and boostWrites untouched)
- [x] NowPlayingDspEngine: live deck is now a var (ping-pong A<->B), glide overlay on the live deck, per-song state swap seams (`dj*` internals), `setLevelDb`, transport/stem/listener hooks
- [x] DjTransitionEngine.kt: spec types, `DjEngineDecline` (pure ordered check), state machine (arm, begin, preroll, fade, postroll, cut/hand-back, ease), 50 Hz `step()` + ticker
- [x] DjTransitionEngineTest
- [ ] full suite + assembleDebug green
