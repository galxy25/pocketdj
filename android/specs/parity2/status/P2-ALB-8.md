state: reviewed

# P2-ALB-8 - Metadata edit sheets + Settings > Edits

- [x] `EditAlbumSheet.kt`: `EditDelta` pure delta math (string/optional/int/long/double/bool/tags, album/song/audio builders), shared `EditField` + `EditSheetScaffold`, `EditAlbumSheet` (deltas vs `CatalogRepository.rawAlbum`, reset to original)
- [x] `EditSongSheet.kt`, `EditAudioAnalysisSheet.kt` (per-segment deltas vs RAW; all-default save drops the override)
- [x] `EditsSection.kt`: Settings > Edits (Export via CreateDocument `pocketdj-edits.json`, disabled at count 0; Import = imported wins per id via BackupEditsStore.importMerging; Clear with confirm; footer count + schema version); `EditsTransfer` pure helpers
- [x] Wiring: Edit buttons in AlbumDetailScreen (header + audio-analysis section) and SongDetailSheet; section registered in CollectionsGraph.settingsSections (order 430)
- [x] `EditDeltaTest`: 12 tests. Full suite 7667 tests, 0 failures; assembleDebug green. No manifest/gradle/proguard/library change, so assembleRelease not run.

## Files outside owned list
- `data/backup/BackupModels.kt`: `BackupEdits.restamp` gained a `platform` param (default "Android", unchanged for backups); Edits export passes "android" per acceptance.
- `di/CollectionsGraph.kt`: one line registering `editsSection()` (SettingsSections.builtin() is pinned by tests, so used the sidecar list).
- `CatalogRepository.rawAlbum/rawSong` and `EditsStore` already existed (P2-ALB-2); no change needed.

## Deviations
- Album save carries the existing `audioTracks` override (iOS rebuilds a bare AlbumEdit and wipes boundary/audio edits); Reset on the album sheet likewise keeps them.
- Clear button added (not in iOS UI) with a confirm dialog.
- No emulator run (instructions).

## Questions for Levi
None.

## Review
- MINOR EditSongSheet/EditAlbumSheet/EditAudioAnalysisSheet diff against a null raw row -> fixed (Save now no-ops and dismisses when the raw row is missing; audio sheet no longer falls back to the overlaid album)
- MINOR EditsSection stale count -> fixed (count re-read on every CatalogRepository.state change)
- NIT unparseable numeric text -> fixed (field shows error, Save disabled; `EditDelta.*Invalid`, covered by `invalidNumericInputIsFlagged`)

fixes applied
