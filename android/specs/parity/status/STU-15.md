state: in-progress

# STU-15 Demux drum pattern + melody + key + instrumental + cut sample + send stems + lyrics

## Checklist
- [x] KeyDetector, MelodyTracker (YIN @16 kHz), DrumPatternDetector (streamed hop-512 flux, bars, stepGrid)
- [x] DemuxInstrumental (+ content, DemuxTakeSwitch), LyricsSidecar (+ gate, lossy decode, lines, panel state)
- [x] DemuxExports (pure export plan + DemuxExporter I/O)
- [ ] Analyzers wiring (drum/melody/lyrics fetch) + panels (DrumPatternPanel, InstrumentalPanel, CutSampleSheet, LyricsPanel)
- [ ] DemuxScreen wiring, Takes-menu switch
- [ ] Tests
