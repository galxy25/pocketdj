state: reviewed

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

## Review

fixes applied

- MINOR rewind cancelled on scope exit: fixed. Execute step now runs on `graph.appScope` (Main); event log still re-read at execute time; failure Toast posted on Main.
- MINOR live speaker ignores paused-but-running: fixed. `isLiveRow` = current event AND (sequencer running OR playing); test case added.
- MINOR hydration race: fixed. `refreshExternal` publishes nothing until restored (`requireRestore`), `restore()` applies only when filter/sort are still pristine, a failed load still marks restored; the screen recompute keys on the restored flow. Two tests added.
- MINOR Pockets / For You gate: partially fixed. `HistoryTabGate` is now a StateFlow collected by the screen (recomposes). The Pockets / For You tab bodies remain placeholders: tracked as a follow-up package, acceptance NOT met for them.
- NIT ledger row: left to integrator; mark PARTIAL (emulator steps pending, Pockets/For You bodies stubbed).
- NIT BrowseSortSheet `historyMode` param: additive with default; integrator should watch merge order. No code change.

Tests: 2474 run, 0 failures; :app:assembleDebug green.
