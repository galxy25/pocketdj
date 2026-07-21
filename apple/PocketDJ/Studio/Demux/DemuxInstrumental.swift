import Foundation

// MARK: - Demux ▸ chord-comping instrumental (F8 slice A)
//
// Pure value math (the BeatMath / ScoreQuantizer discipline: `nonisolated static`, no state,
// unit-tested directly). Turns the ALREADY-DETECTED, time-synced chord blocks (`DemuxChordSegment`
// in `doc.chords` — never re-analyzed) into a beat-quantized CHORD-COMPING instrumental: a stream
// of `StudioNoteEvent`s the Instruments tab plays/edits as a plain `StudioTake` and the score
// quantizer renders as notation. This is the HARMONY reduction of the chord timeline, NOT a melody
// (true monophonic pitch-tracking is a separate, later slice — see f8-demux-instrumental).
//
// Two load-bearing rules the score alignment depends on:
//   • each chord holds for the NUMBER OF BEATS it spans on the real grid (measured `beatsMs` when
//     present, else a constant grid from `bpm`), min 1;
//   • all times RE-ANCHOR to `firstDownbeatMs` so 0 ms = beat 1 — the exact anchor
//     `ScoreQuantizer` snaps to, so the instrumental's bar lines line up with the drum pattern's
//     bars. Emit the FULL TRIAD (`chord.midiNotes(base:60)`) as N same-onset events; the quantizer
//     merges same-onset notes into ONE chord `ScoreItem` (chords render + play). Gaps between
//     chords emit nothing — the quantizer fills them with rests (never invent a chord).
enum DemuxInstrumental {

    /// The beat grid the converter reads: scalar tempo + the count-in anchor + the REAL measured
    /// per-beat timestamps (empty ⇒ a constant grid synthesized from `bpm`, the `StudioGrid`
    /// convention). Labeled tuple so call sites read like the spec (`grid: (bpm:firstDownbeatMs:beatsMs:)`).
    typealias Grid = (bpm: Double, firstDownbeatMs: Int, beatsMs: [Int])

    /// Number of beats a `[startMs, endMs)` region spans: the count of measured `beatsMs` inside it
    /// when the real grid is present, else `round((endMs-startMs)·bpm/60000)`. Always ≥ 1 (a chord
    /// shorter than a beat still sounds for one beat — "hold each chord for the beats it spans").
    nonisolated static func beatsSpanned(startMs: Int, endMs: Int, grid: Grid) -> Int {
        if !grid.beatsMs.isEmpty {
            let n = grid.beatsMs.lazy.filter { $0 >= startMs && $0 < endMs }.count
            if n >= 1 { return n }
            // A chord that falls entirely between two measured beats still gets one beat below.
        }
        let bpm = grid.bpm > 0 ? grid.bpm : 120
        let n = Int((Double(endMs - startMs) * bpm / 60_000.0).rounded())
        return max(1, n)
    }

    /// Snap a time to the nearest beat: the closest measured `beatsMs` when present, else the
    /// nearest constant-grid beat anchored at `firstDownbeatMs`. Chord starts snap so the score
    /// items land on beats, not a chromagram's ragged segment boundaries.
    nonisolated static func snapToBeat(ms: Int, grid: Grid) -> Int {
        if !grid.beatsMs.isEmpty {
            return grid.beatsMs.min(by: { abs($0 - ms) < abs($1 - ms) }) ?? ms
        }
        let bpm = grid.bpm > 0 ? grid.bpm : 120
        let beatMs = 60_000.0 / bpm
        let k = (Double(ms - grid.firstDownbeatMs) / beatMs).rounded()
        return grid.firstDownbeatMs + Int((k * beatMs).rounded())
    }

    /// Convert chord segments → a beat-quantized chord-comping event stream + the take's bpm.
    ///
    /// For each chord (in start order): count the beats it spans, snap its start to the nearest
    /// beat, re-anchor to `firstDownbeatMs` (0 ms = beat 1, clamped ≥ 0), and emit the full triad
    /// as same-onset events lasting `beats · 60000/bpm`. `take.bpm` = the grid's bpm.
    nonisolated static func events(chords: [DemuxChordSegment], grid: Grid)
        -> (events: [StudioNoteEvent], bpm: Double) {
        let bpm = grid.bpm > 0 ? grid.bpm : 120
        let beatMs = 60_000.0 / bpm
        var out: [StudioNoteEvent] = []
        for chord in chords.sorted(by: { $0.startMs < $1.startMs }) {
            let beats = beatsSpanned(startMs: chord.startMs, endMs: chord.endMs, grid: grid)
            let onMs = max(0, snapToBeat(ms: chord.startMs, grid: grid) - grid.firstDownbeatMs)
            let offMs = onMs + Int((Double(beats) * beatMs).rounded())
            for note in chord.midiNotes(base: 60) {
                out.append(StudioNoteEvent(onMs: onMs, offMs: offMs, note: note, velocity: 88))
            }
        }
        return (out, bpm)
    }
}
