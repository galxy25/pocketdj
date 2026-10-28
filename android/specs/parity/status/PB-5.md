state: reviewed

# PB-5 History outcomes

- [x] PlayEvent additive fields (originInstallId, wasSkipped, listenedFraction, tzOffsetMin, originCollectionId), derived `outcome`
- [x] PlaySource.GAME, PlayContext.game(runTag,label), SOURCE_GAME; MIX token already existed
- [x] PlayHistoryStore: record stamps install/tz/origin, onRecord/onResume, markSkipped, noteListened, isFromAnotherDevice, local-only window, lastLocalEvent, recentPlaysForZone
- [x] SkipTracker (strict <0.5, high-water, one-deep stash, restart, checkpoint, natural end)
- [x] PlayProgress/PlayAdvancedAway/PlayStopped on PlayEventBus; sequencer feeds tracker at 1 Hz, advance-away sites, restart, stop checkpoint
- [x] PlaybackGraph wires tracker (verdicts fan out through PlayOutcomeRegistry) and store hooks

Tests: 1934 total, 0 failures (SkipTrackerTest 15, PlayEventCodecTest 6, PlayHistoryStoreOutcomesTest 7 new).

## Files touched outside owned list (minimal/additive)
- playback/health/EngineProbe.kt: `durationMs` default-null member; PlaybackController.kt engineProbe overrides it
- screens/history/HistoryScreen.kt: GAME icon branch (exhaustive `when`)

## Deviations / not done
- History timeline outcome glyph + live-row highlight NOT implemented (HistoryScreen not owned); `SkipTracker.currentEventId` is exposed for it.
- When skipTracker is unset the sequencer keeps the legacy progressProvider outcome path (existing test).
- recentPlaysForZone returns PlayEvent list (no ZoneEngine.Play type in Kotlin yet); default coverage 60 d.
- noteSkip (cumulative per-song count sink) not wired; no Kotlin PlayCountService equivalent found.

## Questions for Levi
None.

## Review
fixes applied

- MAJOR HistoryScreen glyph + live row -> fixed: HistoryRow.outcome, OutcomeGlyph (skipped/completed/partial, unknown none), live row from `SkipTracker.currentEventIdState` StateFlow; HistoryRowsTest.rows_carryDerivedOutcome.
- MAJOR persist on Main / inside lock -> fixed: markSkipped/noteListened publish synchronously, persist coalesced on a daemon writer (`flush()` for tests/background); SkipTracker queues store/fan-out sinks under the lock and runs them after release; tests sinks_runOutsideTheTrackerLock, outcomeMutations_persistOffCallerThread_andCoalesce.
- MINOR noteAdvanceAway live guard -> fixed (`if (waitingForLive) return`).
- MINOR duration source -> fixed: `cur.lengthMs` first, engine fallback, both for samples and advance-away (catalogLength_beatsMissingEngineDuration).
- MINOR noteSkip sink -> not wired (no PlayCountService in Kotlin); gap recorded in status ledger row as a dependency.
- MINOR ledger row -> fixed: PARTIAL with device-only/open items.
- MINOR sequencer wiring tests -> fixed: SkipWiringTest (8): skipNext 10%/50%, previous/end/stop no mark, playNow, sampleAudible feed, repeat-one pass 2, unknown duration.
- NIT hooks race -> fixed: `PlayHistoryStore.get(ctx, onRecord, onResume)` installs hooks before the bus collector starts.
- NIT GAME icon -> fixed (SportsEsports).
- NIT endRun spurious PlayStopped -> fixed (only when running).

Tests: 1946 total, 0 failures (was 1934; +12). assembleDebug OK. Emulator not used.
