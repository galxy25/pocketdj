state: reviewed

# ANS-STU-7 Profile custom-audio source part A

- [x] ProfileSourceStore (iOS doc shape `pocketdj-profile-source.json`, synthetic index, two default albums, rename re-tag, no cloud sync)
- [x] ProfileAudioStore (ingest byte-exact + all-or-nothing stems under filesDir/profile-audio, resolve, delete, usage)
- [x] ProfileRowResolver (playback LocalFile, fence rung for absent pdj_ rows, Mix track + stem provider)
- [x] Wiring: catalog syntheticDocuments (CollectionsGraph), playback localFiles, Mix resolver/stems/isOnDisk/auto seams/download isOnDisk (MixGraph), StudioGraph (profileSource/profileAudio/reset), Storage "Pocket DJ audio" category
- [x] Tests: ProfileSourceStoreTest (14), ProfileRowResolverTest (7)

## Files touched outside owned list (minimal, additive)
- di/PlaybackGraph.kt (one line: wrap burnedFirst with studioGraph.withProfileAudio)
- di/AppGraph.kt (StorageService args), data/storage/StorageService.kt (PROFILE_AUDIO category), screens/settings/StorageScreen.kt (meta)

## Notes
- Part B (saving demuxes/samples into the source from the UI) will call `studioGraph.profileAudio.ingest(...)`; no UI hook added here.
- Browse label: source name comes from the synthetic manifest.sourceName (profile name); not verified in-screen (emulator not used).
- pdj_ is not in PlayResolver.STUDIO_ID_PREFIXES; ProfileFenceResolver (STUDIO_LOCAL rung) keeps absent pdj_ rows from being streamed or ripped.

## Questions for Levi
None.

## Summary
Android now has the iOS "Pocket DJ" profile source: records + two synthetic default albums joined into the catalog merge, device-local audio store, playback/Mix lookups for pdj_ ids, reset and Storage coverage. No cloud sync.

## Tests
`:app:testDebugUnitTest :app:assembleDebug` green: 5508 tests, 0 failures (+21 new). Emulator step not run.

## Review
- MAJOR CollectionsGraph always-on synthetic doc -> fixed: `ProfileSourceStore.syntheticDocumentsIfAny()` returns empty until >=1 item (iOS parity); test added.
- MAJOR CatalogRepository empty-input guards -> fixed: root cause removed above, plus `remergeLocal` skips while no real merge has happened and no catalog exists.
- MINOR Mix non-mp3 profile originals -> fixed (limited): `ProfileMixTrackResolver` exists()/resolve() refuse non-mp3 originals so they are not offered as mixable; test added. LIMITATION: no MediaCodec PcmSource yet, so m4a/wav demuxes play in Now Playing but not on Mix decks.
- MINOR ProfileAudioStore IO -> fixed: `store.add` now runs inside the IO block in `ingest`; `deleteAsset`/`deleteAll` documented as off-Main (sole caller StorageService.clear runs on Default).
- NIT setProfileName trimmed compare -> fixed; test added.

fixes applied
