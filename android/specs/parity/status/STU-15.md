state: reviewed

# STU-15 Demux drum pattern + melody + key + instrumental + cut sample + send stems to arrangement + lyrics sidecar panel

Summary: the Demuxer now extracts and hands off beyond chords. DrumPatternDetector (streamed hop-512 STFT flux, adaptive
peak pick, kick/snare/perc/other band ratios, bass-stem low-band lane, bars from sidecar downbeats else gridEstimate,
stepGrid with early-push), MelodyTracker (YIN f0, voiced gate, median smooth, note segmentation, KeyDetector scale snap +
near-octave fold), KeyDetector (KS profiles -> Camelot, from chroma / note events / audio), DemuxInstrumental (comping +
melody events re-anchored to firstDownbeatMs, collision winners) and DemuxTakeSwitch, LyricsSidecar (per-word lossy decode,
lines, gate, panel state, wholesale landing), DemuxAnalyzers (per-key runs persisted on the DemuxDocument), DemuxExporter
(Send bar / Send all bars -> carved kit samples + StudioPattern up to 8192 steps; Extract instrumental/melody -> StudioTake
with demuxSourceKey/demuxMode; Cut sample incl. stem-subset mix; stems -> new/existing arrangement). UI: DrumPatternPanel,
InstrumentalPanel (synced follow score through the shared ScoreEditor), CutSampleSheet, LyricsPanel, DemuxPanels host.

Tests: +90 new JVM tests in 8 files (DrumPatternDetectorTest, MelodyTrackerTest, KeyDetectorTest, DemuxInstrumentalTest,
LyricsSidecarTest, DemuxExportsTest, DemuxAnalysisTest, DemuxPanelMathTest). Full `:app:testDebugUnitTest :app:assembleDebug`
green at the tip: 4550 tests, 0 failures (counts read from build/test-results/testDebugUnitTest).

## Checklist
- [x] KeyDetector, MelodyTracker, DrumPatternDetector
- [x] DemuxInstrumental (+ DemuxInstrumentalContent, DemuxTakeSwitch), LyricsSidecar (+ DemuxFeatures gate)
- [x] DemuxExports (DrumLanes, DrumPatternExport, DemuxCutMath, DemuxExporter), DemuxAnalysis (grid resolver + analyzers)
- [x] DrumPatternPanel, InstrumentalPanel, CutSampleSheet, LyricsPanel, DemuxPanels (host + send-stems dialog)
- [x] Wiring: DemuxScreen, StudioGraph (demuxAnalyzers, demuxExporter), TakesScreen mode-switch menu item
- [x] Tests + full suite green

## Touched outside owned files (all minimal + additive)
- screens/producer/demux/DemuxScreen.kt: thread `graph` into LoadedView/ReadyBody; one `DemuxPanels(...)` call after StemsSection.
- di/StudioGraph.kt: two lazy vals (demuxAnalyzers, demuxExporter) before demuxSession.
- screens/producer/instruments/TakesScreen.kt: optional `onSwitchMode` param on TakeRow + "Switch to melody / chord comping" menu item for takes with demuxSourceKey.
- New unlisted files: studio/demux/{DemuxExports,DemuxAnalysis}.kt, screens/producer/demux/DemuxPanels.kt, tests DemuxInstrumentalTest/LyricsSidecarTest/DemuxExportsTest/DemuxAnalysisTest/screens DemuxPanelMathTest.

## Deviations
- MelodyTracker decodes at 16 kHz (frame 1024 / hop 160 = 10 ms) instead of iOS 2048/512 @ 44.1 kHz: the O(frame x lag) YIN loop is ~25x cheaper on a phone; pitch band and thresholds are unchanged.
- Follow score: the shared ScoreEditor (read-only, host-clock playhead + tap-to-seek) inside a bounded scroll box that auto-scrolls proportionally to elapsed take time, not per-system scrolling. Bar chips + the score share one follow poll (paused scrubs included).
- Cut sample is offered for every source (catalog songs too) since Android has no separate NewSampleFromTrack hand-off for the Demuxer; stem-mix audition drives the Demuxer's own synced player (chips live-mute it) rather than a second private StemPlayer.
- Lyrics are cloud-sidecar only (Android has no on-device recognizer); DemuxFeatures.lyricsEnabled is a @Volatile dev seam (default false), panel shows when gate on OR a cloud sidecar exists/landed.
- A take whose pack bank is not on the device is filed with a short silent placeholder and renderRevision=1 so first play re-renders (and names the pack) instead of replaying silence. iOS wrote a full-length silent file.
- TracksActions.stemSource (arranger Stems picker) is NOT wired here (TracksHomeScreen untouched); stems reach arrangements via the Demuxer's "Send stems to arrangement..." dialog instead.
- Key detection is surfaced as a "Key 8A" line on the instrumental/melody panels (from the converted events); no separate Performance-media key UI (not in this package).
- Build note: running with several parallel Gradle builds, the default -Xmx2g OOMs; used `-Dorg.gradle.jvmargs=-Xmx3g -Pkotlin.daemon.jvmargs=-Xmx3g` on the command line only (gradle.properties untouched).

## Device-only
Real-stem detection quality (drum class thresholds, YIN on real vocals, comping quality), cut-sample stem audition on hardware, emulator steps (Extract drums -> Send bar 1 -> Sequencer rows; Instrumental -> take; Cut sample with stem subset -> smp_) not run (integrator owns the emulator).

## Questions for Levi
- none
