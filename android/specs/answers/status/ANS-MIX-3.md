state: merged

# ANS-MIX-3 Mix returns after process death (launch park + Auto Mix row) and Mix disk work off Main

Summary:
- MixGraph.launchRestore(): deck snapshot read on IO, MixEngine.parkRestore(snap) on Main; called once per process from PocketDjApplication's first-foreground hook. Park refreshes the card (onNowPlayingChanged); EngineMixTransportPort.card() shows the parked mix (MixEngine.parkedCard()) and lock-screen play materializes first, then resumes.
- AutoMixTab.root() calls extras.materializePendingRestoreIfNeeded("autoRow") (AppAutoMixExtras: only when a launch restore is parked; never builds the engine otherwise).
- Restore: materializeNow prepares BOTH decks off Main (restoreOffload) then commits atomically on Main (RestorePrep); superseded by any real load/run (restoreGen) -> prepared voices discarded.
- Auto-DJ prepared-load cache: AutoDj.prefetchUpcoming() (next 2 on-device queue items) -> MixEngine.prefetchPrepared via loadOffload; loadNow takes the cache, sync prepare only on miss; cleared on stop/eject.
- Stores: flush() snapshots under the lock, encodes + writes outside it (encoder test seam). MixGraph's ON_STOP Flushable hands off to the writer thread (no main wait); FlushOnStop untouched.
- Tests: 5342 -> 5351 JVM (+9: 4 MixEnginePersistenceTest, 3 AutoDjTest, 2 MixSessionStoreFlushTest), 0 failures; assembleDebug OK.

Files outside the owned list (minimal/additive): auto/AppAutoServices.kt (AppAutoMixExtras override), mix/service/MixSessionPlayer.kt (parked card + remotePlay materialize).

Notes: gradle needed `-Pkotlin.compiler.execution.strategy=in-process -Dorg.gradle.jvmargs=-Xmx5g` (kotlin daemon OOM under parallel load). Emulator/device steps (dumpsys media_session of parked mix, StrictMode, jank) NOT run.

## Questions for Levi
- none

## Review
fixes applied. JVM 5351 -> 5358 (+7: 3 MixEnginePersistenceTest, 2 MixSessionPlayerTest, 2 AutoMixTabTest), 0 failures; assembleDebug OK. Emulator steps still NOT run.
- MAJOR lock screen/MediaSession: FIXED. ParkedMixSession.offer (MixSessionPlayer.kt) makes the Mix player the switchboard's preferred target + ensureMediaService when nothing else owns the session; withdrawIfGone/SessionSwitchboard.resignIfPreferred on eject. Tests assert remoteTarget()===mix after offer, no steal from a sounding owner, withdraw.
- MAJOR Auto with no activity: FIXED. PlaybackService.onCreate calls mixGraph.launchRestore() (once-per-process); AutoMixTab renders a parked-mix row (Paused, label) from extras.parkedMix() (held snapshot, no engine). Tests: row shown, tap resumes.
- MINOR Auto root() materialized on browse: FIXED. root() only describes; the PARKED row / TOGGLE gesture calls resumeParkedMix (materialize, then resume). START supersedes, so no materialize.
- MINOR parkRestore races: FIXED. launchReadInFlight probe: Mix-surface requests (incl. `then` callbacks) wait for launchReadFinished (no sync store.load on Main); parkRestore refuses when restoreSettled or materializing; ejectAll marks settled. 3 tests.
- MINOR engine built on Main at launch: PARTIAL. Snapshot is held in MixGraph (parkedSummary/hasLaunchRestore never build the engine) and the engine is built from a Main idle handler, not inline in the launch frame. Building it at all is required: the session owner (lock-screen card) is created with the engine; iOS parks with no card, Android roadmap wants the card.
- MINOR prefetch coverage: FIXED. prefetchUpcoming also on resumeAuto, restoreSuspended, loadNextUnplayed and queue mutations (shuffle/remove/move/insert); stale entries pruned to the next-2 window.
- NIT late duplicate prefetch: FIXED (lateDiscard). Invalidate on burn/rip-complete: NOT done (cache lifetime is the next-2 window only).
- NIT tests: FIXED. Thread.sleep replaced by a seed-encoded latch; park-after-launchRestore wiring covered at the ParkedMixSession seam (MixGraph itself needs Android).
