state: implemented

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
