state: implemented

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
