import Foundation

// MARK: - Harmonic interpolation
//
// Pure port of `src/engine/interpolate.ts`. realize()'s autofill uses this to splice
// smooth transitions into temporal gaps: `interpolatePath` lays down N target points
// between two anchors (linear bpm ramp + a step around the Camelot wheel along the
// shorter arc + a genre-category crossfade), and `nearestCandidate` snaps the closest
// real catalog song onto a target. Pure + deterministic.

/// One sampled point along the bridge between two anchors.
struct TargetPoint {
    var bpm: Double?        // linear-interpolated (nil when either anchor has no bpm)
    var camelot: String?    // stepped toward the target along the shorter arc (nil if missing)
    var category: String?   // genre top-level category in force at this point (nil if unknown)
    var ratio: Double       // position along the bridge, in (0,1)
}

enum Interpolate {
    /// Fallback duration (ms) a candidate contributes — mirrors RealizeEngine.DEFAULT_TRACK_MS.
    static let defaultCandidateMs = 210_000
    static func candidateMs(_ song: IndexSong) -> Int {
        if let l = song.length, l > 0 { return l }
        return defaultCandidateMs
    }

    /// Number of contiguous wheel positions (1A..12B == 24).
    private static let wheel = Camelot.keys.count   // 24

    /// Step from rank `fromRank` toward `toRank` around the 24-slot Camelot wheel by
    /// `ratio`, choosing the SHORTER direction. Returns the destination Camelot code.
    /// Ranks come from Camelot.rank (A=even, B=odd, contiguous: 1A=2 … 12B=25).
    private static func stepCamelot(_ fromRank: Int, _ toRank: Int, _ ratio: Double) -> String {
        let fromIdx = fromRank - 2
        let toIdx = toRank - 2
        var delta = (toIdx - fromIdx) % wheel
        if delta < 0 { delta += wheel }              // 0..wheel-1
        if delta > wheel / 2 { delta -= wheel }      // shorter arc: -wheel/2 .. wheel/2
        // JS Math.round rounds halves toward +∞ (floor(x + 0.5)); replicate it so a
        // negative (shorter-arc-backwards) delta steps identically to the PWA.
        let stepped = fromIdx + Int((Double(delta) * ratio + 0.5).rounded(.down))
        let idx = ((stepped % wheel) + wheel) % wheel
        return Camelot.keys[idx]
    }

    /// Resolve a raw genre string to its top-level category, or nil when unknown
    /// (the "Other" bucket surfaces as nil so callers treat "no usable genre" uniformly).
    private static func categoryOf(_ genre: String?) -> String? {
        let cat = Genre.category(genre)
        return cat == Genre.other ? nil : cat
    }

    /// Build `steps` target points bridging two anchor songs. For point i (0-based):
    /// ratio = (i+1)/(steps+1). bpm: linear lerp (nil if either anchor's bpm is nil);
    /// camelot: stepped along the shorter wheel arc (nil if either lacks one);
    /// category: from's while ratio < 0.5 else to's. `steps <= 0` yields [].
    static func interpolatePath(_ from: IndexSong, _ to: IndexSong, _ steps: Int,
                                fromGenre: String?, toGenre: String?) -> [TargetPoint] {
        guard steps > 0 else { return [] }

        let fromBpm = from.bpm
        let toBpm = to.bpm
        let bpmOk = fromBpm != nil && toBpm != nil

        let fromRank = Camelot.rank(from.camelot)
        let toRank = Camelot.rank(to.camelot)
        let wheelOk = fromRank != nil && toRank != nil

        let fromCategory = categoryOf(fromGenre)
        let toCategory = categoryOf(toGenre)

        var out: [TargetPoint] = []
        for i in 0..<steps {
            let ratio = Double(i + 1) / Double(steps + 1)
            out.append(TargetPoint(
                bpm: bpmOk ? fromBpm! + (toBpm! - fromBpm!) * ratio : nil,
                camelot: wheelOk ? stepCamelot(fromRank!, toRank!, ratio) : nil,
                category: ratio < 0.5 ? fromCategory : toCategory,
                ratio: ratio
            ))
        }
        return out
    }

    /// Pick the catalog song closest to `target`. Eligibility: not in `used`, BOTH
    /// bpm and camelot present, and `candidateMs <= maxMs`. Score =
    /// wKey·camelotDistance + wBpm·bpmDistance + wGenre·genreDistance, with null axes
    /// dropped. `genreOf` resolves a candidate's genre (lives on its album natively).
    /// Deterministic: ties resolve to the FIRST candidate encountered.
    static func nearestCandidate(
        _ target: TargetPoint,
        candidates: [IndexSong],
        used: Set<String>,
        genreOf: (IndexSong) -> String?,
        weights: HarmonicWeights? = nil,
        maxMs: Int? = nil
    ) -> IndexSong? {
        let wKey = weights?.key ?? 1
        let wBpm = weights?.bpm ?? 1
        let wGenre = weights?.genre ?? 1
        let cap = maxMs ?? Int.max

        var best: IndexSong?
        var bestScore = Double.infinity
        for c in candidates {
            if used.contains(c.id) { continue }
            guard c.bpm != nil, c.camelot != nil else { continue }   // must be beat+key mixable
            if candidateMs(c) > cap { continue }                     // won't fit the budget

            let cam = Harmonics.camelotDistance(target.camelot, c.camelot)
            let bpm = Harmonics.bpmDistance(target.bpm, c.bpm)
            let gen = Harmonics.genreDistance(target.category, genreOf(c))

            var score = wGenre * gen
            if let cam { score += wKey * cam }
            if let bpm { score += wBpm * bpm }

            if score < bestScore { bestScore = score; best = c }
        }
        return best
    }
}
