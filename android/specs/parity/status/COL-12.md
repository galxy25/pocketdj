state: implemented

# COL-12 Recently added virtual playlist
- [x] IndexSong.dateAdded + Settings count/clamp already existed (earlier packages); added IndexModelsDecodeTest.dateAddedOptional
- [x] RecentlyAdded.kt: pure derivation + RecentlyAddedBuilder (memo on catalog identity/limit/add signature, computeCount, hasItems gate, playlist())
- [x] Yours tab pinned "Recently added" section (off-main produceState) -> SourcePlaylistDetailScreen with id __pdj_recently_added__
- [x] CollectionsGraph.recentlyAdded; tests: 8 RecentlyAddedTest + 1 decode (3137 total, 0 failures)

## Notes
- In-app adds come from activity catalogAdd events (Android has no discoverAdds/imports stores). No non-owner own-library scoping (no owner-gate source tag wired).
- Settings row (CollectionsSection) already existed; no live "N songs" caption added.
- No files touched outside owned list besides IndexModelsDecodeTest.kt (additive).

## Questions for Levi
- None.
