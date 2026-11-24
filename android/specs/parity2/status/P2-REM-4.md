state: merged

# P2-REM-4 RemoteSongResolver + SequencerRemoteTarget + InMemoryRemoteTarget

Summary: `RemotePlaybackTarget` interface (iOS shape over QueueItem/uid/Long ms); `SequencerRemoteTarget` (every mutation an `applyingExternal`
apply, UNDISPATCHED launches so the gate/intent checks see the external depth; held-deck resume/seek via held seams; transition cause tracked through a
SequencerListener, `close()` unhooks); `InMemoryRemoteTarget` (+ simulate* helpers); `RemoteSongResolver` ladder (own id -> catalog by appleMusicId -> am:<id>
if AM usable -> exact normalized title|artist (JukeboxMatcher.normalize key) -> fuzzy JukeboxMatcher -> unavailable), `outboundRow` stamping appleMusicId,
`RemoteCatalogIndex` (rebuilt per catalog revision) and `RemoteResolutionCache` (fuzzy only for current+3, undecided rows retried as they near current,
decided cached by rid, `queueItem()` always a fresh uid).

Tests: +46 JVM tests (RemoteSongResolverTest, SequencerRemoteTargetTest, InMemoryRemoteTargetTest). Total 6449 (0 failures) on :app:testDebugUnitTest :app:assembleDebug.
No manifest/gradle/proguard touched, so assembleRelease not run.

- [x] RemotePlaybackTarget.kt
- [x] SequencerRemoteTarget.kt
- [x] InMemoryRemoteTarget.kt
- [x] RemoteSongResolver.kt (+ RemoteCatalogIndex, RemoteResolutionCache)
- [x] tests, build green

## Deviations / notes
- P2-REM-3 (gate, system-pause classification, coarse position, Mix/DSP silencers) is not merged: those are constructor seams on SequencerRemoteTarget
  (`systemPaused`, `coarsePosition` default = `sequencer.appleMusicActive()`, `extraSilencers`) for the graph to wire.
- Exact key uses JukeboxMatcher.normalize (per roadmap), not iOS ShazamCatalogMatch.norm.
- No files outside the owned list were modified. Added a third test file InMemoryRemoteTargetTest.kt.

## Questions for Levi
- none

## Review
- RemoteCatalogIndex rebuilds on caller thread (line 128) -> fixed: old Tables keep answering; one single-flight background build (injectable executor) swaps in; synchronous only when no tables exist.
- Unsynchronized refresh / stale fuzzy memo (line 150) -> fixed: build is single-flight under a lock, builds counter atomic, fuzzy memo now lives on each Tables instance so it cannot leak across builds.
- stamped() raw variant (line 71) -> fixed: variant kept only if it matches a known SongVariant raw value, else null.

Tests: +3 (old-tables-while-building + single-flight, per-build memo, unknown variant dropped). 6452 total, 0 failures; assembleDebug green.

fixes applied
