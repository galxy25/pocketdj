state: implemented

# P2-MM-8: Mix Mode ph3b (growing-file start, touch hand-off, holds and fallbacks)

- [x] `playback/npmix/GrowingStart.kt`: pure `GrowingRules` (eligibility matrix, deep-resume <= 15 s rule, `touchCovers`, touch decision), `HoldWatch` (5 s mid-song / 22 s start budget, interruption restarts it), `GrowingStart` StartInterceptor (priority 50) with ledger (growingUid / refusedUid / left stream), generation + row fences, fallback executor.
- [x] `NpMixWiring`: production `GrowingEnv` (loader open/join as Buffer origin, engine `engageStreaming`, card meta staging, sequencer announce, meter), interceptor registered in `install()`, row/session hooks, loader progress listener (registered lazily on first open).
- [x] `NowPlayingDspHost`: `DspHostPorts.growingTouchReady/engageGrowingFromStream`; first control touch on a presigned stream with a covering buffer engages the growing file; `available()` includes it.
- [x] Dead-air: `DeadAirMeter.BACKEND_GROWING = "growing"` via `completeClaimedStart(backend="growing")`; causes `npmix-growing-handoff`, `npmix-fallback`.
- [x] Supervisor: probe returns idle while `growing.ownsAudio` (its own 5 s fallback is the backstop).
- [x] Route loss: already handled by the NP DSP focus machine (`ACTION_AUDIO_BECOMING_NOISY` -> `npFocus.onBecomingNoisy` -> engine pause); a paused engine is not "buffering", so no fallback fires while it is paused. Verified by reading, device-only to prove.
- [x] Tests: `GrowingStartTest` (41 tests): eligibility matrix, resume depth, touch coverage/decision, hold clock, claim order, 5 s fallback position, noisy/interruption holds, generation fences, left-stream fallback, history/first-audio/progress, ledger clear.

Suite: 6444 tests, 0 failures (`:app:testDebugUnitTest :app:assembleDebug` green). No manifest/gradle/proguard change, so no assembleRelease.

## Files touched outside the owned list (minimal, additive)
- `playback/sequencer/SetlistSequencer.kt` (touchpoint): `restartCurrentRow(uid, atMs)`, `contextFor(item)`.
- `playback/PlaybackService.kt` (touchpoint): one-shot `suppressHistoryFor` so a fallback restart records no second History play.
- `playback/health/DeadAirMeter.kt` (touchpoint): `BACKEND_GROWING` constant.
- `playback/PlaybackController.kt`: `claimForDsp()` (AM stop + back to EXO ownership) and `resumeStreamAt()` (resume the stream a touch hand-off left).
- `di/MixGraph.kt`: staged card metadata for a growing engage, `onAudioStarted` -> `growing.onDspAudioStarted()`, two host port overrides.
- `di/PlaybackGraph.kt`: supervisor probe idles while the DSP owns a growing row.
- `playback/npmix/NpMixWiring.kt` (MM-5 file): growing env + registration.

## Deviations
- Analog album-SIDE streams never touch-hand-off (file duration of the whole side is unknown on Android: Exo reports the clip), and a side song minutes in starts plain (iOS rule). Digital files and per-song cuts are covered.
- Stem Lock carry on a growing start: the engine defers stems until the stream completes (MM-7); the host's carry just stands down when the DSP already owns the row. Stems for a growing row follow its completion via `replan()`.
- A mid-song stream death after audio started ends the window at the frontier (the MM-7 engine behavior) instead of falling back; only a pre-audio death falls back.
- A growing start always plays (no startPaused re-entry after a media-services reset: Android has none).
- Apple-Music-first distinction is MM-9's: `appleMusicFirst = false` (Android's ladder never starts a ripped row on AM).

## Questions for Levi
- None.

## Review
- MAJOR mid-song stream death: fixed. `GrowingStart.onStreamProgress` now falls back at the playhead (`stream failed`, engine released by us) when the stream is `failed` and the DSP has already made sound, instead of feeding the engine's finish-at-frontier path. Tests: `aStreamThatDiesAfterAudioFallsBack...`, `aStreamFailureBeforeAudioIsLeftToTheEngineCallback`. (Deviation entry above superseded.)
- MINOR hand-off fallback meter: fixed. `fallBack` opens the fallback meter only on a real restart (plain, or left-stream resume failing); resuming the left stream opens none. Test assertion added.
- MINOR `suppressHistoryFor`: fixed. Now armed via `PlaybackService.armSuppressHistory` with a 15 s expiry, so a restart that never loads cannot swallow a later play.
- MINOR stale `npMetaStaged`: fixed. `clearStagedGrowingMeta()` after every growing engage attempt and in `disengage`.
- NIT awaitingFirstAudio: fixed. New engine `producedAudio` (per-engagement `grow.everStarted`) replaces the per-resume `hasStarted`.
- NIT merge hotspots: noted, merge in dependency order.

Suite: 6446 tests, 0 failures (+2). assembleDebug green.

fixes applied
