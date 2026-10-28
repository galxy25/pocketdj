state: implemented

# BRW-6 History screen parity

- [x] Tabs Playback | Collection (+ Pockets / For You gated via `HistoryTabGate`); Unified + `buildUnified`/`HistoryEntry` removed
- [x] `HistoryRows.kt`: `PlayRef`, `HistoryBase`, `visibleEvents`, `buildItems` (event-id identity, snapshot fallback), `contextLabel`, `isLiveRow`
- [x] `HistoryBrowseState.kt`: refreshExternal with debounce-first, supersede abandon (post-sleep + publish point), never-memoize-empty, no-base-no-stamp, invalidate (both memos), pagingKey excludes catalog; own persisted state
- [x] `HistorySettings.kt` (`historySnapshotJson`), hydrate/debounced write/flushable in `BrowseGraph`
- [x] `Rewind.kt` (slice / sameRunUid / plan / performRewind) + `HistoryRowMenu.kt` (Rewind / Add to… / Share), rewind always confirms
- [x] Row chrome: live speaker (eventId == skipTracker.currentEventId AND player playing), skipped badge, on another device, N plays
- [x] Sort/filter sheets in history mode (Last played date pickers, Hide skips)
- [x] Tests: HistoryRowsTest, HistoryBrowseStateTest, RewindTest (JVM suite 2472 tests, 0 failures)

## Files touched outside owned set
- `screens/browse/BrowseSortSheet.kt`: additive `historyMode` param (exposes Last played key) + history empty-state copy.

## Notes
- Hide skips and query are transient (not persisted), matching the BrowseFilters doc comment and iOS.
- HistoryRowsTest rewritten (Unified tests removed with Unified).
- `HistoryTabGate.pocketsEnabled/forYouEnabled` default false; Pockets / For You tab bodies are placeholders until those stores land.
- Base build runs on Default dispatcher (iOS builds on main) to avoid jank at 20k events.
- Not emulator-verified (emulator owned by integrator).

## Questions for Levi
- None.
