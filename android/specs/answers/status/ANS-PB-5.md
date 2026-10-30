state: reviewed

# ANS-PB-5 - PlaybackController pass (Q17 / Q21 / Q95 / Q89c)

- [x] Q17: RipWaitCap (item length -> catalog length -> 10 min, + 60 s slack); begin(songId, capMs) / awaitDurable(job, capMs); RIP_WAIT_CAP_MS removed
- [x] Q21: begin(via, gen, reResolve) traced as `rip-begin song= via= gen= joined= reResolve=` (NPLog RIPREQ); joins an in-flight resolution unless PlayRequest.reResolve; watcher joins instead of beginning; sequencer startCurrent() (idle play) no-ops while the same uid's start is in flight; supervisorRetryInPlace sets reResolve
- [x] Q95: MixIdleResign (park runnable resigns idle Mix owner); Mix eject with nothing parked resigns; PlaybackController.resume() calls yieldMixToExo() before play()
- [x] Q89c: DirectPlaySampler feeds SkipTracker for non-sequencer plays (1 Hz tick in controller, noteReplacing before a foreign/run play, noteStopped on stop)
- [x] tests green (5611 total, 0 failures; 15 new: CloudRowResolverTest +5, SequencerHealthTest +2, SessionSwitchboardTest +2, DirectPlaySamplerTest 6); assembleDebug + assembleRelease green

## Q21 trace / diagnosis
Could not run the emulator (integrator owns it). Static analysis of the two `rip-post begin` lines ~20 ms apart:
1. Media3Port.load did `ripSession.cancel(id); ripSession.begin(id)` (always a fresh POST), and
2. any second load of the same row (idle/remote ▶ -> SetlistSequencer.startCurrent() while the first start was still resolving; or a retry) did the same again, cancelling the first POST and issuing another.
3. The post-load watcher called begin() again: it joined only while the entry existed, but a cancel+begin from a second load raced it.
Fix: one begin per load that joins an active entry; watcher uses join(); startCurrent() guards the duplicate load; only retry-in-place re-resolves. Trace lines carry via=load|watch|retry so the first real device log confirms exactly one `joined=0` per row.

## Deviations / notes
- Auto-DJ stop (stopAutoMix) is not hooked directly: it pauses both decks, which reaches onNowPlayingChanged -> 15 s park -> resign. Eject (nowPlayingDeck==null, nothing parked) resigns immediately.
- Files touched outside the owned list: none (MixSessionPlayer.kt got the MixIdleResign object). The startCurrent guard runs BEFORE noteUserTransport (which clears the cascade halt).
- The "same uid+generation" duplicate-load guard is implemented at the entry point where duplicates actually occur (startCurrent), since every playCurrent bumps the generation.

## Questions for Levi
None.

## Summary
Rip wait cap = item length + 60 s; exactly one POST /rip per row (join in-flight, retry-in-place re-resolves, duplicate idle-play suppressed, traced via=load|watch|retry); idle Mix resigns the session and resume() yields a held Mix to Exo; Browse singles/album queues now feed SkipTracker through DirectPlaySampler.

## Review
- MAJOR resume() yields npdsp/Studio/active Mix -> fixed: PlaybackController.resume() now calls SessionSwitchboard.yieldIdleMixForResume(): yields ONLY a paused Mix (session player not playWhenReady) while ExoPlayer holds an item; never npdsp/Studio, never a playing Mix, never when Exo is empty (play goes to the owner). Tests: SessionSwitchboardTest resumeYieldsAPausedMix..., resumeNeverYieldsNpdspOrStudio, resumeKeepsAMixThatIsPlayingOrHasNoSingleBehindIt.
- MAJOR park resigns during transient focus loss -> fixed: MixIdleResign.resignIfIdle takes interruptionParked (MixGraph passes focus.interruptionParked) and skips. Test: MixAudioFocusTest.parkAfterLongTransientLossDoesNotResign... (loss, park, gain still resumes), plus switchboard test.
- MAJOR resign with nothing to front -> fixed: resignIfIdle takes exoHasItem (SessionSwitchboard.exoHasItem() reads the registered Exo owner's item count); a Mix-only session keeps the paused Mix as remote target. Tests: idleMixKeepsTheSessionWhenExoIsEmptyOrAnInterruptionIsParked, exoHasItemReadsTheRegisteredExoOwner.
- MINOR no Q21 trace recorded -> accepted/partial: emulator is the integrator's, so no device trace; CloudRowResolverTest asserts one joined=0 per row (load, duplicate load, completed-durable restart). Auto-DJ stop resigns only via the 15 s park (now gated by exoHasItem / interruption latch); deviation flagged for the integrator.
- MINOR completed Durable not joined -> fixed: begin() joins a completed Durable result (non-reResolve); Live or reResolve re-POSTs. Tests: completedDurable_isJoinedByAFreshPlay_butReResolveRePosts, completedLive_isNotJoinedByAFreshPlay (replaces the old locking test).
- NIT reResolveNext field -> fixed: reResolve is a playCurrent parameter; field removed.

fixes applied. Tests: 5617 total, 0 failures (was 5611, +6); assembleDebug green.
