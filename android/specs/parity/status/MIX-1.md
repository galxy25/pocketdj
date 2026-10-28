state: reviewed

MIX-1 Durable Mix stores (MixDeckSessionStore decks v1 + MixSessionStore sessions v2) over VersionedJsonWriter.
- [x] mix/store/MixDeckSessionStore.kt (TrackRef/FXSlotSnapshot/DeckSnapshot/AutoRow/AutoSnapshot/MixDeckSnapshot, resolvedSlots, isEmpty/isExhausted, save/saveDebounced/updatePosition/clear/load/flush)
- [x] mix/store/MixSessionModels.kt (MixEventKind w/ Unknown(raw) round-trip, event/session/recording/document, MixSessionRecorder seam)
- [x] mix/store/MixSessionStore.kt (120 ms coalescing, 0.6 s debounce, resume re-anchor, Session N counter, rename/reset/delete/clear, played set + playedRevision, recordings metadata, reloadFromDisk, virgin-flush guard)
- [x] di/MixGraph.kt (own background writer executor, lazies mixDeckSession/mixSessions, ON_STOP flushable, reset hook)
- [x] iOS-shape fixtures + tests: MixDeckSessionStoreTest (18), MixSessionStoreTest (24); suite 854, 0 failures (was 812); assembleDebug green

Deviations / notes
- New file outside the roadmap list but inside owned dir: mix/store/StoreScheduler.kt (injectable debounce scheduler) and test support mix/store/StoreTestSupport.kt.
- AppGraph NOT touched: MixGraph creates its own single-thread writer executor (AppGraph's bgWriterExecutor is private).
- Debounce matches iOS exactly: timer armed on the FIRST saveDebounced of a burst fires 1 s later with the latest state (not re-armed per call).
- Missing "schemaVersion" key in decks file loads null (iOS decode would fail on it too).
- deleteAllRecordings/deleteRecording file sweeps (SessionFolders/bookmarks) are not ported; store exposes metadata-only removeRecording. File handling belongs to the recorder package.
- Existing sessions-doc decode is lenient (missing keys default) vs iOS strict; superset.
- Not touched: docs/ARCHITECTURE-ANDROID.md (integrator). Emulator adb run-as check not run.

## Questions for Levi
None.

## Review

fixes applied

- MINOR scheduleSave orphan race: fixed (saveGen counter bumped in cancelPending; debounce task no-ops on mismatch). Test: staleDebounceTaskAfterCancelIsNoOp.
- MINOR clear() queued delete vs flush: fixed (new VersionedJsonWriter.deleteNow, clear() deletes synchronously). Test: clearThenFlushDoesNotMaterializeFile.
- MINOR MixGraph eager construction on ON_STOP/reset: fixed (Lazy handles + isInitialized; reset deletes the file directly for uninitialized stores). Dirty-flag skip not added.
- NIT ledger row: deferred to integrator (add MIX-1 as DONE, no device-only work).
- NIT ArrayList copy per save: not changed (optional).

Tests: 854 -> 856, 0 failures; assembleDebug green.
