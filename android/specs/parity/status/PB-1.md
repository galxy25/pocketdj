state: in-progress

# PB-1 - SetlistSequencer core

- [x] sequencer/ types: QueueItem, RepeatMode, AdvanceCause, SequencerState, PlayerPort, RowSourceResolver (+Rung, LocalFile/Manifest rungs), RowResolverRegistry, LocalFileResolver, EditionDecider
- [x] SetlistSequencer (play, handleEnded/Failed, skip, repeat/shuffle, live edits, adoptCursor, playUrl, appendRows, held/resume seam)
- [x] PlaybackController rewired: Media3Port loads current row only; playQueue/playSetlist via sequencer; next/previous/stop route to it; manual member play adopts cursor
- [x] PlaybackSettings (PlaybackMode, repeat pref), PlayOutcomeRegistry, NowPlayingRoutes (empty), PlaybackGraph wiring
- [x] SetlistDetailScreen / QueuePlan moved onto sequencer
- [ ] JVM tests (SetlistSequencerTest, RepeatShuffleTest, LiveEditsTest, ResolveLadderTest, FakePlayerPort, QueuePlanTest update)
