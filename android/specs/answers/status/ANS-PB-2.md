state: reviewed

# ANS-PB-2: Game rows prefer full-track Apple Music, fall back to previews (Q36)
- [x] Removed runTag guard from AppleMusicRowResolver (canPlayFullTrackCached / ripStartsNow unchanged)
- [x] GamePreviewResolver.canPlayFullTrack (wired in GamesGraph to PlaybackController.canSeekAppleMusic): skips preview warm/probe when full-track capable
- [x] Tests: AppleMusicRowTest (+1), GameRunPlayerContractTest (+4); ResolveLadderTest unchanged (no change needed)
- Timing: AM start is slower than a cached preview; documented in SequencerGameRunPlayer KDoc. Device-only to measure.
- Touched outside owned files: android/.../di/GamesGraph.kt (one additive line).

## Questions for Levi
none

## Review
fixes applied
- MAJOR (AM failure lost preview degradation): fixed. New GamePreviewFallbackPort wraps Media3Port; a runTag row whose AM load throws reloads as the cached preview StreamSource (rethrows if no preview; ordinary rows unchanged). GamesGraph wires PlaybackController.gamePreviewUrl. Tests: amFailure_gameRow_fallsBackToPreviewStream, _noPreview_rethrows, amFailure_ordinaryRow_stillThrows.
- MINOR (GamesGraph hot file / capability drift): fixed. Single PlaybackController.canPlayFullTrackWarming() used by both the AM rung and GamePreviewResolver (GamesGraph edit is two additive lines; flag as shared touchpoint for ANS-GM-2/GM-3 integration: keep canPlayFullTrack + gamePreviewUrl wiring).
- MINOR (warm skipped when capable): fixed. warm() always warms the LOOKAHEAD window (cheap, cached); canPlay still skips probing when capable.
- NIT comments: fixed (SequencerGameRunPlayer KDoc, GamesGraph, AppleMusicRowResolver).
- NIT tests: added ladder_gameRowWithManifestHit_resolvesManifestRung and AM-failure tests. ResolveLadderTest untouched. Tests 5136 -> 5140 (+4), 0 failures. Emulator step not run (integrator owns it).
