import Foundation

// MARK: - Standard MIDI File writer (spec §7)
//
// Type-0 SMF bytes from a take's RAW event log — deliberately the UNQUANTIZED events (spec §7):
// the MIDI export is the faithful performance for a DAW, while the score is the readable
// simplification; exporting the quantized version would bake ScoreQuantizer's opinions into the
// user's data. Same anchor as everything else: 0 ms = beat 1 = end of count-in, which lands the
// first downbeat exactly on tick 0 so the file bar-aligns in any DAW at the embedded tempo.
//
// Pure `nonisolated` statics returning `Data` (no I/O, no state) — the `.fileExporter` wiring
// (score-export-midi) wraps the bytes; unit tests hand-decode them against fixtures.
enum SMFWriter {

    /// Ticks per quarter note. 480 (spec §7) divides evenly into 16ths (120), 32nds (60), and
    /// triplet 8ths (160) — plenty of resolution for ms-precision events (~1 tick ≈ 1 ms at
    /// 120 BPM) while staying the de-facto interchange default.
    static let ppq = 480

    // MARK: Pure conversion helpers (unit-tested directly)

    /// Variable-length-quantity encoding (the SMF delta-time format): big-endian 7-bit groups,
    /// high bit set on every byte except the last. Always emits ≥ 1 byte (0 → [0x00]).
    nonisolated static func vlq(_ value: UInt32) -> [UInt8] {
        var groups: [UInt8] = [UInt8(value & 0x7F)]
        var rest = value >> 7
        while rest > 0 {
            groups.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
        return groups.reversed()
    }

    /// ms → ticks at `bpm`: one quarter = 60000/bpm ms = `ppq` ticks, so
    /// ticks = ms · bpm · ppq / 60000, rounded to nearest. Guarded to the schema's 120 default
    /// on a degenerate bpm (StudioGrid lenient-decode convention). Never negative — a clock
    /// can't run backwards from the anchor.
    nonisolated static func ticks(fromMs ms: Int, bpm: Double) -> Int {
        let b = bpm > 0 ? bpm : 120
        return max(0, Int((Double(ms) * b * Double(ppq) / 60_000.0).rounded()))
    }

    /// The tempo meta event's payload: microseconds per quarter note (60,000,000 / bpm), e.g.
    /// 120 BPM → 500 000. Same bpm guard as `ticks` so the two can never disagree.
    nonisolated static func microsecondsPerQuarter(bpm: Double) -> UInt32 {
        let b = bpm > 0 ? bpm : 120
        return UInt32((60_000_000.0 / b).rounded())
    }

    // MARK: File assembly

    /// The channel-message sort key at equal ticks: note-OFFS strictly before note-ONS, so a
    /// repeated pitch whose off coincides with the next on retriggers cleanly instead of the
    /// on/off pairing collapsing into a stuck or zero-length note in the importing DAW.
    private enum Order: Int, Comparable {
        case tempo = 0, program = 1, noteOff = 2, noteOn = 3
        static func < (l: Order, r: Order) -> Bool { l.rawValue < r.rawValue }
    }

    /// Serialize a take's events as a complete type-0 SMF. Layout: MThd (format 0, 1 track,
    /// division `ppq`) + one MTrk holding, in tick order: tempo meta at 0, program change at 0
    /// (from `InstrumentKey.gmProgram`, channel 0), the note on/off pairs, end-of-track meta.
    ///
    /// Robustness rules (a hand-edited/corrupt document must yield a valid file, never a
    /// crash or an unreadable export):
    ///   • events with an out-of-range MIDI note are dropped;
    ///   • note-on velocity clamps to 1…127 — velocity 0 IS a note-off in MIDI semantics, so an
    ///     honest 0 would silently delete the note in most DAWs;
    ///   • an off at/before its on is pushed to on + 1 tick (shortest expressible note);
    ///   • running status is NOT used — every event carries its status byte. Costs a few bytes,
    ///     removes a whole class of decoder disagreements, and keeps the fixture tests literal.
    nonisolated static func write(events: [StudioNoteEvent], bpm: Double,
                                  instrument: InstrumentKey) -> Data {
        // (absolute tick, tie-break order, event bytes)
        var track: [(tick: Int, order: Order, bytes: [UInt8])] = []

        let tempo = microsecondsPerQuarter(bpm: bpm)
        track.append((0, .tempo, [0xFF, 0x51, 0x03,
                                  UInt8((tempo >> 16) & 0xFF),
                                  UInt8((tempo >> 8) & 0xFF),
                                  UInt8(tempo & 0xFF)]))
        track.append((0, .program, [0xC0, instrument.gmProgram]))

        for e in events {
            guard (0...127).contains(e.note) else { continue }
            let on = ticks(fromMs: e.onMs, bpm: bpm)
            let off = max(on + 1, ticks(fromMs: e.offMs, bpm: bpm))
            let velocity = UInt8(min(127, max(1, e.velocity)))
            track.append((on, .noteOn, [0x90, UInt8(e.note), velocity]))
            // Off velocity 0x40 (64): the traditional "no release information" midpoint.
            track.append((off, .noteOff, [0x80, UInt8(e.note), 0x40]))
        }

        // Stable order: tick, then the off-before-on tie-break.
        track.sort { $0.tick == $1.tick ? $0.order < $1.order : $0.tick < $1.tick }

        var body: [UInt8] = []
        var lastTick = 0
        for ev in track {
            body += vlq(UInt32(ev.tick - lastTick))
            body += ev.bytes
            lastTick = ev.tick
        }
        body += vlq(0) + [0xFF, 0x2F, 0x00]           // end-of-track at the final tick

        var bytes: [UInt8] = []
        bytes += Array("MThd".utf8) + be32(6)          // header chunk, fixed 6-byte payload
        bytes += be16(0) + be16(1) + be16(UInt16(ppq)) // format 0, 1 track, ticks/quarter
        bytes += Array("MTrk".utf8) + be32(UInt32(body.count))
        bytes += body
        return Data(bytes)
    }

    // Big-endian byte splitters (SMF is big-endian throughout).
    private nonisolated static func be16(_ v: UInt16) -> [UInt8] {
        [UInt8(v >> 8), UInt8(v & 0xFF)]
    }
    private nonisolated static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
}
