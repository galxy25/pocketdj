state: merged

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

## Review

fixes applied

Status: PARTIAL. Clause-editor UI (Add filter, Year between, Genre none-of) is BRW-2; the engine and persistence exist here but are not reachable from the UI until BRW-2 lands. Emulator steps not run (integrator owns the emulator). The docs/ARCHITECTURE-ANDROID.md ledger row is deferred to the orchestrator.

- MINOR SortField DATE_ADDED shown but unpopulated -> fixed: hidden from `SortField.forKind` (test added). BRW-3 must map `IndexSong.dateAdded` into `SongRow(dateAdded=...)` in `BrowseRows` and re-enable DATE_ADDED in forKind. The `dateAdded` filter field stays in the registry; BRW-2 should not offer it until then.
- MINOR BrowseFilterSheet.kt touchpoint owned by BRW-2 -> noted: BRW-1 only switched to `BrowseFilters.withGenres/withBpm/withCamelots/withSources`; those helpers are kept stable for BRW-2. Whichever merges second rebases knowingly.
- MINOR Plays source -> fixed: counts now read via `PlayHistoryStore.playCount` (the countIndex), no duplicate groupingBy. PARTIAL: still the device-local, capped event log, not the lifetime Apple-baseline count; gap belongs to the PlayCountService roadmap item.
- NIT norm() whitespace -> fixed: trims any horizontal whitespace incl. NBSP (test added).
- NIT catalogIdentity identityHashCode -> not changed (optional; no monotonic catalog revision exists in CatalogRepository; collision risk negligible).

Tests: 328 run, 0 failures (326 before review).
