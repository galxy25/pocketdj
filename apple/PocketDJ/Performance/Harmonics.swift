import Foundation

// MARK: - Harmonic-distance toolkit
//
// Pure port of `src/engine/harmonics.ts` — the similarity math the realize engine
// builds on. Every distance is NULL-SAFE: ~18% of songs have no audio analysis
// (bpm/camelot nil). camelotDistance + bpmDistance return nil when data is missing;
// the categorical axes (genre/artist/sentiment) always return a finite value.
// `harmonicDistance` DROPS any nil axis and renormalizes the remaining weights, so
// the blend always stays in [0,1] regardless of how much metadata exists.
//
// Operates on `IndexSong` (the native catalog record), whose `bpm`/`camelot` are
// optional. Genre lives on the album in the native catalog, so callers pass it in.

/// Per-axis weights for the blended harmonic distance.
struct HarmonicWeights: Sendable {
    var key: Double
    var bpm: Double
    var genre: Double
    var artist: Double
    var sentiment: Double
}

/// key + bpm dominate (DJ-mix essentials), genre shapes the vibe, sentiment nudges,
/// artist barely matters. Need not sum to 1 — harmonicDistance normalizes by the
/// active weight total.
let DEFAULT_WEIGHTS = HarmonicWeights(key: 0.35, bpm: 0.3, genre: 0.2, artist: 0.05, sentiment: 0.1)

enum Harmonics {
    // --- camelot -----------------------------------------------------------

    /// Decompose a Camelot code into wheel "hour" (1..12) + mode (major = B).
    private static func camelotParts(_ c: String?) -> (hour: Int, major: Bool)? {
        guard let rank = Camelot.rank(c) else { return nil }
        // rank = hour*2 + (B?1:0). B is odd, A even.
        return (rank >> 1, (rank & 1) == 1)
    }

    /// Shortest distance between two wheel hours (1..12), wrapping 12<->1. 0..6.
    private static func hourGap(_ a: Int, _ b: Int) -> Int {
        let raw = abs(a - b)
        return min(raw, 12 - raw)
    }

    /// Camelot-wheel distance in "steps" (0..7), nil if either key is unparseable.
    ///   same code → 0; adjacent hour same mode → 1; relative major/minor → 1;
    ///   else shortest hour gap (0..6) + 1 if modes differ.
    static func camelotDistance(_ a: String?, _ b: String?) -> Double? {
        guard let pa = camelotParts(a), let pb = camelotParts(b) else { return nil }
        if pa.hour == pb.hour && pa.major == pb.major { return 0 }
        let gap = hourGap(pa.hour, pb.hour)
        let modesDiffer = pa.major != pb.major
        if gap == 1 && !modesDiffer { return 1 }
        if gap == 0 && modesDiffer { return 1 }
        return Double(gap + (modesDiffer ? 1 : 0))
    }

    // --- bpm ---------------------------------------------------------------

    /// Spread (in BPM) at which two tempos are maximally far (clamp point).
    private static let bpmSpread = 30.0

    /// Tempo distance, normalized to [0,1], null-safe + half/double-time aware:
    /// folds `b` toward `a` by *2 or /2 while that shrinks the gap.
    static func bpmDistance(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b, a.isFinite, b.isFinite, a > 0, b > 0 else { return nil }
        var folded = b
        var gap = abs(a - folded)
        for _ in 0..<4 {
            var improved = false
            if folded < a {
                let up = folded * 2
                if abs(a - up) < gap { folded = up; gap = abs(a - folded); improved = true }
            } else if folded > a {
                let down = folded / 2
                if abs(a - down) < gap { folded = down; gap = abs(a - folded); improved = true }
            }
            if !improved { break }
        }
        let norm = gap / bpmSpread
        return norm < 0 ? 0 : (norm > 1 ? 1 : norm)
    }

    // --- genre -------------------------------------------------------------

    /// 0 if both strings land in the same top-level star-map category (via
    /// `Genre.category`), else 1. A nil/empty genre maps to "Other".
    static func genreDistance(_ a: String?, _ b: String?) -> Double {
        Genre.category(a) == Genre.category(b) ? 0 : 1
    }

    // --- sentiment ---------------------------------------------------------

    /// 1 − Jaccard(lowercased keyword sets). If EITHER set is empty → 0.5 (neutral).
    static func sentimentDistance(_ a: [String]?, _ b: [String]?) -> Double {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return 0.5 }
        let sa = Set(a.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        let sb = Set(b.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        let inter = sa.intersection(sb).count
        let union = sa.count + sb.count - inter
        if union == 0 { return 0.5 }
        return 1 - Double(inter) / Double(union)
    }

    // --- artist ------------------------------------------------------------

    /// 0 if the same artist (case-insensitive, trimmed) and non-empty, else 1.
    static func artistDistance(_ a: String?, _ b: String?) -> Double {
        let na = (a ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        let nb = (b ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        return na == nb && !na.isEmpty ? 0 : 1
    }

    // --- blended -----------------------------------------------------------

    /// Max camelot-step distance, used to normalize camelotDistance into [0,1].
    static let maxCamelotSteps = 7.0   // 6 hours apart + mode mismatch

    /// Weighted harmonic distance between two songs, in [0,1]. Null-safe: any axis
    /// whose raw distance is nil is DROPPED and the remaining weights renormalized.
    /// If every axis is nil/zero-weight, returns 0.5.
    ///
    /// `genreA`/`genreB` are passed explicitly because the native `IndexSong`
    /// carries genre on its album, not on the song.
    static func harmonicDistance(
        _ a: IndexSong, _ b: IndexSong,
        genreA: String? = nil, genreB: String? = nil,
        weights w: HarmonicWeights = DEFAULT_WEIGHTS
    ) -> Double {
        let camRaw = camelotDistance(a.camelot, b.camelot)
        let bpmRaw = bpmDistance(a.bpm, b.bpm)

        let axes: [(weight: Double, dist: Double?)] = [
            (w.key, camRaw == nil ? nil : camRaw! / maxCamelotSteps),
            (w.bpm, bpmRaw),
            (w.genre, genreDistance(genreA, genreB)),
            (w.artist, artistDistance(a.artist, b.artist)),
            (w.sentiment, sentimentDistance(a.sentimentKeywords, b.sentimentKeywords)),
        ]

        var weighted = 0.0
        var activeWeight = 0.0
        for ax in axes {
            guard let d = ax.dist, d.isFinite, ax.weight > 0 else { continue }
            weighted += ax.weight * d
            activeWeight += ax.weight
        }
        if activeWeight == 0 { return 0.5 }
        let blended = weighted / activeWeight
        return blended < 0 ? 0 : (blended > 1 ? 1 : blended)
    }
}
