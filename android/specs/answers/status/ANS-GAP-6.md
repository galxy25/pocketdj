state: implemented

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
