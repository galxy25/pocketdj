import Foundation

/// **THE SOUND DOOR — a small, capped, skew-proof quota of candidates admitted on AUDIO ALONE.**
///
/// ── THE CEILING THIS EXISTS TO LIFT ──────────────────────────────────────────────────────────
/// `ZoneEngine.suggestions` scores a candidate only after `guard a > 0 || g > 0` — it must
/// ALREADY share an artist or a genre category with the crate. The timbre term therefore only
/// ever re-ranked rows metadata had qualified, inside a band measured at ~1.10× against the
/// genre family's 0.375 additive weight. Measured on a permutation-controlled hold-out (64
/// pockets, 319 rounds, bootstrap clustered on pocket) the term is REAL but lands around rank
/// 1,000 of 84,000: mean rank percentile −2.10pp [−3.16, −1.12] against the identical set of
/// boosts randomly reassigned, while recall@100 (+0.63pp) and MRR (+0.0008) are both NULL. A
/// signal that cannot reach the visible 25 rows is a signal that cannot be heard.
///
/// The same measurement says where it CAN be heard: the whole gain sits where metadata is silent
/// — artist NOT already in the profile −2.86pp [−4.29, −1.51] (significant), artist already in
/// the profile −0.40pp (not significant). So the door is cut exactly there: candidates sharing
/// NEITHER artist NOR genre category with the crate, admitted purely on how they sound.
///
/// ── WHY A QUOTA AND NOT A SCORE ──────────────────────────────────────────────────────────────
/// Folding audio fit into the score as an admission term would put every analysed row in the
/// catalog into the ranking and let a bounded multiplier decide the tile — the failure mode the
/// timbre term was deliberately shaped to avoid. A QUOTA is a bound that is a theorem rather
/// than a hope: at most `soundAdmitHardCap` rows of ~25 can ever be sound-admitted, no ranking
/// change can raise that, and with the quota at zero the engine is byte-identical to today.
///
/// ── THE SKEW GUARD (the failure the coverage audit predicts) ─────────────────────────────────
/// Vector coverage is not uniform: 1970s 54.7% / 1980s 53.4% against 2010s 6.3% / 2020s 2.6%,
/// funk 79% / disco 75% against pop 4.7% / electronic 8.0%. Ranking the admit pool by fit alone
/// would hand the whole quota to the best-covered corner of the corpus — a tile of old vinyl,
/// dressed as discovery. So selection is BUCKET-CAPPED: at most one seat per decade, one per raw
/// genre and one per artist. With a quota of 3 that FORCES three distinct decades, three distinct
/// raw genres and three distinct artists, so coverage skew cannot express itself as tile skew no
/// matter how thoroughly one era dominates the top of the pool. `RecSoundAdmitTests`
/// (`testSoundAdmitCannotFloodTheBestCoveredEraOrGenre`) is that claim as an assertion.
///
/// The buckets are measured on RAW genre labels, not the 16 collapsed categories — an admitted
/// candidate shares no CATEGORY with the crate by construction, so the category is nearly a
/// constant across the pool and would cap nothing.
enum RecSoundAdmit {

    /// At most one admitted row per decade. `nil` year is its own bucket (also capped at one), so
    /// an undated corner of the catalog cannot become the escape hatch the caps do not cover.
    static let maxPerDecade = 1
    /// At most one admitted row per RAW genre label.
    static let maxPerRawGenre = 1
    /// At most one admitted row per artist (`RecNovelty.primaryArtistKey`, the same budget key
    /// the tile's artist cap uses).
    static let maxPerArtist = 1

    /// The net fit an admitted row must still clear against the REJECTED sound. An admitted row
    /// is inside the crate's radius, so its positive fit is 1.0 by construction (the fit
    /// saturates inside the spread) and the negative profile is the only thing left that can
    /// disqualify it. At the shipped `rejectionWeight` of 0.5 this reads as "its fit to the 👎'd
    /// sound must be ≤ 0.2" — a veto rather than a shading, because there is no metadata score
    /// here for a penalty to subtract from.
    static let minNetFit = 0.9

    /// One candidate that cleared the sound door, as the selector sees it.
    struct Candidate: Equatable, Sendable {
        let id: String
        /// `RecNovelty.primaryArtistKey` — the per-artist budget key.
        let capKey: String
        /// `(year / 10) * 10`, or nil for an undated row.
        let decade: Int?
        /// The RAW genre label, normalised (see `genreBucket`), or nil when the row carries none.
        let rawGenre: String?
        /// RMS timbre distance to the crate's centroid — smaller is a closer sound.
        let distance: Double
    }

    /// Case- and whitespace-normalised raw genre, so "Hip-Hop/Rap" and "hip-hop/rap " share a
    /// bucket. Deliberately NOT a genre parser: this is a de-duplication key, and any two labels
    /// a listener would read as one string must not buy two seats.
    static func genreBucket(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let s = raw.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return s.isEmpty ? nil : s
    }

    /// Choose at most `cap` admitted rows: closest sound first, subject to the bucket caps.
    ///
    /// Deterministic on every input — ties break on the id, exactly like the ranking's own sort,
    /// so two runs over the same corpus admit the same rows in the same order.
    static func select(_ pool: [Candidate], cap: Int) -> [Candidate] {
        guard cap > 0, !pool.isEmpty else { return [] }
        let ordered = pool.sorted {
            $0.distance < $1.distance || ($0.distance == $1.distance && $0.id < $1.id)
        }
        var byDecade: [Int: Int] = [:]      // nil year ⇒ the sentinel bucket below
        var byGenre: [String: Int] = [:]
        var byArtist: [String: Int] = [:]
        let undated = Int.min
        let ungenred = "\u{0}none"
        var out: [Candidate] = []
        for c in ordered {
            if out.count >= cap { break }
            let d = c.decade ?? undated
            let g = c.rawGenre ?? ungenred
            let a = c.capKey.isEmpty ? c.id : c.capKey
            guard (byDecade[d] ?? 0) < maxPerDecade,
                  (byGenre[g] ?? 0) < maxPerRawGenre,
                  (byArtist[a] ?? 0) < maxPerArtist else { continue }
            byDecade[d, default: 0] += 1
            byGenre[g, default: 0] += 1
            byArtist[a, default: 0] += 1
            out.append(c)
        }
        return out
    }

    /// The scan's working set stays BOUNDED. The margin test is strict enough that the real pool
    /// is small (tens of rows), but a degenerate corpus — a crate of duplicates, a corpus whose
    /// vectors collapsed — could otherwise grow it to the size of the catalog inside a per-crate
    /// loop. Trimmed to `trimTo` whenever it passes `trimAt`, closest-first: far more rows than
    /// the bucket caps can possibly seat, so the trim can never change which rows are admitted in
    /// any non-degenerate case, and it is deterministic when it does.
    static let trimAt = 4096
    static let trimTo = 1024

    static func trimIfNeeded(_ pool: inout [Candidate]) {
        guard pool.count >= trimAt else { return }
        pool.sort { $0.distance < $1.distance || ($0.distance == $1.distance && $0.id < $1.id) }
        pool.removeSubrange(trimTo...)
    }
}
