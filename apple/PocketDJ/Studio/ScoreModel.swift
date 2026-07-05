import Foundation

// MARK: - Score model — quantized notation of an instrument take (spec §7)
//
// Pure value types + `nonisolated` statics (the BeatMath discipline): the quantizer turns a
// take's RAW `StudioNoteEvent` log into a `ScoreDocument` at render time — quantization is never
// persisted, so it can improve without touching saved takes (StudioTake.events doc). The anchor
// convention is load-bearing and shared with the recorder and SMFWriter: **0 ms = beat 1 = the
// end of the count-in** (spec §4/§7), so the score, the replay, and the MIDI export all agree on
// where the music starts.
//
// Model: a voice-less single-staff stream in 4/4 — ONE item sounds at a time (same-onset notes
// are a chord), rests fill every gap, and each measure's items always sum to exactly 16
// sixteenths. v1 has NO ties, so a duration that would cross a barline (or the next onset) is
// truncated to what fits; the remainder becomes rest — a deliberate notational simplification,
// not data loss (the raw events keep the true lengths for replay/MIDI).

// MARK: - Note duration (the snapped rhythmic vocabulary)

/// The only rhythmic values the quantizer emits (spec §7): 16th/8th/quarter/half/whole plus the
/// dotted 8th/quarter/half. `rawValue` IS the length in 16th-note units — the whole rhythmic
/// pipeline (snapping, gap filling, measure packing) is integer math on sixteenths, so there is
/// no float drift anywhere downstream of the initial onset rounding.
enum NoteDuration: Int, CaseIterable, Hashable, Sendable {
    case sixteenth = 1
    case eighth = 2
    case dottedEighth = 3
    case quarter = 4
    case dottedQuarter = 6
    case half = 8
    case dottedHalf = 12
    case whole = 16

    /// Length in 16th-note units (the rawValue, named for readability at call sites).
    var sixteenths: Int { rawValue }

    /// Carries an augmentation dot? (Rendering draws `base` + a dot glyph.)
    var isDotted: Bool {
        self == .dottedEighth || self == .dottedQuarter || self == .dottedHalf
    }

    /// The plain value under a dotted one (what the note-head/flag shape is drawn as); plain
    /// values return self. A dotted 8th draws an 8th head+flag plus a dot, etc.
    var base: NoteDuration {
        switch self {
        case .dottedEighth: return .eighth
        case .dottedQuarter: return .quarter
        case .dottedHalf: return .half
        default: return self
        }
    }

    /// Filled (black) note head? Quarter and shorter are filled; half/whole are open — decided
    /// on the BASE value so a dotted quarter is filled and a dotted half is open.
    var filledHead: Bool { base.rawValue <= NoteDuration.quarter.rawValue }

    /// Stem flags: 2 for a 16th, 1 for an 8th (dotted or not), 0 otherwise.
    var flags: Int {
        switch base {
        case .sixteenth: return 2
        case .eighth: return 1
        default: return 0
        }
    }

    /// Every value except the whole note draws a stem.
    var hasStem: Bool { self != .whole }

    /// All values longest-first — the greedy gap-fill order (`fill`).
    static let descending: [NoteDuration] = allCases.sorted { $0.rawValue > $1.rawValue }

    /// Nearest allowed value to `n` sixteenths. Ties round DOWN to the shorter value — the
    /// quantizer must never INFLATE a note past what was played (an inflated duration eats into
    /// the next onset and gets truncated right back, producing a different, surprising value).
    /// `n ≤ 0` clamps to a 16th (shortest representable); `n ≥ 16` caps at a whole (v1 has no
    /// ties, so nothing longer than one measure is representable).
    static func snapped(toSixteenths n: Int) -> NoteDuration {
        guard n > 0 else { return .sixteenth }
        guard n < NoteDuration.whole.rawValue else { return .whole }
        var best = NoteDuration.sixteenth
        var bestDist = Int.max
        // Ascending scan + strict `<` keeps the FIRST (shortest) value on a distance tie.
        for d in allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            let dist = abs(d.rawValue - n)
            if dist < bestDist { best = d; bestDist = dist }
        }
        return best
    }

    /// Largest allowed value that FITS in `n` sixteenths (min: a 16th). Used after truncation
    /// against the next onset / the barline, where rounding UP would recreate the overlap the
    /// truncation just removed.
    static func snappedDown(toSixteenths n: Int) -> NoteDuration {
        descending.first { $0.rawValue <= max(1, n) } ?? .sixteenth
    }

    /// Greedy longest-first decomposition of a gap (1…16 sixteenths) into allowed values — how
    /// rests are spelled. Greedy is EXACT for this vocabulary: every n in 1…16 decomposes
    /// (16=whole, 15=12+3, 14=12+2, 13=12+1, 11=8+3, 10=8+2, 9=8+1, 7=6+1, 5=4+1, rest are
    /// members), so the loop always terminates with the gap fully covered.
    static func fill(gapSixteenths: Int) -> [NoteDuration] {
        var remaining = gapSixteenths
        var out: [NoteDuration] = []
        while remaining > 0 {
            let d = snappedDown(toSixteenths: remaining)
            out.append(d)
            remaining -= d.sixteenths
        }
        return out
    }
}

// MARK: - Score items / measures / document

/// One slot in the single-voice stream: a chord (1+ simultaneous notes) or a rest, at an offset
/// WITHIN its measure.
struct ScoreItem: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Sorted, de-duplicated MIDI note numbers sounding together (same post-quantize onset).
        case notes([Int])
        case rest
    }

    /// Offset within the measure, in 16ths (0–15) — measure-RELATIVE so layout math is local
    /// (absolute position = `measure.index * 16 + onset16ths`).
    var onset16ths: Int
    var kind: Kind
    var duration: NoteDuration
}

/// One 4/4 measure. The quantizer guarantees `items` are onset-ordered, non-overlapping, and
/// sum to exactly 16 sixteenths (notes + rests) — layout and rendering rely on it.
struct ScoreMeasure: Hashable, Sendable {
    /// 0-based measure number (beat 1 of the take = measure 0, onset 0).
    var index: Int
    var items: [ScoreItem]
}

/// Which physical staff a note head lands on (also selects the clef glyph drawn on that staff).
enum StaffRole: Hashable, Sendable {
    case treble, bass
}

/// The staff configuration for an instrument (spec §7): grand staff for the wide-range
/// instruments, a single treble or bass staff for the rest.
enum ClefPlan: Hashable, Sendable {
    case grandStaff, treble, bass

    /// Per-instrument plan, locked by the spec: grandStaff (piano, harp), treble (violin,
    /// trumpet, clarinet, acoustic guitar), bass (bass guitar). Changing a mapping re-typesets
    /// every saved take's score, so treat it like the GM program table — never "fix" it.
    static func plan(for instrument: InstrumentKey) -> ClefPlan {
        switch instrument {
        case .piano, .harp: return .grandStaff
        case .bassGuitar: return .bass
        case .violin, .trumpet, .clarinet, .acousticGuitar: return .treble
        }
    }

    /// Which staff a note renders on. Grand staff splits at middle C with **note 60 ⇒ treble**
    /// (spec §7 — the split is a spec constant, not a heuristic); single-staff plans put every
    /// note on their one staff regardless of range (ledger lines absorb the extremes).
    func staff(forNote note: Int) -> StaffRole {
        switch self {
        case .treble: return .treble
        case .bass: return .bass
        case .grandStaff: return note >= 60 ? .treble : .bass
        }
    }

    /// The staves this plan draws, top-first — shared by layout (strip construction) and any
    /// consumer that needs to know how tall a system is.
    var staves: [StaffRole] {
        switch self {
        case .grandStaff: return [.treble, .bass]
        case .treble: return [.treble]
        case .bass: return [.bass]
        }
    }
}

/// The quantized score: what ScoreView draws and ScorePDF paginates. Derived (never persisted)
/// — always re-quantized from the take's raw events, so quantizer improvements retroactively
/// improve every saved take's score.
struct ScoreDocument: Hashable, Sendable {
    var measures: [ScoreMeasure]
    /// The take's click/quantize tempo (header display; NOT re-derived from events).
    var bpm: Double
    var clefPlan: ClefPlan
}

// MARK: - Quantizer

/// Pure event-log → notation quantizer (spec §7). All statics, no state — trivially unit-tested
/// and callable from any isolation.
enum ScoreQuantizer {

    /// One 16th note in ms at `bpm` (60000/bpm/4). 0/negative bpm is guarded to the schema's
    /// 120 default (the StudioGrid lenient-decode convention) rather than dividing by zero.
    nonisolated static func sixteenthMs(bpm: Double) -> Double {
        15_000.0 / (bpm > 0 ? bpm : 120)
    }

    /// Quantize a take's raw events into a score.
    ///
    /// Pipeline (each step closes a spec'd requirement):
    ///  1. onsets round to the nearest 16th at `bpm`; 0 ms = beat 1 = measure 0/onset 0 (the
    ///     count-in anchor). Early hits round to onset 0, never negative.
    ///  2. played lengths snap to the `NoteDuration` vocabulary (nearest; ties shorter).
    ///  3. events sharing a post-quantize onset merge into ONE chord item; the chord's duration
    ///     is its longest member's (a single-voice item has exactly one duration — keeping the
    ///     longest preserves the most sound; the truncation below trims any overlap).
    ///  4. single-voice enforcement: a duration is truncated at the NEXT onset and at the
    ///     barline (no ties in v1), then re-snapped DOWN so it stays in vocabulary.
    ///  5. rests fill every gap (leading, between items, and to the end of the last measure),
    ///     split at barlines and spelled by greedy decomposition — every measure sums to 16.
    ///
    /// Events with out-of-range MIDI notes are dropped (a corrupt document must not crash the
    /// score); zero/negative-length events still get the minimum 16th (a tap is a note, not
    /// nothing). No events ⇒ an empty-measures document (callers show an empty state).
    nonisolated static func quantize(events: [StudioNoteEvent], bpm: Double,
                                     instrument: InstrumentKey) -> ScoreDocument {
        let tempo = bpm > 0 ? bpm : 120
        let plan = ClefPlan.plan(for: instrument)
        let step = sixteenthMs(bpm: tempo)

        // 1–3: snap + merge into chords keyed by absolute onset (in 16ths from beat 1).
        var chords: [Int: (notes: Set<Int>, dur16: Int)] = [:]
        for e in events {
            guard (0...127).contains(e.note) else { continue }
            let on16 = max(0, Int((Double(e.onMs) / step).rounded()))
            let raw16 = max(1, Int((Double(e.offMs - e.onMs) / step).rounded()))
            let snapped = NoteDuration.snapped(toSixteenths: raw16).sixteenths
            var c = chords[on16] ?? (notes: [], dur16: 0)
            c.notes.insert(e.note)
            c.dur16 = max(c.dur16, snapped)
            chords[on16] = c
        }
        guard !chords.isEmpty else {
            return ScoreDocument(measures: [], bpm: tempo, clefPlan: plan)
        }

        // 4–5: walk the timeline once, emitting rests for gaps and truncating overlaps.
        let onsets = chords.keys.sorted()
        var flat: [(onset: Int, kind: ScoreItem.Kind, duration: NoteDuration)] = []
        var cursor = 0
        for (i, on) in onsets.enumerated() {
            flat += restItems(from: cursor, to: on)
            let chord = chords[on]!
            let next = i + 1 < onsets.count ? onsets[i + 1] : Int.max
            // Cap at the next onset (single voice) AND the barline (no ties), then snap DOWN.
            // Every cap is ≥ 1 (onsets are distinct; a measure offset is ≤ 15), so this never
            // degenerates below a 16th.
            let headroom = min(chord.dur16, next - on, 16 - on % 16)
            let d = NoteDuration.snappedDown(toSixteenths: headroom)
            flat.append((onset: on, kind: .notes(chord.notes.sorted()), duration: d))
            cursor = on + d.sixteenths
        }
        // Trailing rests pad the FINAL measure to a full 16 — partial measures don't exist.
        let end = ((cursor + 15) / 16) * 16
        flat += restItems(from: cursor, to: end)

        // Split the flat stream into measures. Every measure 0..<count has items by
        // construction (gap measures were rest-filled above).
        var measures = (0..<end / 16).map { ScoreMeasure(index: $0, items: []) }
        for f in flat {
            measures[f.onset / 16].items
                .append(ScoreItem(onset16ths: f.onset % 16, kind: f.kind, duration: f.duration))
        }
        return ScoreDocument(measures: measures, bpm: tempo, clefPlan: plan)
    }

    /// Rest items covering `[from, to)` in absolute 16ths: split at every barline first (a rest
    /// never crosses one), then greedily decomposed within each measure — a full empty measure
    /// comes out as a single whole rest.
    nonisolated static func restItems(from: Int, to: Int)
        -> [(onset: Int, kind: ScoreItem.Kind, duration: NoteDuration)] {
        var out: [(onset: Int, kind: ScoreItem.Kind, duration: NoteDuration)] = []
        var cur = from
        while cur < to {
            let measureEnd = min(to, (cur / 16 + 1) * 16)
            for d in NoteDuration.fill(gapSixteenths: measureEnd - cur) {
                out.append((onset: cur, kind: .rest, duration: d))
                cur += d.sixteenths
            }
        }
        return out
    }
}
