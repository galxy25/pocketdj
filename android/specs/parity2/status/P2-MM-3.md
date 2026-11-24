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

## Review
- Browse-row badge missing (MINOR) -> open gap, not fixed: BrowseComponents is not owned by this package; follow-up needed to mount a compact BufferedBadge on browse rows. Audio-only badge condition kept (the expiry clock is the audio hold's, as iOS).
- Pin in pick() too aggressive (MINOR) -> fixed: pin removed from pick(); now pins when stem audition starts (setStemMode on) and in carve().
- Clear now cancelled on leaving screen / null result ignored (MINOR) -> fixed: runs on graph.appScope; null shows "Busy, try again in a moment.", success and Keep all show a status line.
- Pin reason strings differ from iOS + weak tests (MINOR) -> reasons kept (roadmap names them); added TakeRendererTest.songKeyUseHookFiresForCatalogSongKeysOnly (fires for song key, not studio/dmx_ keys). Constants test left as a stability guard.
- Cap change sweeps existing footprint, expiry text not ticking (NIT) -> rejected: matches iOS, disclosed; roadmap text to note the deviation.

Tests: 6661 run, 0 failed (+1). Fixes applied.
state: reviewed
