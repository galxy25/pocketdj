state: implemented

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
