state: merged

# P2-DJ-7: NP DSP two-deck transition engine

- [x] RenderParams.kt: `ParamsComposer.setLevelDb/levelDb` (per-deck leveling added to the boost trim; crossfader moves and boostWrites untouched)
- [x] NowPlayingDspEngine: live deck is now a var (ping-pong A<->B), glide overlay on the live deck, per-song state swap seams (`dj*` internals), `setLevelDb`, transport/stem/listener hooks
- [x] DjTransitionEngine.kt: spec types, `DjEngineDecline` (pure ordered check), state machine (arm, begin, preroll, fade, postroll, cut/hand-back, ease), 50 Hz `step()` + ticker
- [x] DjTransitionEngineTest
- [x] full suite + assembleDebug green

## Summary
`DjTransitionEngine` (owned by `NowPlayingDspEngine.dj`): `armDj(lead){spec?}`, `beginTransition(spec): String?` (null = began, else decline reason), `cutTransition(reason)`, callbacks `onFadeStart(songId): Boolean` (false = refuse, outgoing handed back), `onTransitionEnded(songId?, how)`, `onHandBack(atSec)`, `onDeclined(reason)`. `DjTransitionSpec(plan, glide, texture, outgoingBeat, incoming: DjIncoming(songId,file,startMs,lengthMs,beat,levelDb))`. Ping-pong: incoming opens on the idle deck (silent), equal-power crossfader is the fade, per-deck leveling via `ParamsComposer.setLevelDb`, ramps from `step()` (50 Hz ticker only while running; fake clock injectable). Pause pauses both decks, seek cuts the other deck, stop (disengage) cuts everything, listener touch (rate/pitch/effect) ends the glide with no jump, cut before the advance hands back at the playhead with a 0.5 s ease, after the advance the tail ramps out over 40 ms. Decline list in `DjEngineDecline.check` (pure, ordered). Generation bumped at the commit (`djCommitFlip`) before the tail's voices are stopped.

## Tests
22 new in DjTransitionEngineTest (incl. composer leveling). Full `:app:testDebugUnitTest :app:assembleDebug` green; 6847 tests, 0 failures (22 new DjTransitionEngineTest cases + composer). assembleRelease not run (no manifest/gradle/proguard/library change).

## Deviations
- The engine's per-song state (and listener controls) flips onto the incoming deck at the FADE START, not after the fade: the host advance (card, FX Lock stamp, stem lock) happens there and must address the incoming. The outgoing becomes the tail (`tailPresent`) until the fade lands. `liveDeck` is therefore B from fade start.
- `onFadeStart` returns Boolean (iOS parity: false refuses). Names `DjEngineDecline` (engine) vs the conductor's own `DjDecline` (P2-DJ-8) are deliberately distinct.
- A retired deck is not `resetDsp`'d live (render-thread unsafe); it drains idle. Reverb/flanger rings are cut when the chain goes idle (~0.2 s), not the iOS 2 s ring-out.
- Watch floor is 0.3 s (the decline floor), not iOS 0.75 s. The lead-window watch runs on the existing 4 Hz `tick()`.
- Incoming phase alignment ignores tempo-glide rate differences; a negative offset waits one beat.
- `NowPlayingDspEngine.setLevelDb(db)` added for the live deck (host leveling of non-DJ starts); `beginGraph` resets level and overlay.

## Files touched outside owned list
None.

## Questions for Levi
None.

## Review

- cut reason lost in FADING -> fixed (cutReason field; endFade finishes with it; test aSeekDuringTheFadeReportsTheSeekReason)
- decline order (unreadable before too-close) -> fixed (TOO_CLOSE path probes the incoming and releases it; test anUnreadableIncomingWinsOverTooClose)
- seek in PREROLL hands back stale playhead -> fixed (no onHandBack for reason "seek"; test aSeekInThePreRollDoesNotHandBackAStalePlayhead)
- reset() stale state (NIT) -> fixed (clears glideDropped, fadeProgress, running ease overlay)

fixes applied
