state: implemented

# PB-4 - Durable playback session: real-time snapshot, held restore, resume at position, materialize Now Playing setlist, playback-resumption provider

Tests: 2223 total, 0 failed at the committed tip (`./gradlew :app:testDebugUnitTest :app:assembleDebug` green). +34 new tests in `playback/durable/` (PlaybackSessionStoreTest, SessionWriterOrderingTest, SessionWriterRulesTest, HeldRestoreTest, ResumptionSnapshotTest).

- [x] durable/SessionSnapshot.kt: iOS JSON shape (sessionId pses_, source{kind,id,name,originKind,originId}, rows with null variant/editionLocked/repeatCount omitted, index, positionMs, isPlaying, repeatMode, shuffleEnabled, stemLock, updatedAt, schemaVersion 1); lenient decode (bad json / other version / empty queue -> null); fixture ios-playback-session-v1.json
- [x] durable/PlaybackSessionStore.kt: save (immediate), updatePosition (5 s throttle, transitions immediate), clear, flush; on the shared VersionedJsonWriter (stale write can never overwrite newer or resurrect after clear)
- [x] durable/SessionWriter.kt: sequencer state -> store (play/index move = pos 0, edits = live pos, held never written, run end clears, cold start never clears, resume adopts with the held offset, skip-while-held drops it)
- [x] durable/AppLifecycleFlusher.kt (ON_STOP Flushable), durable/ResumptionProvider.kt (SessionRestorer.restoreIfIdle, ResumptionSnapshot, ResumptionProvider)
- [x] SetlistSequencer: additive `sessionId` (minted per play, re-adopted by restoreHeld, nulled on end), `resumeOffsetMs`; SequencerState.sessionId
- [x] CollectionsStore.materializeNowPlayingSetlist (+ QueueRowSnapshot)
- [x] PlaybackGraph: sessionStore/sessionWriter/sessionRestorer/resumptionProvider, flushable, restore-then-observe on Main, 1 Hz tick
- [x] PlaybackService.onPlaybackResumption: restores held, returns a failed future (never auto-plays)

## Deviations / files touched outside the owned list
- `playback/PlaybackController.kt` (1 line): the saved-repeat pref load no longer overrides a run that is already running (it would clobber the restored repeat mode).
- `playback/PlaybackService.kt`: onPlaybackResumption override. `playback/sequencer/SequencerState.kt`: additive sessionId.
- Roadmap unit test name "SessionRestoreTest" is covered by HeldRestoreTest + ResumptionSnapshotTest.
- Stem lock: the Android sequencer has no stem-lock state yet; the snapshot carries `stemLock` (round-trips) and the writer takes a provider (null today).
- Run-tag ghost source ids (iOS nils `sourceSetlistId` for game round ids): Android game runs have no id prefix convention; not applied.
- Variant storage id on restore assumes `<songId>_<variant>` (QueueItem doc convention).
- Position comes from the Exo engine (song-relative via clipping); Apple Music rows are not tracked (PB-8).
- Flush runs on a worker thread (Main is blocked by the funnel), so it persists the 1 Hz-fresh in-memory position, not a live engine read.
- Not emulator verified (emulator not used).

## Questions for Levi
- None blocking.
