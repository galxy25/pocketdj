state: implemented

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
