state: merged

# STU-7 Collections integration

- [x] StudioLookup seam + synthetic pseudo-songs (CollectionCatalog.kt), counts/runtime include studio
- [x] RealizeEngine ctx.songFor (mandatory real lengthMs, bpm/camelot; never in candidates)
- [x] StudioRowResolver (STUDIO_LOCAL rung) + StudioPlayback prepare-on-demand (bounce dirty pattern, render stale sample)
- [x] StudioAnalyzer + KeyDetector (chromagram/Krumhansl)
- [x] StorageService STUDIO_* categories (strict delete-all via StudioStore), StudioStorageSection (folder choosers, usage, delete-all)
- [x] Row UI: studio rows in Pocket/Playlist detail, kind badge on setlist rows
- [x] Tests: 27 new (suite 3155, 0 failures)

## Touched outside owned files (minimal, additive)
CollectionsStore.kt (studioLookup/studioArtist/studioInfo, playNow + activity title), AppGraph.kt (3 lines: lookup, storage ops, studioGraph.wire()), StorageScreen.kt (meta for new categories), PocketDetailScreen/PlaylistDetailScreen/SetlistDetailScreen (studio row branch/badge), new screens/playlists/StudioItemRow.kt.

## Deviations
- Stale instrumental (tk_) render: no Android take synth exists yet; StudioPrepareBackend.renderTake defaults to false so the take plays its raw file.
- SAF-hosted (non-File) loop/sample targets are skipped as bounce inputs (decoder takes paths).

## Questions for Levi
- Should studio rows use the profile "PocketDJ name" as artist? Seam exists (CollectionsStore.studioArtist), unwired; defaults to "Studio".

## Review
fixes applied

- MAJOR StudioAnalyzer never called -> fixed: CollectionsStore.onStudioIdsAdded fires from addSong/addSongs for studio ids; AppGraph runs studioAnalyzer.prepare on appScope/IO (key + pre-bounce at add time). Test: addingAStudioIdFiresTheAnalyzerSeamOncePerStudioId, analyzerPrepareStoresAKeyForATake.
- MAJOR no Add-to path for studio items -> fixed: "Add to..." overflow action on Producer sample, loop and sequence rows opens AddToCollectionSheet(AddToItem.Song(studioId)) (the add path is prefix-agnostic). Take rows: Android has no Producer take list yet, so none to add from (recorded in ledger).
- MAJOR dead air on play path -> fixed: rowOnDevice now uses cheap StudioPlayback.isOnDeviceNow (file must exist, dirty pattern is NOT on-device, never prepares); prepare moved to add time via the analyzer, resolve keeps prepare only as last resort. Test: rowOnDeviceProbeIsCheapAndHonest.
- MINOR bounce ignores Sequences folder -> fixed: bounce writes to StudioFolders.writeFolder (user root when configured+writable, SAF via temp file + stream copy) and records the real wasUserFolder (BouncedFile).
- MINOR StudioItemRow main-thread/stale -> fixed: rememberStudioInfo is produceState off-main collecting StudioStore.state; AppGraph warms the studio store on IO when a collection holds studio ids.
- MINOR Storage copy/enable -> fixed: separate "Producer studio" section with iOS-style footer, destructive "Delete" label, enabled when count > 0 || bytes > 0 (StudioStorageOps.recordCount). Test: studioRecordCountReflectsRecordsEvenWhenBytesAreZero.
- MINOR ledger row -> fixed: STU-7 row set PARTIAL in docs/ARCHITECTURE-ANDROID.md.
- NIT picking rememberSaveable + release replaced SAF grant -> fixed (grant kept if another family still uses the tree).

Tests: 3159 run, 0 failures (was 3155). assembleDebug green.
