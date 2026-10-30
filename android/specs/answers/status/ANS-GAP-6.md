state: merged

# ANS-GAP-6 — STU-3 stem carve

- [x] StemCarve.kt: pure rules (availability, chip toggle keeps >=1, canonical order paths, "song · drums+bass" naming, local->download resolve, all-or-nothing)
- [x] SampleFactory.carveStems (additive; song-relative window, Track provenance, SAF-relocating like carveTrack)
- [x] FromTrackSheet.kt: StemSourceSection (Stem source switch + chips), wired into NewSampleFromTrackSheet (additive: state, pick(), carve() branch)
- [x] StemCarveTest: 9 tests. Full suite 5495 tests, 0 failures; assembleDebug green.

## Files touched outside owned list
- SampleFactory.kt (additive carveStems), NewSampleFromTrackSheet.kt (additive wiring).

## Deviations
- iOS stem-mode live AUDITION (synced StemPlayer, chips live-mute) not ported: the preview keeps playing the full mix; the carve itself uses the chosen stems. 

## Questions for Levi
- Want the stem-mode audition (synced stem player in the carve sheet) as a follow-up?

## Review
fixes applied
- MINOR stem audition: partially fixed. Live synced stem audition remains a follow-up (still the open question above); the sheet now shows a caption in stem mode saying the preview plays the full mix.
- MINOR download/busy: fixed. Stems download when stem mode is switched on (busy spinner, switch disabled, mode reverts with DOWNLOAD_FAILED on error); chips disabled while busy/carving; carve() snapshots enabledStems at start.
- MINOR emulator step: not run (emulator owned by the integrator; not booted). Still to do before merge: carve 4 s of drums from a stemmed burn fixture and confirm playback.
- NIT stem-specific error: fixed (SampleFileFailure.StemCarve with iOS wording, used by carveStems; test updated + added). Unused NONE_PICKED removed; DOWNLOAD_FAILED now used.
- NIT availability source: fixed (burns.stemsRemote(id)).
- Tests: 5496 run (was 5495), 0 failures; assembleDebug green.
