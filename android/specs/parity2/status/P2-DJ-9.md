state: implemented

# P2-DJ-9: DJ skip mix: ⏭ mixes over the Skip fade; double-tap and lock-screen/Auto/headset/widget ⏭ = 5 s sweep

- [x] DjSkipMix (pure phase rules, pending skip keyed on the run's incoming, same-skip rule, fast upgrade) + DjSkipHooks/DjSkipResult
- [x] DjConductor: skipMix, fade start takes the pending skip (USER advance, refusal still skips), cleared on cut/disarm
- [x] SetlistSequencer.skipNext(fast) routes to the hooks; advanceAtDjFadeStart(skip); pending cleared on start/advance/previous/run end
- [x] DjTransitionEngine: skipDuringPreRoll / abandonForSkip / endPostRollForSkip / shortenFade / outRate (additive)
- [x] Wiring (DjModeWiring), SequencerForwardingPlayer (remote next = fast), WidgetBridge NEXT = fast
- [x] Tests; `:app:testDebugUnitTest :app:assembleDebug` green

## Summary
`SetlistSequencer.skipNext(fast)` asks `djSkip` (DjSkipHooks, bound by DjModeWiring) first. `DjSkipMix` implements the iOS rules: idle = `buildTransition(skipFade)` (conductor decline list in skip mode, `immediatePlan` cut to max(1, runway-0.5)) then `beginTransition`; pre-roll = drop it and fade now (paused = abandon + immediate advance); fade = ignored; post-roll = end the glide, mix out of the new song. Pending skip is keyed on the run's incoming and cleared by every start/advance/previous/run end, by a cut, and by disarm. At the fade start the conductor takes it: a skip advances via `advanceAtDjFadeStart(skip=true)` = USER transport (noteUserTransport, lifts the cascade halt, ignores repeat-one/count because the cursor just moves on, meter cause `skip`), and a refused skip fade still skips (posted immediate advance, press already reported). The skip tracker is told at the PRESS (before the synchronous fade-start advance on Android). Remote `seekToNext*` (callerInternal=false), widget NEXT use `fast=true`; in-app NP and mini-bar ⏭ call `seq.skipNext()` (Skip fade at once). A second ⏭ (in-app tap or remote) inside a skip's own crossfade upgrades it to the 5 s sweep (`DjTransitionEngine.shortenFade`, progress preserved); no double-tap detector.

## Tests
7296 total, 0 failures. This package added 37 (DjSkipMixTest: phase rules, same-skip, pre-roll runway cut, upgrade, conductor fade-start of a skip / refusals / repeat-one override, sequencer USER-transport advance, hooks routing, pending clears). assembleRelease not run (no manifest/gradle/proguard/library change).

## Deviations / files outside the owned list
- Touched (additive): DjConductor (skipMix, Env defaults), DjModeWiring (Env impls, skip hooks), DjTransitionEngine (skip/shortenFade/outRate), SequencerForwardingPlayer's SequencerControl got `skipNextRemote()` (default = skipNext, so fakes stay valid).
- Android fade start is synchronous (no 60 ms handover like iOS), so a skip from idle is already FADING when the second tap lands; the upgrade is therefore a shorten of the running skip crossfade (any second press, in-app or remote). NowPlayingTransport.kt / MiniPlayerBar.kt left untouched: in-app taps already call `seq.skipNext()` and no pointerInput detector exists (release blocker 0c696c9a).
- Android Auto's own ⏭ goes through the media session (remote -> fast); AppAutoServices' Mix tab skipFast/skipSlow is a separate Mix engine path, unchanged.
- NOT verified on the emulator (shared, integrator-owned): `[dj] skip mix ...` logcat lines (mine are `skip song=a -> b mix fade=15.0s`), `KEYCODE_MEDIA_NEXT`, double tap. Headset/DHU device-only.

## Questions for Levi
None beyond roadmap needs_levi (default taken: tap acts at once, second tap upgrades).
