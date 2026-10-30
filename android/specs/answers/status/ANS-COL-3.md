state: merged

# ANS-COL-3 - COL-15 complete

- [x] CatalogRepository: importedSource resolver (after Discover) + onImportedSupersede; ImportedSongsStore.resolve/resolveEntries/landSupersede (remove imported -> remap collections -> remap favorites)
- [x] CollectionsGraph wiring (replaces syntheticDocuments for Imported)
- [x] PlaylistsScreen: Setlists section (reserved Now Playing hidden, newest first, search-filtered); ShellNavigation passes onOpenSetlist (one-line additive edit outside owned files)
- [x] Export... / Export CSV in playlist + pocket detail overflow; Export CSV in setlist detail
- [x] Tests: ImportedSongsStoreTest (+2), ImportedSupersedeWiringTest (3), CollectionExportImportTest (+2). Total suite 5218 run, 0 failures.

## Notes
- Setlist detail has CSV only: the store has no setlist .pdjcollection exporter (iOS has none either).
- Imported-songs cloud SyncEntry intentionally NOT added (ANS-SYNC-1).
- Emulator steps not run (emulator owned by integrator).

## Questions for Levi
- None.

## Review
- MINOR PlaylistsScreen global Setlists section: fixed (kept per Q75 "no partial"; rows now have Rename/Delete(confirm) overflow like iOS setlistRow; setlists whose playlistId is the reserved Now Playing playlist hidden). Per-playlist section already existed; global list flagged for Levi/integrator to confirm.
- MINOR "No results" above setlist results: fixed (caption only when playlists, pockets and setlists all empty).
- MINOR resolve() rebuilt IndexJson each merge: fixed (memoized on entries/realDocs identity; test resolveIsMemoizedOnUnchangedInputs).
- MINOR landSupersede order: fixed (remap collections, remap favorites, THEN prune imported; documented deviation from iOS; tests updated).
- NIT KDoc stale "deferred": fixed. Label/format alignment with iOS: not done (optional).
- NIT wiring test never drives CollectionsGraph: not fixed (graph needs the app container); order is covered at landSupersede. Tests re-run at tip: 5220 run (was 5218, +2), 0 failures, assembleDebug OK.

fixes applied
