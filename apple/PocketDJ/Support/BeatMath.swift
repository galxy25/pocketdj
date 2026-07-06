import Foundation

/// Shared beat-grid math — pure, `nonisolated` statics so the Mix beat pulse, Studio
/// loop slicing, and unit tests all consume ONE implementation (extracted from
/// `MixView.BeatPulseView`, which previously kept the binary searches private; spec §5).
///
/// Conventions (the whole beat-grid pipeline's contract, see BurnStore/RipsStore):
///   • all beat positions are Int MILLISECONDS from the song's / sample's 0:00
///     (an analog cut's 0:00 == the album `startMs`, a sample's 0:00 == its own start);
///   • `beatsMs` is the REAL measured per-beat grid (handles tempo drift),
///     `downbeatsMs ⊆ beatsMs` marks bar starts, `beatsPerBar` is always 4;
///   • when `beatsMs` is absent, a CONSTANT grid is synthesized from `bpm` +
///     `firstDownbeatMs` (the phase anchor) — mirroring the beat pulse's fallback.
enum BeatMath {
    /// ± tolerance (ms) for near-membership of a beat in `downbeatsMs`. The analyzer's
    /// downbeat timestamps come from the same librosa pass as `beatsMs` but are rounded
    /// independently, so exact equality misses; 30 ms is well under half of the shortest
    /// realistic inter-beat interval (~333 ms at 180 BPM), so it can never smear onto a
    /// neighbouring beat. Same constant the Mix beat pulse always used.
    nonisolated static let downbeatToleranceMs = 30

    /// The most recent beat at/just before `atMs` on the REAL grid + whether it's a bar
    /// downbeat. Binary search (largest `beatsMs` entry ≤ `atMs`) so the 60 fps beat
    /// pulse can call it every frame. nil before the first beat or when the grid is
    /// empty — callers decide their own synthesis fallback (the pulse synthesizes from
    /// BPM; a slicer may refuse).
    nonisolated static func lastBeat(beatsMs: [Int], downbeatsMs: [Int]?, atMs: Double)
        -> (beatMs: Int, isDownbeat: Bool)? {
        guard !beatsMs.isEmpty else { return nil }
        var lo = 0, hi = beatsMs.count                  // largest beat ≤ atMs
        while lo < hi { let mid = (lo + hi) / 2; if Double(beatsMs[mid]) <= atMs { lo = mid + 1 } else { hi = mid } }
        guard lo > 0 else { return nil }                // before the first beat
        let bms = beatsMs[lo - 1]
        return (bms, isDownbeat(bms, downbeatsMs: downbeatsMs))
    }

    /// A bar downbeat? Near-membership (± `downbeatToleranceMs`) of `beatMs` in the
    /// measured `downbeatsMs`. Binary search for the insertion point, then only the two
    /// neighbours can be within tolerance — O(log n) per frame, like `lastBeat`.
    nonisolated static func isDownbeat(_ beatMs: Int, downbeatsMs: [Int]?) -> Bool {
        guard let d = downbeatsMs, !d.isEmpty else { return false }
        var lo = 0, hi = d.count                        // nearest downbeat by binary search
        while lo < hi { let mid = (lo + hi) / 2; if d[mid] < beatMs { lo = mid + 1 } else { hi = mid } }
        return [lo - 1, lo].contains { $0 >= 0 && $0 < d.count && abs(d[$0] - beatMs) <= downbeatToleranceMs }
    }

    /// Beat-aligned loop-slice boundaries (spec §5): starting at the nearest beat ≥
    /// `anchorMs`, walk `beats` beats (½, 1, 2 … 32) through the grid and return the
    /// window. Rules — each one is load-bearing for seamless loops:
    ///   • REAL grid (`beatsMs` non-empty): walk the ACTUAL beat timestamps, so the
    ///     loop length is the sum of the real inter-beat intervals (a tempo-drifting
    ///     track slices on its true beats, not an idealized lattice). A ½-beat walk
    ///     ends at the MIDPOINT between the start beat and the next beat.
    ///   • When the walk runs past the last measured beat (loops near the track's end,
    ///     or an outro the analyzer stopped gridding), the lattice is EXTENDED from the
    ///     last real beat at the constant `60000/bpm` spacing (phase-continuous with
    ///     the measured grid) rather than refusing — audio usually outlives the grid.
    ///   • EMPTY grid: synthesize a constant lattice anchored at `firstDownbeatMs`
    ///     (beats before the anchor don't exist, mirroring `lastBeat`'s nil-before-
    ///     first-beat), and the length is exactly `beats × 60000/bpm`.
    /// Returns nil when there is no usable grid at all (no beats AND no positive bpm),
    /// or `beats ≤ 0`. `lengthMs == endMs − startMs` always; it's returned separately
    /// because `StudioLoop` persists the length as its authoritative duration.
    nonisolated static func sliceBoundaries(anchorMs: Int, beats: Double,
                                            grid: (bpm: Double, firstDownbeatMs: Int, beatsMs: [Int]))
        -> (startMs: Int, endMs: Int, lengthMs: Int)? {
        guard beats > 0 else { return nil }
        let real = grid.beatsMs
        if !real.isEmpty {
            // Constant spacing used ONLY to extend past the measured grid: prefer the
            // stated bpm; with no bpm fall back to the grid's own mean interval (a grid
            // of one beat and no bpm has no usable spacing ⇒ the walk may return nil).
            let step: Double? = grid.bpm > 0 ? 60000.0 / grid.bpm
                : (real.count >= 2 ? Double(real[real.count - 1] - real[0]) / Double(real.count - 1) : nil)
            // First real beat ≥ anchor (binary-search lower bound).
            var lo = 0, hi = real.count
            while lo < hi { let mid = (lo + hi) / 2; if real[mid] < anchorMs { lo = mid + 1 } else { hi = mid } }
            // Beat position n steps into the walk (0 = the start beat), extending past
            // the array on the constant lattice when needed. When even the START is past
            // the last measured beat, snap it to the first EXTENDED beat ≥ anchor so the
            // walk stays phase-continuous with the real grid.
            let last = real.count - 1
            func beatAt(_ n: Int) -> Double? {
                let idx = lo + n
                if idx < real.count { return Double(real[idx]) }
                guard let step else { return nil }
                if lo >= real.count {                   // anchor beyond the last real beat
                    let base = Double(real[last])
                    let k = max(1, Int(ceil((Double(anchorMs) - base) / step)))
                    return base + Double(k + n) * step
                }
                return Double(real[last]) + Double(idx - last) * step
            }
            guard let start = beatAt(0) else { return nil }
            let whole = Int(beats.rounded(.down))
            let frac = beats - Double(whole)
            let end: Double
            if frac == 0 {
                guard let e = beatAt(whole) else { return nil }
                end = e
            } else {                                    // ½-beat: interpolate between adjacent beats
                guard let a = beatAt(whole), let b = beatAt(whole + 1) else { return nil }
                end = a + frac * (b - a)
            }
            let s = Int(start.rounded()), e = Int(end.rounded())
            return (s, e, e - s)
        }
        // No measured beats: constant-grid synthesis from bpm + the downbeat phase.
        guard grid.bpm > 0 else { return nil }
        let step = 60000.0 / grid.bpm
        let n = max(0, Int(ceil((Double(anchorMs) - Double(grid.firstDownbeatMs)) / step)))
        let start = Double(grid.firstDownbeatMs) + Double(n) * step
        let len = Int((beats * step).rounded())         // spec: beats × 60000/bpm exactly
        let s = Int(start.rounded())
        return (s, s + len, len)
    }

    /// Up to `count` slice START points partitioning `[0, durationMs)` for auto-slicing a sample
    /// (spec: slicing → pads). With a grid, the even-time cut points are SNAPPED to the nearest beat
    /// so pads land on the groove; grid-less, it's a plain even time chop. Pad 0 is always 0 (tap
    /// from the top). De-duped + sorted — coincident snaps just yield fewer than `count` pads.
    nonisolated static func sliceStarts(count: Int,
                                        grid: (bpm: Double, firstDownbeatMs: Int, beatsMs: [Int])?,
                                        durationMs: Int) -> [Int] {
        let n = max(1, min(count, 8))                       // 8 = the pad-grid cap (not coupled to the model)
        guard durationMs > 0 else { return [0] }
        let targets = (0..<n).map { $0 * durationMs / n }
        guard let g = grid, let beats = beatLattice(grid: g, durationMs: durationMs), !beats.isEmpty else {
            return targets
        }
        var out = targets.map { t in beats.min(by: { abs($0 - t) < abs($1 - t) }) ?? t }
        out[0] = 0                                          // the first pad always plays from 0:00
        return Array(Set(out)).sorted()
    }

    /// Beat positions in `[0, durationMs)` — the real measured grid when present, else a constant
    /// lattice from `bpm` phased on `firstDownbeatMs`. nil when there's no usable grid.
    private nonisolated static func beatLattice(grid g: (bpm: Double, firstDownbeatMs: Int, beatsMs: [Int]),
                                                durationMs: Int) -> [Int]? {
        if !g.beatsMs.isEmpty {
            return g.beatsMs.filter { $0 >= 0 && $0 < durationMs }
        }
        guard g.bpm > 0 else { return nil }
        let step = 60_000.0 / g.bpm
        var x = Double(g.firstDownbeatMs)
        while x - step >= 0 { x -= step }                   // rewind to the earliest in-range beat
        var out: [Int] = []
        while x < Double(durationMs) {
            if x >= 0 { out.append(Int(x.rounded())) }
            x += step
        }
        return out
    }
}
