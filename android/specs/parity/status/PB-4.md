state: reviewed

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

## Review
fixes applied

- MAJOR positionValid not row-aware -> fixed: `SetlistSequencer.currentRowLoaded` (lastLoadedId == current row id); positionValid = engine loaded AND current row loaded. Test `staleOldRowPositionNeverOverwritesAfterAnIndexMove`.
- MINOR onPlaybackResumption claim -> fixed (comment/doc): Media3 1.6.1 calls play() after a failed future, so an explicit media-button/Bluetooth play resumes the held deck (iOS latched remote play). Exception changed to IllegalStateException (no UnsupportedOperation warning). Media3 onFailure->play path itself is not unit-testable (device-only).
- MINOR writer `resumed` ignored sessionId -> fixed: resumed requires same session (not fresh). Test `heldThenFreshPlay_newSession_persistsZeroNotTheHeldOffset`.
- MINOR restore consumed before collector -> fixed: sequencer `lastResumeOffsetMs`; writer uses it on the first observed running state. Test `resumeConsumedBeforeObserving_keepsTheOffset`.
- MINOR PlaybackController repeat gate -> fixed: skip saved-repeat only for a held restored run (`isRunning && isHeldForResume`).
- MINOR ledger/docs -> rejected for docs/ARCHITECTURE-ANDROID.md edit in this branch (integrator owns the ledger; status file lists gaps: stem lock, AM position, run-tag rule, emulator steps not run). `materializeNowPlayingSetlist` has no UI caller: follow-up (Up Next SETLIST button wiring).
- NIT variantStorageId -> fixed via SongVariant.variantId.
- NIT main-thread double load in provider -> not changed (optional).
