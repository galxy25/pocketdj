import Foundation

// MARK: - Arpeggiator (pure timing/order math — no AV imports, fully unit-testable)
//
// The Instruments-tab arpeggiator's brain, separated from the audio engine the way
// `InstrumentEngine.replayActions` is: everything here is `nonisolated`/static value math, so
// the order permutations and the swing clock are pinned by unit tests, and the `@MainActor`
// scheduling loop in `InstrumentEngine.startArpPlayback` stays a thin sleep-and-strike shell.

/// Playback order of the recorded note set. `exclusive`/`inclusive` are the up-down variants
/// that EXCLUDE/INCLUDE the repeated endpoints; `order` replays the notes in the order they
/// were recorded; `random` draws each slot uniformly from the pool through an injected RNG
/// (tests seed it — the engine passes `SystemRandomNumberGenerator`).
enum ArpOrder: String, Codable, CaseIterable, Sendable {
    case up, down, exclusive, inclusive, order, random
}

/// Step duration as a note value. Raw value = the note's DENOMINATOR (4 = quarter … 32 = 1/32),
/// which is what persists in settings — a changed mapping would silently re-time saved knobs.
enum ArpStepLength: Int, Codable, CaseIterable, Sendable {
    case thirtysecond = 32, sixteenth = 16, eighth = 8, quarter = 4
}

/// The arp's knob state (the panel mirrors this into `InstrumentEngine.arpSettings`).
/// `latch` ON ⇒ play mode loops the cycle until toggled off; OFF ⇒ exactly one full cycle.
struct ArpSettings: Equatable, Sendable {
    var order: ArpOrder = .up
    var length: ArpStepLength = .sixteenth
    var octaves: Int = 1                     // 1…4, clamped by the math below
    var swingPct: Double = 50                // 50…75, clamped by the math below
    var latch: Bool = true
}

enum ArpPattern {

    /// Ceiling for any onset the schedule can produce — shared with the replay clock so arp
    /// math can never hand the scheduler an un-clamped Int (the StaffChordView Int.min lesson).
    static let maxOnsetMs = 86_400_000

    /// The note POOL for a recorded set + octave count: for each octave k in `0..<octaves` the
    /// recorded notes shifted up 12k, insertion order preserved WITHIN each octave (the `.order`
    /// contract), out-of-MIDI-range notes dropped, duplicates dropped (first occurrence wins).
    static func pool(notes: [Int], octaves: Int) -> [Int] {
        let octs = max(1, min(4, octaves))
        var seen = Set<Int>()
        var out: [Int] = []
        for k in 0..<octs {
            for n in notes {
                let shifted = n + 12 * k
                guard (0...127).contains(shifted), seen.insert(shifted).inserted else { continue }
                out.append(shifted)
            }
        }
        return out
    }

    /// One full cycle of MIDI notes for the recorded set + settings. `notes` is the RECORDED
    /// order (insertion order, deduped). Deterministic for every mode except `.random`, which
    /// draws through the injected RNG.
    static func cycle(notes: [Int], order: ArpOrder, octaves: Int,
                      rng: inout any RandomNumberGenerator) -> [Int] {
        let p = pool(notes: notes, octaves: octaves)
        guard !p.isEmpty else { return [] }
        let asc = p.sorted()
        switch order {
        case .up:
            return asc
        case .down:
            return asc.reversed()
        case .exclusive:
            // Ascending, then the descending INTERIOR — endpoints never repeat back-to-back:
            // [a,b,c] → a b c b (period 2n−2); n==2 → a b; n==1 → a.
            guard asc.count > 2 else { return asc }
            return asc + asc.dropFirst().dropLast().reversed()
        case .inclusive:
            // Ascending then descending with BOTH endpoints repeated: [a,b,c] → a b c c b a
            // (period 2n); n==1 → a a.
            return asc + asc.reversed()
        case .order:
            return p                                   // recorded order, replicated per octave
        case .random:
            // Cycle length = pool size; each slot an independent uniform draw from the pool.
            return (0..<p.count).map { _ in p[Int.random(in: 0..<p.count, using: &rng)] }
        }
    }

    /// One step's duration in ms at `bpm` — pure Double (a quarter at `bpm` is 60000/bpm ms).
    /// Non-finite/non-positive bpm degrades to 120, the `InstrumentEngine.barSeconds` convention.
    static func stepMs(length: ArpStepLength, bpm: Double) -> Double {
        let b = (bpm.isFinite && bpm > 0) ? bpm : 120
        return 60_000.0 / b * 4.0 / Double(length.rawValue)
    }

    /// Onset of step `k` within a cycle, swing applied. Steps come in pairs: the even step sits
    /// on the grid, the odd step is pushed to `swingPct` of the pair (50% = straight, 66.7% =
    /// triplet swing, 75% = hard cap). Double math, clamped BEFORE the Int conversion.
    static func onsetMs(step: Int, stepMs: Double, swingPct: Double) -> Int {
        clampMs(onsetDouble(step: step, stepMs: stepMs, swingPct: swingPct))
    }

    /// The step's gate-off time: 80% of the gap to the NEXT onset — a swung short step gets a
    /// proportionally short gate, so notes never overlap their successor.
    static func gateOffMs(step: Int, stepMs: Double, swingPct: Double) -> Int {
        let on = onsetDouble(step: step, stepMs: stepMs, swingPct: swingPct)
        let next = onsetDouble(step: step + 1, stepMs: stepMs, swingPct: swingPct)
        return clampMs(on + 0.8 * (next - on))
    }

    // MARK: internals

    private static func onsetDouble(step: Int, stepMs: Double, swingPct: Double) -> Double {
        guard stepMs.isFinite, stepMs > 0, step >= 0 else { return 0 }
        let s = min(max(swingPct.isFinite ? swingPct : 50, 50), 75) / 100
        let pairMs = 2 * stepMs
        let base = Double(step / 2) * pairMs
        return step.isMultiple(of: 2) ? base : base + pairMs * s
    }

    /// Clamp a Double ms to `0…maxOnsetMs` before Int conversion (never trap on wild input).
    private static func clampMs(_ ms: Double) -> Int {
        guard ms.isFinite else { return 0 }
        return Int(min(max(ms, 0), Double(maxOnsetMs)).rounded())
    }
}
