import Foundation

/// NOVELTY — the second signal, and the per-artist cap key that makes a cap mean what it says.
///
/// ── WHY A NOVELTY TERM AT ALL, AND WHY IT IS NOT "1 − PLAY COUNT" ────────────────────────────
/// The owner's report was "each tile is recommending multiple Drake songs", and his reason was not
/// only diversity: while the ranking is dominated by play count, a 👍 is nearly REDUNDANT. The
/// engine already read what he plays, so the tile proposes what he plays, and a thumbs-up on it
/// confirms a number the ranker had in hand. Feedback only carries information when the engine
/// proposes something it is genuinely unsure about.
///
/// The obvious fix does NOT work, and the identity is worth writing down because it is invisible
/// until you do the algebra. With song-level novelty `nov = 1 − fam`:
///
///     sim + wf·fam + wn·(1 − fam)  ==  sim + wn + (wf − wn)·fam
///
/// The `wn` is a CONSTANT across every candidate, so it cannot reorder anything: adding song-level
/// novelty at weight `wn` is *exactly* reducing the play weight to `wf − wn`, with a different name.
/// Measured on the real catalog (`scripts/measure-rec-report.mjs`, section 7):
/// Spearman(songNovelty, playTerm) = **−1.000** — one axis, two signs. The harness confirms it
/// operationally too: `fam .15 + songNov .15` produces the same tiles as `fam 0`.
///
/// Dormancy is nearly the same story (Spearman −0.906) AND it is undefined for the 47.9% of the
/// catalog with no last-played date, so using it would promote or bury that half wholesale.
///
/// ── WHAT IS ACTUALLY INDEPENDENT: THE ARTIST, NOT THE SONG ───────────────────────────────────
/// ARTIST-level novelty is the only axis with both real independence and full coverage:
///
///     axis             spearman vs the play term    defined for      resolution
///     songNovelty            −1.000                    100%          40/101 values
///     dormancy               −0.906                  **52%**         99/101
///     artistNovelty        **−0.387**                **100%**        66/101
///     genreNovelty           −0.055                     89%          14/101 — too coarse alone
///
/// It is defined for 100% of songs *because* it is an artist AGGREGATE: a song with no play data
/// still has an artist, and that artist either has plays or does not. That is precisely what keeps
/// it from acting on the 47.8% never-played slice wholesale — measured over the real candidate
/// pools, artist novelty among NEVER-PLAYED songs runs p10 0.34 / median 0.65 / mean 0.679 against
/// p10 0.29 / median 0.52 / mean 0.523 among PLAYED ones. Two overlapping distributions, not a
/// partition: a Drake deep cut he has never pressed play on is still a *familiar* row, and a
/// heavily-played track by an artist he otherwise ignores is still a *novel* one.
///
/// It also has a property the pinned rediscovery tests depend on: because it is constant across a
/// discography, it CANNOT reorder two songs by the same artist. "A buried favourite beats a record
/// he never played" survives intact and is only ever re-decided ACROSS artists.
///
/// ── AND WHY NOVELTY IS NOT ALLOWED TO BECOME RANDOMNESS ──────────────────────────────────────
/// A novel-but-irrelevant suggestion is worse than a familiar one. The boundary is structural, not
/// a matter of tuning: SIMILARITY GATES WHAT IS ELIGIBLE (the artist-or-genre admission rule is
/// untouched), and novelty only ever reorders inside that pool THROUGH A BOUNDED MULTIPLIER —
/// `sim × (1 + gain × aux)`. That makes the limit a theorem rather than a hope: a song can never
/// outrank another whose similarity is more than `1 + gain` times its own. Added on instead, a
/// novelty term has no such bound — at the bottom of the admitted range a flat +0.20 is a 4×
/// swing — which is the shape that turns "novelty" into "noise".
enum RecNovelty {

    // ========================================================================
    // MARK: - The cap key
    // ========================================================================

    /// The PRIMARY artist of a credit string — what a per-artist cap has to key on.
    ///
    /// ── THE BUG THIS FIXES ───────────────────────────────────────────────────────────────────
    /// Every per-artist cap in the app (and in the Lambda) keyed on the raw credit string, so
    /// `Drake & Future` did not consume Drake's budget. Measured over 40 real collection tiles:
    /// Drake held 25 rows under his own name plus 7 more through collaborations — 32 rows under a
    /// cap of 3 per tile — while Future picked up 8 rows of which 7 were invisible to his own cap.
    /// On the cloud tile it is what put four Drake-credited rows into a 50-row list capped at 2.
    ///
    /// A cap that a credit string can walk around is not a cap; it is a suggestion.
    ///
    /// ── WHY A HAND-ROLLED SCAN AND NOT A REGEX ───────────────────────────────────────────────
    /// This runs inside the selector loop of a ranking over a ~108k-row catalog. `NSRegularExpression`
    /// there is a bridging allocation per row for something a single pass over the characters does
    /// exactly as well.
    ///
    /// ── THE DIRECTION OF THE FAILURE MODE IS DELIBERATE ──────────────────────────────────────
    /// This is a BUCKETING key, not an identity. Two genuinely different artists colliding into one
    /// bucket makes the cap STRICTER — the tile loses a row it could have had, which is a diversity-
    /// safe failure. One artist escaping their bucket makes the cap looser, which is the defect
    /// being fixed. So where the two risks trade off, this splits.
    ///
    /// The one collision worth guarding by hand is a comma that is part of a NAME rather than a
    /// list — "Tyler, The Creator" — because it is common and unambiguous: a list item never begins
    /// with "the ". Everything else is left to the separator set.
    static func primaryArtistKey(_ credit: String) -> String {
        let cut = primaryCredit(credit)
        return PuzzleSimilarity.artistKey(cut.isEmpty ? credit : cut)
    }

    /// The part of `credit` before the first collaboration separator, LOWER-CASED (every caller
    /// feeds it to `PuzzleSimilarity.artistKey`, which case-folds anyway — folding once up front is
    /// what keeps the scan below a single pass with no per-character allocation). Exposed so the
    /// tests can pin the splitter itself rather than only its effect on a ranking.
    static func primaryCredit(_ credit: String) -> String {
        let s = Array(credit.lowercased())
        guard !s.isEmpty else { return credit }
        var i = 0
        while i < s.count {
            let c = s[i]
            // A comma always separates — except when what follows is "the", which is a NAME
            // ("Tyler, The Creator"). A list item never begins with "the ".
            if c == "," {
                var j = i + 1
                while j < s.count, s[j] == " " { j += 1 }
                if !matches(s, at: j, Self.theArticle) { return trimmed(String(s[0..<i])) }
                i = j
                continue
            }
            if c == "/" { return trimmed(String(s[0..<i])) }
            // The word-ish separators only count STANDING ALONE between spaces, so "Fetty Wap"
            // does not split on a "with"-shaped middle and "Xavier" is not an " x " collaboration.
            if c == " " {
                for w in Self.wordSeparators where matches(s, at: i + 1, w) {
                    return trimmed(String(s[0..<i]))
                }
            }
            i += 1
        }
        return trimmed(String(s))
    }

    /// Lower-cased, space-terminated collaboration separators. `&` is here rather than treated as a
    /// bare character on purpose: an ampersand INSIDE a name ("Hall & Oates", "Sam & Dave") is
    /// spaced exactly like a collaboration, so the two are genuinely indistinguishable from the
    /// string alone — and per the bucketing rule above, splitting is the safe direction.
    private static let wordSeparators: [[Character]] =
        ["& ", "feat. ", "feat ", "featuring ", "ft. ", "ft ", "with ", "x ", "vs. ", "vs "]
            .map(Array.init)
    private static let theArticle: [Character] = Array("the ")

    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Literal match of an already-lower-cased `word` at `idx`. `word` carries its own terminating
    /// space, which is what gives "x " and "ft " their word boundary.
    private static func matches(_ s: [Character], at idx: Int, _ word: [Character]) -> Bool {
        guard idx + word.count <= s.count else { return false }
        for (k, w) in word.enumerated() where s[idx + k] != w { return false }
        return true
    }

    // ========================================================================
    // MARK: - Artist-level familiarity / novelty
    // ========================================================================

    /// How well the listener knows each ARTIST, 0…1, log-scaled against his own top artist.
    ///
    /// ROUND-LEVEL and normalized against the library's OWN maximum, for the same two reasons the
    /// song-level term is: raw artist totals are hopelessly skewed (top artist 2,796 plays, MEDIAN
    /// artist 2), and normalizing by the observed max is what keeps the term comparable between a
    /// listener with a 40-play top artist and one with a 2,800-play top artist.
    struct ArtistFamiliarity: Sendable, Equatable {
        /// artist key → 0…1 familiarity. Absent ⇒ this artist has no plays at all ⇒ novelty 1.
        private(set) var byArtist: [String: Double] = [:]
        /// Does this device know ANY play counts? When false the whole axis is DEAD and every
        /// lookup returns 0 — the renormalization case, not a silent 1.0 for the entire catalog.
        private(set) var isLive: Bool = false

        init() {}

        init(artistPlays: [String: Int]) {
            let maxPlays = artistPlays.values.max() ?? 0
            guard maxPlays > 0 else { return }
            isLive = true
            let denom = log2(1 + Double(maxPlays))
            guard denom > 0 else { return }
            for (key, n) in artistPlays where n > 0 {
                byArtist[key] = min(1, log2(1 + Double(n)) / denom)
            }
        }

        /// 0…1. Dead axis ⇒ 0 for everyone, so a caller renormalizing over live signals drops it.
        func familiarity(_ artistKey: String) -> Double {
            isLive ? (byArtist[artistKey] ?? 0) : 0
        }

        /// 0…1, 1 = an artist with no plays at all. Dead axis ⇒ 0, so it cannot lift anything.
        func novelty(_ artistKey: String) -> Double {
            isLive ? 1 - (byArtist[artistKey] ?? 0) : 0
        }

        /// How a row earned its novelty, for the "why" line. `nil` when the axis is dead.
        func reason(_ artistKey: String) -> String? {
            guard isLive else { return nil }
            let f = familiarity(artistKey)
            if byArtist[artistKey] == nil { return "An artist you've never played" }
            if f < 0.25 { return "An artist you rarely play" }
            return nil
        }
    }

    /// Fold a catalog into per-artist lifetime plays. One pass, the same pass the ranking already
    /// makes for `maxPlays`, so the axis costs nothing new.
    static func artistFamiliarity<S: Sequence>(_ rows: S) -> ArtistFamiliarity
        where S.Element == (artistKey: String, plays: Int) {
        var totals: [String: Int] = [:]
        for r in rows where r.plays > 0 { totals[r.artistKey, default: 0] += r.plays }
        return ArtistFamiliarity(artistPlays: totals)
    }

    // ========================================================================
    // MARK: - The aux mix
    // ========================================================================

    /// Blend novelty and lifetime familiarity into one 0…1 auxiliary signal, RENORMALIZED over
    /// whichever of the two this device can actually speak.
    ///
    /// Renormalizing (rather than summing over a fixed denominator) is what stops a device with no
    /// play history at all from scoring every candidate a uniformly deflated aux — the same trap
    /// `SimilarityFamilies.termWeights` and `ZoneEngine`'s `hasDormancy` exist to avoid. With no
    /// play data both terms are dead, the denominator is 0, and the caller multiplies by 1.
    ///
    /// The two pull in OPPOSITE directions by construction, and that is the point rather than a
    /// bug: `noveltyWeight` 0.75 against `familiarityWeight` 0.25 is the statement "prefer what you
    /// don't know, but between two equally unknown rows prefer the one you played".
    static func aux(novelty: Double, familiarity: Double,
                    noveltyWeight: Double, familiarityWeight: Double,
                    isLive: Bool) -> Double {
        guard isLive else { return 0 }
        let den = noveltyWeight + familiarityWeight
        guard den > 0 else { return 0 }
        return (noveltyWeight * novelty + familiarityWeight * familiarity) / den
    }
}
