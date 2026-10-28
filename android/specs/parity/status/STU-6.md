state: implemented

# STU-6 Cues tab + cue-seek plumbing

- [x] CueSeek (plan/availability/search/analogCrop/stamp) + CueSeekTest (7)
- [x] StudioCuePointsProvider (shared deck/editor seam, dropAtNextFree 8/9th) + StudioGraph.cuePoints + CuePointsProviderTest (3)
- [x] PlaybackController.play(startMs): ExoPlayer start position on the single clipped item (clip-relative; clipStart never pre-added), AM play-then-seek, canSeekAppleMusic()
- [x] CuesScreen + CueTimeline (burned-first search, local peaks / PNG / analog cropped PNG, 8 slots, tap/long-press menu, transport scrub, still-ripping disabled state)
- Tests: 2890 total, 0 failures (+10 new).

## Files touched outside ownership (minimal, additive)
- playback/PlaybackController.kt: `startMs` param on play(), setQueueAndPlay startPositionMs, seekAfterAm, canSeekAppleMusic
- screens/producer/ProducerScreen.kt: Cues sub-tab -> CuesScreen

## Notes
- Mix DeckView still uses its own StudioCuePoints; StudioGraph.cuePoints is the shared instance for MIX wiring to adopt (not wired: MixGraph not owned).
- StudioStoreTest cue additions already covered by existing cueCapEightSlotsReplaceAndValidation.
- Device-only: Apple Music play-then-seek. Emulator step not run (emulator off-limits).

## Questions for Levi
- none

## Review
fixes applied
- MAJOR ledger row still Planned -> fixed (PARTIAL, device-only AM seek + unrun emulator step noted; test architectureLedgerRowForStu6IsNoLongerPlanned)
- MINOR seekAfterAm ignored playGeneration -> fixed (amWithSeek captures gen; CueSeek.shouldSeekAfterAm checks gen + AM ownership; tested)
- MINOR AM seek applied to 30 s preview -> fixed (tryAppleMusic reports full-track start; preview never seeked)
- MINOR backstop "Cue dropped" notice -> fixed (PlaybackController.lastStartHonored; CuesScreen notice when offset not applied)
- MINOR disabled-slider scrub stuck -> fixed (unseekable timeline tap shows notice, never sets scrub)
- MINOR amReady never refreshed -> fixed (re-polled every 3 s while pane visible)
- MINOR duplicate provider -> fixed (dropAtNextFree moved into screens/mix StudioCuePoints; StudioCuePointsProvider deleted; StudioGraph.cuePoints is that class; DeckView adoption remains MIX hand-off)
- NIT rememberSaveable -> fixed; NIT CancellationException swallowed -> fixed (runCatching removed)
- NIT ProducerScreen routing edit -> rejected as code change; flagged for integrator (single-line `Cues ->` branch, may conflict with STU-5)
