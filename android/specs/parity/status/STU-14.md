state: implemented

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
