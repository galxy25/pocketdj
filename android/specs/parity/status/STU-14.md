state: merged

# STU-14 Demuxer core (sources, DemuxStore, chords, timeline, chord detail, stems)

- [x] DemuxModels (iOS-shape JSON via PdjJson.lenient; optional drum/melody/transcript fields)
- [x] Chromagram (streaming) + ChordDetector (24 templates, vote + merge, ranged 30 s streaming decode)
- [x] DemuxStore (demux-cache/<key>.json, audio/, carved song once, stems/<key>/ all-or-nothing)
- [x] DemuxStemClient in studio/demux/StemClient.kt (/stemify-custom raw upload + /jobs poll, id regex)
- [x] StemPlayer interface, StemMixState, SingleFileStemPlayer (MediaPlayer), VoiceGroupStemPlayer (synced), RoutingStemPlayer
- [x] DemuxSession (select/resolve ladder, generation + key isCurrent guard, stem state machine) + DemuxEnv
- [x] UI: DemuxScreen, DemuxSourcePicker, DemuxTimeline, ChordDetailSheet, StemsSection
- [x] Wired ProducerScreen (Demuxer tab) + StudioGraph (demuxStore, demuxStemClient, demuxSession)
- [x] Tests: 70 new (ChordDetector, Chromagram, DemuxStore, StemClient, StemPlayerSync, DemuxSession, ChordDetailMath, DemuxTimelineMath/picker rules). Full suite 3751, 0 failures; assembleDebug green.

## Touched outside owned files
- screens/producer/ProducerScreen.kt: one additive `when` branch for Demuxer.
- New (unlisted) files: studio/demux/DemuxSession.kt, studio/demux/StemClient.kt, tests DemuxSessionTest / DemuxTimelineMathTest / ChordDetailMathTest / StemClientTest.

## Deviations
- Chord staves are drawn by a small Canvas (ChordStaffMath) as in iOS StaffChordView, not ScoreLayout (not present yet).
- Catalog-song stemify reuses RipJobTracker (SVC-11); only custom upload is new.
- Save-to-"Pocket DJ"-library button omitted (no profile custom-audio source on Android yet); timeline has the optional onSave hook.
- Timeline: drag on the waveform lane scrubs, chord lane scrolls; follow/zoom buttons recenter.
- Other Studio engines do not pause the Demuxer player when they start (no shared touchpoint); Demuxer pauses them on play.
- Peaks for non-mp3 decode at 8 kHz via AudioDecoder.
- Synced stem player decodes mp3 only (Mp3Decoder), matching burned/server stems.

## Device-only
Real-song chord quality; VoiceGroup stem playback on hardware; Oboe/AudioTrack sink.

## Questions for Levi
- none

## Review
fixes applied
- MAJOR SingleFileStemPlayer.load unguarded -> fixed (StemPlayer.load returns Boolean; MediaPlayer setup in runCatching, half-built player released; enterReady moves to Failed("Couldn’t play this audio"); appScope got a CoroutineExceptionHandler). Tests: unplayableAudioFails…, throwingPlayerLoadIsContained….
- MAJOR DemuxScreen dispose clears on rotation -> fixed (skip clearSource when Activity.isChangingConfigurations; DemuxScreenRules.shouldClearOnDispose, tested).
- MAJOR ledger row -> fixed (STU-14 row now PARTIAL; emulator steps, real-song chords, VoiceGroup hardware playback listed as device-only/pending). Emulator not run (integrator owns it).
- MINOR stemifySong poll -> fixed (READY terminal, 4h deadline); createStems/downloadStems jobs tracked and cancelled by select/clearSource/dispose.
- MINOR player thread races -> fixed (all player load/stop on one-thread playerContext; isCurrent re-checked after refreshStemState and inside the context right before load; generation @Volatile). Test: staleBlockingLoadNeverLeavesAPlayerLoadedAfterReselect.
- MINOR chordRuns -> fixed (StateFlow.update everywhere).
- MINOR importedSources/burned on main -> fixed (produceState on IO, burned keyed on BurnStore.items).
- MINOR setStemMode -> fixed (runs on playerContext, _stemMode only true when stems loaded, falls back to mix). Test: stemModeFallsBackToMixWhenStemsDontLoad. Not done: explicit loading indicator in UI.
- NIT custom-id regex -> fixed (no underscore in tail; StemClientTest assertion that expected "slc_a_b" corrected, it encoded the bug; real ids are UUID-hyphen).
Tests: 3751 -> 3757, 0 failures; assembleDebug green.
