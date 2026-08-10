import Foundation

/// THE one place that answers "how recently was this song played?" — the companion to
/// `PlayCountService.combinedPlayCount`, and deliberately a SEPARATE axis from it.
///
/// ── WHY A SECOND AXIS AND NOT A BETTER PLAY COUNT ────────────────────────────────────────────
/// "Played 40 times, last in 2019" and "played once yesterday" are different facts about a song,
/// and collapsing them into one number throws away the difference. Measured on the owner's
/// library (96,021 songs, 56,224 with any play): the correlation between `log2(1+plays)` and this
/// decay is only r = 0.45, and the two populations that a single score cannot express are real —
/// 629 songs are heavy-but-old (10+ plays, untouched for 3 years) and 475 are light-but-recent
/// (≤2 plays, inside 90 days). Every consumer therefore weights plays and recency SEPARATELY.
///
/// ── WHY A SMOOTH DECAY AND NOT A "PLAYED IN THE LAST 30 DAYS" FLAG ───────────────────────────
/// The owner's last-played dates skew OLD: the median played song was last played 2,117 days
/// (5.8 years) ago, p10 is 913 days, and NOTHING at all was played in the 7 days before the
/// snapshot. Only 485 songs — 0.5% of the catalog — fall inside 30 days. A cliff at 30 or 90 days
/// therefore scores 99.5% of the library identically zero and ranks on a 500-song sliver; the
/// signal has to be a gradient to say anything about the library the user actually has.
enum PlayRecency {

    /// Half-life of the recency signal: a play is worth half as much two years later.
    ///
    /// Chosen by sweeping the owner's real distribution, and it is the only value in the sweep
    /// that is neither a sliver nor a mush:
    ///
    ///   • at a 30–180 day half-life the MEDIAN played song scores 0.000 — the term degenerates
    ///     into "played this season or not" over ~2% of the catalog, and the top 500 songs carry
    ///     19–56% of the whole signal mass;
    ///   • at a 3–5 year half-life the p10→p90 spread collapses to under 4×, so a song played
    ///     yesterday scores barely more than one played three years ago and "recent" stops
    ///     meaning anything;
    ///   • at 730 days the spread is 7.0× and 54,193 of the 56,072 dated songs sit on a live
    ///     gradient (p10 0.060 · median 0.134 · p90 0.419).
    ///
    /// It also puts recency on the SAME SCALE as the play-count signal already shipped, which is
    /// what makes "neither signal dominates" a checkable claim rather than a hope: over the real
    /// library `playCountSignal` has mean 0.196 and this has mean 0.206 — within 5%. At a 1-year
    /// half-life recency would be 2.3× weaker than plays, at 3 years 1.6× stronger. Equal weights
    /// only mean equal influence at this half-life.
    static let halfLifeDays: Double = 730

    /// How far a full-strength recency signal may multiply a Gem Collector pool weight.
    ///
    /// Matched to the shipped play-count bias's dynamic range on purpose — that one tops out at
    /// ×8.94 for the owner's most-played song (244 plays), so `1 + 8·r` topping out at ×9.00
    /// makes the two biases equally strong at their extremes. The median played song lands at
    /// ×2.07 under recency-favor and ×2.00 under play-count-favor: parity by construction.
    static let gain: Double = 8

    /// Exponential decay by age in days. 1.0 at age 0, 0.5 at one half-life, → 0 thereafter.
    ///
    /// A NEGATIVE age (a stamp in the future — device clock skew, a peer device a few hours
    /// ahead, a hand-edited snapshot) clamps to 1.0 rather than growing past it: an unbounded
    /// value here would let one bad timestamp outweigh the entire rest of the library.
    static func decay(ageDays: Double) -> Double {
        guard ageDays.isFinite else { return 0 }
        return pow(0.5, max(0, ageDays) / halfLifeDays)
    }

    /// 0…1 recency of one song from its last-played stamp (epoch ms).
    ///
    /// ABSENT IS ZERO, NOT UNKNOWN. Apple omits the key for a song it has never played, so "no
    /// stamp" means "never played" and 0 is the honest answer — the same convention
    /// `playCountSignal` already uses for an absent count. The genuine unknown is a DEVICE with
    /// no baseline at all, which is not a per-song question: it is answered once per round by
    /// `PlayCountService.hasRecencyData`, and drops the term from the denominator entirely.
    static func score(lastPlayedMs: Double?, nowMs: Double) -> Double {
        guard let lastPlayedMs, lastPlayedMs > 0, lastPlayedMs.isFinite, nowMs.isFinite else { return 0 }
        return decay(ageDays: (nowMs - lastPlayedMs) / 86_400_000)
    }
}
