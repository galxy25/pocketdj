state: implemented

# P2-REM-3 Remote controller gate on every transport surface

Summary: `remote/RemoteRedirect.kt` adds `RemoteRedirect` {PlayPause, Play, Pause, Next, Previous, Seek, PlayItems, PlayNow, Jump},
`RemoteControllerGate` (isController probe + forwarder bound by P2-REM-5; maps the sequencer's `TransportRedirect`; LocalStart refused, never forwarded;
no gate bound = passthrough; silencer registry + `silenceAll()` for NP DSP / Mix decks, bound by P2-REM-6; debug fake-controller flag),
`SystemPauseClassifier` / `SystemPauseState` (noisy, permanent focus loss, transient loss not resumed within 5 s -> `isSystemPaused`, flow exposed).
`PlaybackController` installs `sequencer.transportGate`, gates resume/next/previous/seekTo, and does not claim the engine in playQueue while a controller.
`PlaybackService` listener feeds `SystemPauseState`. `WidgetBridge` PLAY_PAUSE is forwarded. Debug screen toggle "Remote: fake controller gate".
MediaSession / BT / Auto / Assistant / quick play all reach `SetlistSequencer` (already gated by P2-PB-3) or `PlaybackController` (gated here).

Tests: +8 JVM (RemoteGateSurfacesTest). Full suite green, `:app:testDebugUnitTest :app:assembleDebug` OK. assembleRelease not run (no manifest/gradle/proguard change).

- [x] RemoteRedirect.kt gate + classifier
- [x] PlaybackController / PlaybackService / WidgetBridge wiring
- [x] debug toggle (DebugScreen.kt, outside owned list, additive)
- [x] tests, build

## Deviations
- ShellActions / AppAutoServices / SetlistSequencer untouched: their paths funnel through sequencer.play / pc.resume, which are gated.
- `RemoteControllerGate.shared.isController` / `forwarder` and `SystemPauseState.isSystemPaused` / `silenceAll` still need binding by REM-5/REM-6 (SequencerRemoteTarget `systemPaused`, `extraSilencers`).
- pc.pause() is deliberately not forwarded directly (internal parking callers); user pauses reach the sequencer's gated pause.

## Questions for Levi
- none
