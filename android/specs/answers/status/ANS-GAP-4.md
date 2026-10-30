state: reviewed

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

## Review
- MAJOR restored edits never applied -> fixed (honestly): a catalog overlay is out of this package's scope, so COL-14 stays PARTIAL for "edits applied on restore". The restore message no longer says edits were "Restored"; it says "N edits saved, not yet applied on Android". Test restoreMessageNeverClaimsEditsWereApplied added. Follow-up needed: catalog edits overlay.
- MINOR importMerging count -> fixed: BackupEdits.changedCount counts only new/different ids; re-restore returns 0 ("Already up to date"). Test realIosShapeCountsMergesAndIsIdempotent.
- MINOR vacuous fixture test -> fixed: removed the `>= 0` assertion; added real iOS-shape edits (albums+songs) test asserting merged values through BackupEditsStore. BackupCoordinator.restore itself still needs an AppGraph and is not driven in a unit test.
- NIT export meta/schemaVersion -> fixed: BackupEdits.restamp (schemaVersion 2, meta platform Android, fresh exportedAt); test exportRestampsSchemaAndMeta.
- Suite: 5420 tests, 0 failures (was 5418: +3 new, -1 obsolete restoreMessageMentionsEdits); assembleDebug green.

fixes applied
