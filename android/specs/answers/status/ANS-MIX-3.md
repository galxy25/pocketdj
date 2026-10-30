state: implemented

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
