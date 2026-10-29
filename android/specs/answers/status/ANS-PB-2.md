state: implemented

# ANS-PB-2: Game rows prefer full-track Apple Music, fall back to previews (Q36)
- [x] Removed runTag guard from AppleMusicRowResolver (canPlayFullTrackCached / ripStartsNow unchanged)
- [x] GamePreviewResolver.canPlayFullTrack (wired in GamesGraph to PlaybackController.canSeekAppleMusic): skips preview warm/probe when full-track capable
- [x] Tests: AppleMusicRowTest (+1), GameRunPlayerContractTest (+4); ResolveLadderTest unchanged (no change needed)
- Timing: AM start is slower than a cached preview; documented in SequencerGameRunPlayer KDoc. Device-only to measure.
- Touched outside owned files: android/.../di/GamesGraph.kt (one additive line).

## Questions for Levi
none
