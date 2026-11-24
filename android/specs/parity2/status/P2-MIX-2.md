state: in-progress

# P2-MIX-2 - Mix tab Volume Glide + visible deck trims

- [x] mix/engine/MixVolumeGlide.kt: LevelingStatus/LevelSide/DeckLeveling, VolumeGlideRules (pure), MixVolumeGlide state machine over a VolumeGlideHost
- [x] MixEngine: volumeGlide + loudnessCache seam, per-deck file/streaming bookkeeping, load/eject hooks, setVolumeGlide/refreshVolumeGlide
- [x] mix/graph/RenderParams.kt (touchpoint): DeckInputs.levelDb + ParamsComposer.setLevelDb (trim = boost + level; not a boost write)
- [x] AutoDj.kt (touchpoint, 3 one-liners) refresh on start / end / restoreSuspended; StreamDecks.kt (touchpoint) streamSettled on finish/truncate
- [x] UI: DeckControls LevelingReadout + VolGlidePill; DeckView (readout under Vol), MixScreen (pill)
- [x] di/MixGraph.kt (touchpoint): LoudnessCache(filesDir/loudness.json), setting followed by the engine
- [ ] tests green, count moved, assembleDebug

## Notes
