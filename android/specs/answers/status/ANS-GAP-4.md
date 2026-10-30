state: implemented

# ANS-GAP-4 - COL-14 complete
- [x] onPortableItems seam: already wired in CollectionsGraph.wireImported (importedSongs.addPortable); materializePortableItems now filters via PortableItems.isPortable.
- [x] Profile song ids (`pdj_` prefix, iOS isProfileSongId) excluded from items.json (PortableItems.isProfileSongId/isPortable); TODOs removed.
- [x] BackupSources.merge + favorites merge were already applied in BackupCoordinator.restore; added edits: BackupEdits.merge (imported wins per id, unknown fields preserved, idempotent) + BackupEditsStore (file backup-edits.json), wired into backup export and restore; restore message counts edits.
- [x] BackupMergeTest (7 tests). Full suite 5418 tests, 0 failures; assembleDebug green.

## Deviations / touched outside owned files
- BackupSection.kt (BackupCoordinator) minimal additive edit; CollectionsStore.materializePortableItems one-line filter.
- Android has no catalog edits overlay yet, so restored edits are stored/round-tripped to iOS backups but not applied to the catalog.

## Questions for Levi
- None.
