state: reviewed

# P2-DJ-8: DJ conductor: decide/decline at track start, advance at fade start (no reload), adoptDsp, hand-back

- [x] DjDecline (ONE decline list: decision, fade-start re-check, skip (DJ-9), chip) + DjConductor (track-start arm, decision + plan, fade-start advance, hand-back log, plain fallback)
- [x] SetlistSequencer.advanceAtDjFadeStart (advanceWithoutLoad NATURAL_END, StartPath.DJ, meter cause `dj`, preload slot forgotten, adoptDsp launch), `currentPlaysRemaining`, `onDjAdoptFailed`
- [x] PlayerPort.adoptDsp (+ DjAdoptedSource); Media3Port: claimForDsp + stop/clearMediaItems + generation bump
- [x] Seams: NowPlayingDspHost (`djAdvanceFor` locks carry onto the engaged incoming, `djPoll`, `resolveLocal`), MixGraph.djAdoptMeta (one card writer), DjModeWiring production Env + engine callbacks (bound lazily on first DJ use), NPLog.DJ, DeadAirMeter.CAUSE_DJ
- [x] ParityFlags.DJ_MODE = true
- [x] Tests: DjDeclineTest (20), DjConductorTest (45: fake Env + real SetlistSequencer)
- [x] `./gradlew :app:testDebugUnitTest :app:assembleDebug` green

## Summary
With DJ Mode on, each local row is engaged on the NP DSP once ExoPlayer is sounding it (the track-start listener + 4 Hz heartbeat `poll`), and the engine's lead-window watch is armed with `conductor.buildTransition()`. The decision runs the shared decline list (transitions off, repeat/count, cascade halt, last row / set repeats, album run playing through, next starts an album side, plain/not-on-DSP, next not local) then plans `advancePlan(secondsLeft x min(1, 1.12/outRate), fade, glide, ...)` with glide only for Tempo/Key, texture only for Effect sweeps, gain only for Volume leveling. At fade start the conductor re-checks the list, then `seq.advanceAtDjFadeStart()` (no load; NATURAL_END; one History play; meter cause `dj`, first audio at once), stages the card metadata for the DSP session player, lets the host apply FX/Stem Lock onto the incoming, re-arms and re-plans; `adoptDsp` leaves ExoPlayer idle. A refusal makes the engine put the outgoing back (metadata undone). Logs: `[dj] transition from=.. to=.. plan=..`, `[dj] declined reason=..`, `[dj] advance at fade start ..`.

## Tests
7089 total, 0 failures (this package added 65: DjDeclineTest 20, DjConductorTest 45; DjModeControllerTest flag assertion flipped). assembleRelease not run (no manifest/gradle/proguard/library change).

## Deviations / files outside the owned list
- Touched (additive): DjModeWiring (engine hooks + production Env), NowPlayingDspHost, MixGraph (djAdoptMeta), NPLog (DJ lane), DjModeControllerTest (flag now true).
- DjDecline has its own `Reason` enum (adds NEXT_NOT_LOCAL/PLAIN beyond DjEndReason) mapped onto DjEndReason for the chip.
- Level (P2-DJ-11), planner replan (P2-DJ-10) and skip mix (P2-DJ-9) are `Env` seams with no-op defaults; the incoming's level is 0 dB until DJ-11 binds `Env.levelDb`.
- Engagement: DJ engages the DSP on ExoPlayer's playhead after the row sounds (swap like a control touch), not at load; first second of each DJ row plays on ExoPlayer.
- Facts (bpm/camelot) come from the catalog + the burn beat grid only; the on-device analysis cache fallback is P2-DJ-11's.
- DEBUG_FORCE_DJ_MODE kept but now a no-op (flag is const true).
- NOT verified on the emulator (shared, integrator-owned): the flag flip, `adb logcat -s PocketDJ.dj`, one-History-play and `deadair cause=dj gap~0` steps remain for the integrator. `scripts/dev/one-at-a-time.sh` refused `--no-quiesce-fin` (LM Studio models resident), so builds ran with the default fin quiesce.

## Questions for Levi
None.

## Review
- MAJOR ParityFlags.DJ_MODE flipped unverified -> fixed: `DJ_MODE` follows `DEBUG_FORCE_DJ_MODE` again (ships hidden); the integrator makes it `true` after the emulator steps (logcat -s PocketDJ.dj, one History play, deadair cause=dj gap~0). DjModeControllerTest.chipWordsAndFlag asserts the gate.
- MINOR adoptDsp ignores generation/current item -> fixed: the sequencer's adopt coroutine re-checks generation + current uid (new test: anAdoptFailureForARowThatMovedOnIsIgnored asserts no adopt reaches the port); PlaybackController.adoptDsp only stops/clears when ExoPlayer holds the outgoing row (or nothing) and bumps its generation only then.
- MINOR buildTransition side effects -> fixed: texture cached per (cur,next) pair (cleared at fade start), one `transition` log per pair, `lastDecline` no longer reset by a build (tests: leadWindowRetriesDoNotConsumeTexturesOrRepeatTheTransitionLog; texture-run test now varies the incoming).
- MINOR onIncomingFailed leaves DSP engaged -> fixed: new Env.disengageDsp() called before playPlain (test aFailedAdoptLetsTheDspGoBeforeThePlainLoad).
- MINOR localSource disk on main thread -> fixed: production Env caches LocalSource (prefetched on IO at track start for current+next, stale hits refresh in background, first miss only resolves inline); test trackStartPrefetchesCurrentAndNextOffTheHotPath.
- NIT DEBUG_FORCE_DJ_MODE no-op -> resolved: it is the real gate again.

Tests: 7092 total, 0 failures (+3). fixes applied
