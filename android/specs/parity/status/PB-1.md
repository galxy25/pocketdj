state: implemented

# PB-1 - SetlistSequencer core

Tests: 1143 total, 0 failed, 0 skipped (`./gradlew :app:testDebugUnitTest :app:assembleDebug` green at the committed tip).
New this package: SetlistSequencerTest 31, LiveEditsTest 18, RepeatShuffleTest 9, ResolveLadderTest 15, QueuePlanTest rewritten (6, replaces the old build/Plan tests).

- [x] sequencer/: QueueItem(uid), RepeatMode, AdvanceCause, SequencerState, PlayerPort, RowSourceResolver (+Rung, LocalFileRowResolver, ManifestRowResolver), RowResolverRegistry, LocalFileResolver, EditionDecider, SetlistSequencer
- [x] SetlistSequencer: play/replace + captured context/origin, natural end (ONE / repeatCount / next / ALL wrap+reshuffle / stop), dead source advances never replays, skipPrevious floor/wrap, all live edits (tail-only, uid-addressed), shuffle canonicalOrder, nearest-occurrence `adoptCursor`, device-mode UNPLAYABLE_HERE + deviceQueueUnplayable banner signal, `playUrl`, `appendRows(runTag)`/`currentIndex()`, held-for-resume seam (restoreHeld/resumeFromHold)
- [x] Single start funnel `startPlayCurrent` (LAZY job, assign, start): cancelled jobs never claim a generation; post-await writes guarded by generation; superseded load/resolve errors never advance the newer row
- [x] PlaybackController rewired: `Media3Port` loads ONLY the current row; `playQueue/playSetlist` go through the sequencer (context captured by setlist id); next/previous/stop route to it; single-row play of a queue member adopts the cursor, album queue abandons the run; ExoPlayer STATE_ENDED / unrecoverable error feed handleEnded/handleFailed (only while the sequencer owns the player)
- [x] PlaybackSettings (PlaybackMode cloud/device, sticky repeat pref keys), PlayOutcomeRegistry fan-out, NowPlayingRoutes (empty entry list consumed by PlaybackGraph), PlaybackGraph wiring
- [x] PlayContext.runTag, PlayStarted.originCollectionId, PlaybackContract extras (EXTRA_RUN_TAG, EXTRA_ORIGIN_COLLECTION_ID)
- [x] SetlistDetailScreen: uses playSetlist(sl) (sequencer captures context)
- [x] JVM tests

## Deviations / files touched outside the owned list (all minimal, additive)
- `playback/PlaybackService.kt`: History emit reads the two new extras (runTag, originCollectionId).
- `di/AppGraph.kt`: one line `init { playbackGraph.wire() }` after `playbackController` (connects historyContext/originCollection/outcome seams). The sequencer itself is built inside PlaybackController (it owns the Media3 port) and exposed via `PlaybackGraph.sequencer`, not as an AppGraph `val`.
- `FeatureModule.rowResolvers` is the display-row `RowResolver(prefix, ...)` (SURF-1); the playback ladder is a different concept, so it is NOT aggregated from it. Rungs register on `PlaybackGraph.rowSourceResolvers.register(...)` (SVC-4 / STU-7 / PB-8 / PB-3 call that from their sidecars). No edit to shell/FeatureModule.kt.
- `PlayOutcomeListener` interface stays the shell one (SURF-1); `playback/outcome/PlayOutcomeListener.kt` holds `PlayOutcomeRegistry` (fan-out). Producers: sequencer emits completed(1.0) on natural end and skipped(<0.5) on user advance-away only when a listened fraction is known (`progressProvider`, wired to the live player position). PB-5 SkipTracker supersedes the fraction source.
- `QueuePlan.build/Plan/PlannedItem` removed (nothing resolves or repeat-expands at build time any more); `QueueOutcome.Started.skippedEntryCount` is now always 0 (skips happen per row at its turn, logged `[playback] advance: unplayable ...`). QueuePlanTest rewritten.
- Default ladder has NO Apple Music / rip-on-demand rung (PB-8 / PB-3 register theirs); single-row ▶ keeps its own AM + preview + rip-on-demand ladder in PlaybackController. Within a run, a rip-required / AM-only row is therefore skipped as before until those packages land.
- Playback mode (`playbackMode` pref, default cloud) has no Settings UI yet; read-only via PrefKey.
- The gapless 2-item window, start watchdog, resolve-stall hop, cascade breaker (only an `autoAdvanceGate` seam), durable session persistence, SkipTracker, DeadAirMeter are other packages (PB-2..PB-10) and are not here.
- `playUrl` mediaId is `url:<url>`; PlayStarted for it records a History row keyed by that id (jukebox package should filter or accept).
- Emulator steps not run (emulator owned by the integrator): logcat `[playback] track start song=... index=i/n backend=rip`, 10x rapid skip, metadata-only row skip.

## Questions for Levi
- Should a user-picked playback mode (cloud/device) get a Settings control now, or wait for the burn store (SVC-4)?
- Inside a run, should an Apple-Music-only row (PB-8) be allowed to take over from the sequencer when AM end detection exists, or skip as today? (Defaulted: skip.)
