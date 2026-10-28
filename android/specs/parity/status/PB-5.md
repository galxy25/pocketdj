state: implemented

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
