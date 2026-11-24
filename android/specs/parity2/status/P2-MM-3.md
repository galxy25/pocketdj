state: in-progress

# P2-MM-3 Mix Mode ph1c: Storage buffer section, Buffered badge, Studio explicit-use pins

- [x] MixModeBufferSection.kt: pure MixModeBufferState + composable (usage, next expiry, TTL/cap pickers, keep-picked toggle, rows, Keep all, Clear now) + StudioPins
- [x] Mounted in StorageScreen (Settings > Storage); StorageSection caption updated
- [x] BufferedBadge.kt in SongDetailSheet
- [x] Pins: DemuxSourcePicker (demux), ClipPickerSheet (tracks-stems), NewSampleFromTrackSheet (sample), TakeRenderer onSongKeyUse hook wired in StudioGraph (take)
- [x] MixModeBufferSectionStateTest
- [ ] full gradle green
