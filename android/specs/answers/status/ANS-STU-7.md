state: in-progress

# ANS-STU-7 Profile custom-audio source part A

- [x] ProfileSourceStore (iOS doc shape, synthetic index, two default albums, rename re-tag, no cloud sync)
- [x] ProfileAudioStore (ingest byte-exact + all-or-nothing stems, resolve, delete, usage)
- [x] ProfileRowResolver (playback LocalFile, fence rung, Mix track + stem provider)
- [x] Wiring: catalog syntheticDocuments, playback localFiles, Mix resolver/stems/isOnDisk/auto seams, reset hook, Storage category
- [x] Tests
- [ ] Full gradle run
