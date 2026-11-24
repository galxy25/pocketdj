state: in-progress

# P2-DJ-9: DJ skip mix

- [x] DjSkipMix (pure phase rules, pending skip keyed on the run's incoming, same-skip rule, fast upgrade) + DjSkipHooks/DjSkipResult
- [x] DjConductor: skipMix, fade start takes the pending skip (USER advance, refusal still skips), cleared on cut/disarm
- [x] SetlistSequencer.skipNext(fast) routes to the hooks; advanceAtDjFadeStart(skip); pending cleared on start/advance/previous/run end
- [x] DjTransitionEngine: skipDuringPreRoll / abandonForSkip / endPostRollForSkip / shortenFade / outRate (additive)
- [x] Wiring (DjModeWiring), SequencerForwardingPlayer (remote next = fast), WidgetBridge NEXT = fast
- [ ] tests green, assembleDebug
