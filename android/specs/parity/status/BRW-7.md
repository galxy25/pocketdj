state: merged

# BRW-7 Collection timeline (F8) + cue store + History Collection tab
- [x] CollectionTimeline.kt (pure builder, month dividers, album aggregation, jumpIndex)
- [x] TimelineCueStore.kt (lenient JSON, cap 500, whole-doc LWW reload)
- [x] CollectionTimelineScreen.kt (grain picker, since-date, direction, cues, summary) wired into HistoryScreen COLLECTION tab
- [x] Tests: CollectionTimelineTest (6), TimelineCueStoreTest (8)
- RecentlyAdded.songIds / synthetic playlist already shipped by COL-12 (RecentlyAddedTest covers top-N, ties, overrides, own-library, memo); not duplicated.

## Notes
- Cue store is constructed in the screen (no AppGraph edit); not yet registered with cloud sync or account-deletion clear (follow-up).
- Timeline rows have no artwork thumbnail yet.
## Questions for Levi
None.

## Review
fixes applied
- MAJOR since-date UTC midnight -> fixed (CollectionTimeline.pickerMillisToLocalStartOfDay/localToPickerMillis, future dates unselectable; tests in CollectionTimelineTest for PDT + Tokyo)
- MAJOR album rows dead -> fixed (onAlbumClick through HistoryScreen/ShellNavigation to album route)
- MAJOR cue store -> fixed (ServicesGraph.timelineCues: lazy, IO writer, loaded off main, `timeline-cues` sync entry + reloadFromDisk, ResetHook clear; SyncRegistryTest key/file check)
- MAJOR ledger row -> fixed (PARTIAL + follow-ups)
- MINOR scroll reset -> fixed (scrollToItem(0) on stream key change)
- MINOR play-count source -> fixed (PlayStatsStore.playCountsSnapshot, re-collected on revision)
- MINOR rebuild cost -> fixed (180 ms query debounce, addedAt/plays memoised separately, cancelCheck in builder loops; test)
- MINOR cue editing -> fixed (date picker in add dialog, Rename action)
- MINOR empty/loading states -> fixed (timeline-empty + emptyMessage; test)
- MINOR owner gate -> rejected: Android has no owner identity yet; matches COL-12, to be wired via the shared helper when the gate lands (ledger follow-up)
- NIT 5k random top-N -> fixed (RecentlyAddedTest)
