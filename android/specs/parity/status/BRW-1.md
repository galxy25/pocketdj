state: implemented

# BRW-1 — Full filter/sort clause engine + persistence migration

- [x] BrowseFilter.kt: Field registry (20 ids, iOS order), FilterOp, Clause, FieldValue, FilterEngine, FieldOptions
- [x] BrowseEngine.kt: filterSort (newline-stripped query, mismatch fallback), resultsKey (sorted-key JSON)
- [x] BrowseSort.kt: SortField mirrors registry (+playCount, dateAdded, lastPlayedAt, albumCount, songCount); ARTISTS sort
- [x] BrowseModels.kt: BrowseRow sealed (AlbumRow/SongRow/ArtistRow); BrowseFilters = List<Clause>
- [x] BrowseSnapshot.kt + BrowseSessionPersistence.kt: ClauseDoc, legacy -> clauses migration, unknown ids dropped
- [x] BrowseScreen.kt: produceState keyed on resultsKey; play-count snapshot from PlayHistoryStore only when used; ARTISTS now filter/sorted
- [x] Tests: FilterEngineTest (new), BrowseEngineTest/SortEngineTest/BrowseSessionPersistenceTest extended

Tests: 326 run, 0 failures (baseline 275 @Test) -> +51.

Notes / deviations:
- Registry has 20 fields (iOS Fields.all), not 18 as the roadmap prose says; order matches BrowseModel.swift.
- SongRow.dateAdded is null until BRW-3 adds IndexSong.dateAdded and wires BrowseRows (IndexModels not touched here).
- SongRow.playedAt is for History rows (BRW History package will populate).
- Touched outside owned list (minimal): BrowseFilterSheet.kt (switched to BrowseFilters.withGenres/withBpm/... helpers; UI unchanged).
- Sort-persist test: "lastPlayedAt" is now a known field, so the unknown-field test uses "futureField".
- ARTISTS kind: filters/sort now apply (previously inert).
