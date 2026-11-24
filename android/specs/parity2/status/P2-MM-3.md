state: implemented

# P2-MM-3 Mix Mode ph1c: Storage buffer section, Buffered badge, Studio explicit-use pins

- [x] MixModeBufferSection.kt: pure MixModeBufferState + composable (usage, next expiry, TTL/cap pickers, keep-picked toggle, rows, Keep all, Clear now) + StudioPins
- [x] Mounted in StorageScreen (Settings > Storage); StorageSection caption updated
- [x] BufferedBadge.kt in SongDetailSheet
- [x] Pins: DemuxSourcePicker (demux), ClipPickerSheet (tracks-stems), NewSampleFromTrackSheet (sample), TakeRenderer onSongKeyUse hook wired in StudioGraph (take)
- [x] MixModeBufferSectionStateTest
- [x] :app:testDebugUnitTest :app:assembleDebug green (6660 tests, 0 failed; +12 new)

## Summary
Settings > Storage gains a "Mix Mode buffer" section (footprint/count, next expiry, TTL 6/12/24/48/72/168 h/Keep, cap 0.5-20 GB, keep-picked-folder toggle, rows, Keep all, Clear now with confirm). Song Detail shows "Buffered · expires in N h" + Keep. Studio demux pick, Tracks stem import, New sample from track and takes pin via BurnStore.pin.
Tests: 12 new (MixModeBufferSectionStateTest).

## Notes / deviations
- Touched outside owned files: StorageScreen.kt (one mount line), StudioGraph.kt (TakeRenderer onSongKeyUse lambda), SongDetailSheet.kt + TakeRenderer.kt (touchpoints).
- Badge on browse list rows not added (only Song Detail); BrowseComponents not owned.
- Take pin: TakeRenderer.render pins when take.demuxSourceKey is a catalog song key (Android analogue of iOS resolveMelodyStem), reason "take"; reasons are the roadmap's ('sample','take'), not iOS 'studio-sample'/'studio-take'.
- Cap change calls scheduleCapSweepIfNeeded like iOS (lower cap applies to the existing footprint at once); TTL change never rewrites existing holds.
- Mix Mode default-on / buffer-ahead / cellular rows (iOS section) left to MM-4.
- assembleRelease not run: no manifest/gradle/proguard/library change.

## Questions for Levi
- none
