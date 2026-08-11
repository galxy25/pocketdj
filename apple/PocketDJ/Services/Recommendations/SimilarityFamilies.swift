import Foundation

/// THE THREE SIMILARITY FAMILIES — the owner's rebalance, expressed as one small pure type.
///
/// The brief: recommendations should not be "just artist based" but weighted roughly EVENLY
/// across three comparable families —
///
///   **A** artist            **B** genre + year            **C** genre + bpm + key/camelot
///
/// ── WHY A SEPARATE TYPE AND NOT MORE TERMS BOLTED ONTO `PuzzleSimilarity` ────────────────────
/// `PuzzleSimilarity` is a SEVEN-TERM scorer with shipped constants and a Gem Collector
/// scoreboard behind it. Adding bpm/key to its default term list would move every ranking that
/// game has ever produced to buy a puzzle a signal it has no use for — "does this belong in the
/// same crate" is not a question tempo answers. So the family balance lives here, `PuzzleSimilarity`
/// takes it as an OPTIONAL parameter (`balance:`, default nil ⇒ byte-identical to today), and the
/// puzzle passes nil.
///
/// ── THE DECOMPOSITION: THREE FAMILIES ARE FOUR TERMS ─────────────────────────────────────────
/// Each family is the MEAN of the fields it is made of, so the blend is exactly term-separable:
///
///     B = mean(genreFit, yearFit)          C = mean(genreFit, musicalFit)
///     score = wA·artist + wB·B + wC·C
///           = wA·artist + (wB/2 + wC/2)·genre + (wB/2)·year + (wC/2)·musical
///
/// That identity is why this file hands `PuzzleSimilarity` a flat `TermWeights` rather than a
/// nested scorer: the family model is the DESIGN, the term vector is the implementation, and the
/// two are provably the same number.
///
/// ── WHAT THE REAL CATALOG SAYS (scripts/measure-similarity-families.mjs, 109,392 songs) ──────
///   COVERAGE      artist 100% · genre 98.7% · year 99.2% · bpm 10.4% · camelot 10.4%
///                 by source: vinyl 83.7% bpm, "My Digital" 99.9%, **Apple Music 0.0%**
///   GENRE         613 distinct raw album-genre strings; 81 of them (34 groups) are punctuation
///                 variants of another ("Hip-Hop/Rap" ≡ "Hip Hop/Rap" — 21,166 + 1,980 songs;
///                 "R&B/Soul" ≡ "R&B / Soul" ≡ "R&Bsoul"). `Genre.category` already collapses all
///                 34 groups correctly, which is why this file canonicalizes THROUGH it rather
///                 than inventing a second normalizer — see `canonicalGenre`.
///                 After collapse: hip-hop 26.0%, soul 18.8%, pop 14.7% — top 3 = 59.5% of the
///                 library. Genre ALONE is a weak discriminator here, exactly as the owner said;
///                 pairing it with year and with bpm/key is the whole point of B and C.
///
/// ── HOW ARTIST "DOMINATES" — IT IS NOT THE WEIGHT ────────────────────────────────────────────
/// Worth stating precisely, because the obvious reading is wrong. `wArtist` (0.30) is already
/// SMALLER than `wGenre + wYear` (0.40), so on any single head-to-head the shipped weights do not
/// favour the artist. Artist dominates by SELECTIVITY: it fires for ~1% of the catalog and scores
/// ~1.0 when it does — a near-binary spike — while genre+year fires for 99% of it at a mean of
/// 0.44, a smooth blanket that separates almost nothing at the top. The songs that reach the top
/// of a ranking are therefore overwhelmingly the ones the artist term picked out.
///
/// ── "EVENLY" IS BY EFFECT, AND THE WEIGHTS ARE MEASURED, NOT ASSUMED ─────────────────────────
/// Because the three families have such different SHAPES, equal nominal weights do NOT produce
/// equal influence — that is the trap. Measured by `scripts/measure-similarity-families.mjs
/// --seeds 60` over the real catalog (sections 6 and 7), on top-90 queues — the only part of a
/// ranking a For You tile ever reads. SURVIVAL is Jaccard against each family's SOLO top-90 ("how
/// much of what this family wanted survived the blend"); SEED-ARTIST is the share of the top-90
/// held by an artist already in the seed profile:
///
///     weights (A / B / C)          seed-artist   survA   survB   survC   A/B ratio
///     shipped today (no C)            91.6%      0.337   0.064   0.007     5.28
///     nominal even ⅓/⅓/⅓             72.7%      0.279   0.165   0.031     1.69
///     .30 / .35  / .35                70.1%      0.267   0.177   0.033     1.51
///     **.25 / .375 / .375 SHIPPED**   63.9%      0.246   0.217   0.036     1.13
///     .20 / .40  / .40                57.6%      0.222   0.255   0.039     0.87
///
/// Nominal ⅓ each already helps a lot (5.28 → 1.69), but it stops short: family C takes its weight
/// out of YEAR — the only high-resolution field family B owns — and hands it to a field 90% of the
/// catalog cannot speak, so B does not gain what A loses. A quarter on artist is what actually
/// brings A and B level (1.13), and it takes the artist's grip on the tile from 92% to 64%.
/// Pushing further (0.20) overshoots into B dominating A, for a further 6 points of seed-artist
/// share — not worth giving up the one signal a human names first.
///
/// Family C **cannot** be brought to parity by effect and that is deliberate: only ~10% of the
/// catalog carries bpm+camelot at all. Weighting C up until it wins a third of the picks would
/// make "has this been beat-gridded yet" (i.e. "is it vinyl") decide a third of every queue. Its
/// share rises on its own as the audio indexer backfills Apple Music.
///
/// ── THE MISSING-METADATA RULE — THREE MECHANISMS, ALL ROUND-LEVEL ────────────────────────────
/// Conflating these is the classic sparse-feature bug:
///
///  1. `termWeights` — a family whose fields the PROFILE cannot speak at all leaves the
///     denominator entirely. No bpm anywhere in the seed set ⇒ C collapses to genre alone and the
///     weight redistributes. Evaluated ONCE per round.
///
///  2. `MusicalCalibration.neutral` — a song with no bpm and no camelot is scored at the MEASURED
///     MEAN of the musical term OVER THIS ROUND'S CANDIDATE POOL. Scoring it 0 would bury 90% of
///     the library for lacking a field the indexer has not reached yet; DROPPING the term for that
///     song (a per-song denominator) would REWARD it for having less metadata, which is precisely
///     the bug `PuzzleSimilarity.availableWeight`'s doc-comment refuses to introduce and a test
///     pins. Mean-imputation is neither — and measuring the mean PER ROUND rather than baking in a
///     global constant is what makes it unbiased in every regime, including a seed whose keys span
///     the whole Camelot wheel (where the term genuinely carries no information and its realized
///     mean is high). Measured over 12,000 ablations (section 7): stripping bpm+camelot from songs
///     that have them moves the score by a mean of **0.0000** (median 0.0000, 49.5% up / 38.8%
///     down) — no systematic bias in either direction, at every candidate weight vector.
///
///  3. `musicalPrior` — SHRINKAGE. A song's musical fit is one or two noisy observations, so it is
///     pulled toward the round neutral in proportion to how little evidence it carries. Without it
///     a partially-observed feature over-selects at the top of a ranking purely by VARIANCE (the
///     winner's curse) even when the imputation is perfectly unbiased: the 10% of songs that can
///     reach 1.0 crowd out the 90% pinned at the mean, and "has this been beat-gridded yet" — i.e.
///     "is it vinyl" — starts deciding the queue.
///
///     Reproduce with `--prior 0` against the shipped `--prior 2`. At the shipped weights, the
///     share of the top-90 held by bpm/key-bearing songs against a 10.35% base rate:
///
///         shrinkage OFF   26.7%  (2.58×)   family-C survival 0.075
///         shrinkage ON    17.1%  (1.65×)   family-C survival 0.036
///
///     It IS a trade, and it is worth naming rather than glossing: family C's voice halves. The
///     reason to take it is that the half being removed is the part driven by which 10% of the
///     library the audio indexer happens to have reached, not by which songs actually fit — and
///     family B gains most of what C gives up (survival 0.169 → 0.217). When the indexer finishes
///     backfilling Apple Music this constant should come back down; it is a correction for sparse
///     coverage, not a statement about tempo.
enum SimilarityFamilies {

    // ========================================================================
    // MARK: - The balance
    // ========================================================================

    /// Relative pull of the three families. Ratios, not a partition — `termWeights` renormalizes.
    struct Balance: Equatable, Sendable {
        var artist: Double
        var genreYear: Double
        var genreMusical: Double

        /// SHIPPED. "Evenly" measured by EFFECT rather than asserted by nominal weight — see the
        /// table in the type doc. A quarter on artist is what brings families A and B level on the
        /// real catalog; equal thirds leave artist 1.85× louder than genre+year.
        static let even = Balance(artist: 0.25, genreYear: 0.375, genreMusical: 0.375)
        /// Nominal thirds. NOT shipped — kept because the tests compare the two directly, and a
        /// constant is a better record of "we measured this and rejected it" than a comment.
        static let nominalThirds = Balance(artist: 1.0 / 3, genreYear: 1.0 / 3, genreMusical: 1.0 / 3)
        /// The shipped-today shape, for A/B comparison in tests: artist twice genre-ish, no
        /// musical term at all.
        static let artistDominant = Balance(artist: 0.55, genreYear: 0.45, genreMusical: 0)

        public init(artist: Double, genreYear: Double, genreMusical: Double) {
            self.artist = max(0, artist)
            self.genreYear = max(0, genreYear)
            self.genreMusical = max(0, genreMusical)
        }
    }

    /// The four flat term weights the families decompose into (see the type doc).
    struct TermWeights: Equatable, Sendable {
        var artist: Double = 0
        var genre: Double = 0
        var year: Double = 0
        var musical: Double = 0
        var total: Double { artist + genre + year + musical }
    }

    /// Total weight the three families are scaled to occupy inside `PuzzleSimilarity`'s seven-term
    /// score. It is EXACTLY today's `wArtist + wGenre + wYear` (0.30 + 0.25 + 0.15), so switching
    /// the balance on redistributes weight strictly AMONG the three families and leaves the four
    /// auxiliary terms (co-membership, lyrics, co-play, recency) holding the same 33% share of the
    /// score they hold today. The rebalance the owner asked for is between artist / genre+year /
    /// genre+bpm+key — it is not an excuse to quietly demote the lyrics or shared-crate signals.
    static let familyTotal = PuzzleSimilarity.wArtist + PuzzleSimilarity.wGenre + PuzzleSimilarity.wYear

    /// ROUND-LEVEL renormalization: which of the four terms this PROFILE can speak, folded into
    /// the family weights. A family with no live component drops out; a family with one live
    /// component keeps its whole weight on that component.
    ///
    /// Scaled so the four weights sum to `familyTotal` whenever anything is live at all — a device
    /// missing every musical field must not end up with a systematically SMALLER total score than
    /// one that has them (that would make any absolute threshold quietly stricter for it, the same
    /// trap `hasRecency` was added to avoid).
    static func termWeights(_ balance: Balance = .even,
                            hasGenre: Bool, hasYear: Bool, hasMusical: Bool,
                            scaledTo total: Double = familyTotal) -> TermWeights {
        var w = TermWeights()
        w.artist = balance.artist
        // B = genre + year
        let bLive = (hasGenre ? 1.0 : 0) + (hasYear ? 1.0 : 0)
        if bLive > 0 {
            let each = balance.genreYear / bLive
            if hasGenre { w.genre += each }
            if hasYear { w.year += each }
        }
        // C = genre + musical
        let cLive = (hasGenre ? 1.0 : 0) + (hasMusical ? 1.0 : 0)
        if cLive > 0 {
            let each = balance.genreMusical / cLive
            if hasGenre { w.genre += each }
            if hasMusical { w.musical += each }
        }
        let sum = w.total
        guard sum > 0, total > 0 else { return TermWeights() }
        let k = total / sum
        return TermWeights(artist: w.artist * k, genre: w.genre * k,
                           year: w.year * k, musical: w.musical * k)
    }

    // ========================================================================
    // MARK: - Genre canonicalization
    // ========================================================================

    /// The canonical genre key both the profile and the candidates must be keyed by.
    ///
    /// Delegates to `Genre.category` ON PURPOSE rather than adding a second normalizer: that
    /// matcher is already an ordered, lowercased, SUBSTRING matcher, which is exactly what makes
    /// "Hip-Hop/Rap", "Hip Hop/Rap", "Hip-hop" and "HipHop" land on one bucket. Measured on the
    /// real catalog it collapses all 34 punctuation-variant groups (81 raw labels) correctly, so a
    /// second normalizer would only be a second thing to drift. The rule this enforces is that
    /// EVERY caller goes through one function — a family keyed on raw labels silently splits.
    static func canonicalGenre(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Genre.category(raw)
    }

    // ========================================================================
    // MARK: - The era window (a collection's year range)
    // ========================================================================

    /// A collection's ERA — the year range its own members occupy.
    ///
    /// Owner, verbatim: *"also factor in year range for recommendation along with genre as a
    /// feature, eg some playlist like 808 & swinging is very new jack swing 88-94 r&b."* So a
    /// collection carries a year WINDOW derived from its own members, and candidates for THAT
    /// collection score on era fit alongside genre — a FEATURE, never a hard filter.
    ///
    /// ── PERCENTILE, NEVER MIN/MAX ────────────────────────────────────────────────────────────
    /// The window is p15–p85 of the members' years, padded ±2y. A deliberate era-outlier the
    /// owner filed stays in the collection and widens NOTHING: on the real catalog (source
    /// backup 2026-08-11, 81 pockets) the "🏋🏾‍♀️" pocket carries a member tagged year **1012** —
    /// an obvious tagging error — and still windows to 1999–2018, where min/max would have made
    /// its era a millennium wide.
    ///
    /// ── WHAT THE REAL POCKETS SAY (rec-features.json years, 99.2% coverage) ──────────────────
    ///     "Bad Bitch Radio"    35 members, all 2015–2026   → 2020–2027  (tight, modern)
    ///     "🏋🏾‍♀️"              500 members, outlier 1012    → 1999–2018  (percentile shrugs it off)
    ///     "808 and Swinging"   87 members, 1986–2025       → 1987–2024  (WIDE — and honestly so)
    /// The owner remembers "808 and Swinging" as ≈1988–1994 new jack swing. Its year data is
    /// verified correct song-by-song (Keith Sweat 1987, SWV 1992, Kodak Black 2023; 86/87 dated);
    /// the membership has simply grown past its founding core — a ~30-song 1986–1998 cluster plus
    /// two whole 2001/2003 albums and a modern R&B tail he added himself. A wide window is the
    /// truthful era of THAT membership: narrowing it to 88–94 would score the very songs he filed
    /// as misfits. The new-jack-swing SOUND is the genre term's job, not this one's.
    ///
    /// ── FAIL OPEN, BOTH DIRECTIONS ───────────────────────────────────────────────────────────
    /// An undated COLLECTION (no member year anywhere) produces no window: the era term drops at
    /// ROUND level and `termWeights` renormalizes the family weights over the live axes — an
    /// unearnable term must never sit in the denominator (the cloud's scoreForYou audio-term
    /// finding). An undated CANDIDATE against a live window is scored at the ROUND NEUTRAL — the
    /// measured mean era fit of the round's dated candidates — exactly the `MusicalCalibration`
    /// mechanism and for the same reason: zeroing it buries a song for a missing tag, while a
    /// per-song denominator would reward the missing tag. No shrinkage here, unlike the musical
    /// term: year coverage is 99.2%, not 10.4%, so there is no sparse-coverage winner's curse to
    /// correct.
    struct EraWindow: Equatable, Sendable {
        var lo: Double
        var hi: Double
        func contains(_ year: Double) -> Bool { year >= lo && year <= hi }
    }

    /// The percentile pair the window is cut at. p15–p85 keeps a 70% core and lets up to 15% of
    /// deliberate outliers on EACH side say nothing about the era.
    static let eraPercentileLow = 0.15
    static let eraPercentileHigh = 0.85
    /// Padding added outside the percentile cut, in years — the cut itself lands ON member years,
    /// and a candidate from the adjacent year is not outside the era in any musical sense.
    static let eraPaddingYears = 2.0
    /// e-folding distance of the fit OUTSIDE the window. At 4y a candidate 2 years out keeps 61%
    /// of the term, 8 years out 14%, and a 2020 track against a 1986–1996 window is at ~0.3% —
    /// buried on era while still fully able to win on genre/artist, which is what "a feature, not
    /// a filter" means.
    static let eraDecayYears = 4.0
    /// Fallback neutral for a round with too few dated candidates to measure one from. MEASURED:
    /// the mean era fit of the full dated catalog (106,879 songs) against the 81 real pocket
    /// windows is **0.758** (see the era fixtures in `SimilarityFamiliesTests`). High on purpose —
    /// most real windows are wide, so most of the catalog fits most eras; the tight-window rounds
    /// this constant would misrepresent are exactly the rounds with plenty of observations, which
    /// never reach it (year coverage 99.2% ⇒ the round mean is essentially always available).
    static let fallbackNeutralEraFit = 0.76

    /// The percentile window over a collection's member years, or nil for an undated collection.
    /// Nearest-rank percentile — deterministic, and identical to the Lambda's weighted
    /// `eraWindow` under uniform weights, which is what keeps cloud and device windows equal for
    /// the same membership.
    static func eraWindow(years: [Double]) -> EraWindow? {
        let ys = years.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !ys.isEmpty else { return nil }
        func rank(_ p: Double) -> Double {
            let idx = min(ys.count - 1, max(0, Int((p * Double(ys.count)).rounded(.up)) - 1))
            return ys[idx]
        }
        return EraWindow(lo: rank(eraPercentileLow) - eraPaddingYears,
                         hi: rank(eraPercentileHigh) + eraPaddingYears)
    }

    /// 0…1 era fit of one dated song: 1.0 anywhere inside the window (an era is a RANGE — 1989 is
    /// not "more 88–94" than 1993), decaying outside it.
    static func eraFit(year: Double, window w: EraWindow) -> Double {
        if w.contains(year) { return 1 }
        let gap = year < w.lo ? w.lo - year : year - w.hi
        return exp(-gap / eraDecayYears)
    }

    /// The round's imputation constant for undated candidates — same shape as
    /// `MusicalCalibration`, same round-level-never-per-song rule.
    struct EraCalibration: Sendable, Equatable {
        var neutral: Double = fallbackNeutralEraFit
        var observations: Int = 0
        var usedRoundMean: Bool { observations >= minObservationsForRoundNeutral }
    }

    /// Measure the round's era neutral from the candidate pool the ranking is about to read.
    static func eraCalibrate<S: Sequence>(_ candidateYears: S, window w: EraWindow)
        -> EraCalibration where S.Element == Double? {
        var sum = 0.0, n = 0
        for y in candidateYears {
            guard let y, y.isFinite, y > 0 else { continue }
            sum += eraFit(year: y, window: w)
            n += 1
        }
        var cal = EraCalibration(neutral: fallbackNeutralEraFit, observations: n)
        if n >= minObservationsForRoundNeutral { cal.neutral = sum / Double(n) }
        return cal
    }

    /// The era sub-term as the scorer sees it: the observed fit, or the round neutral when the
    /// candidate is undated. FAIL OPEN — an undated candidate is scored at the mean of its
    /// competitors, never at zero and never through a per-song denominator.
    static func eraFit(year: Double?, window w: EraWindow, calibration c: EraCalibration) -> Double {
        guard let year, year.isFinite, year > 0 else { return c.neutral }
        return eraFit(year: year, window: w)
    }

    // ========================================================================
    // MARK: - The tempo/key shape of a seed set
    // ========================================================================

    /// The weighted tempo + key DISTRIBUTION of the songs a round is being scored against.
    ///
    /// ── WHY A DISTRIBUTION AND NOT A MEAN + A SET ────────────────────────────────────────────
    /// The two shapes this replaces both SATURATE as the seed grows, and a saturated term is not a
    /// similarity signal any more — it is a constant with extra steps.
    ///
    ///  · Tempo was `mean ± sigma`. A seed of two dozen songs off a 96k library is MULTIMODAL —
    ///    85-bpm soul next to 140-bpm house — so its mean (112) matches neither of the tempos the
    ///    listener actually plays, while its sigma is wide enough that everything scores. A mean
    ///    cannot represent a bimodal listener at all; that is a property of the statistic, not a
    ///    tuning problem (`testTempoScoresTheDistributionNotItsMean` pins it).
    ///  · Key was SET MEMBERSHIP against every Camelot code in the seed — inherited from the
    ///    shipped ZoneEngine, so a real latent bug in it rather than something the rebalance
    ///    introduced. The defect is RESOLUTION, not level: set membership can only ever return one
    ///    of FOUR values (1.0 / 0.75 / 0.6 / 0) however large the seed is, so as the seed grows the
    ///    mass simply piles onto 1.0. Measured mean/sd of the affinity a random candidate gets,
    ///    with uniform member weights (the worst case for the replacement):
    ///
    ///        codes in seed     SET membership          DENSITY        distinct values
    ///              1           0.123 / sd 0.283     0.123 / 0.283        4  →  4
    ///              5           0.488 / sd 0.397     0.347 / 0.324        4  →  6.6
    ///             12           0.810 / sd 0.244     0.543 / 0.263        4  →  9.8
    ///
    /// Both become well-behaved as a DENSITY normalized by its own peak: "how well does this song
    /// sit in the region the seed actually occupies", relative to the best-fitting point. It keeps
    /// grading where set membership has run out of grades. And a seed that genuinely spans the
    /// whole wheel scores every key ALIKE — which is the truth (key carries no information there),
    /// and a flat term cannot distort a ranking, whereas one pinned at 1.0 for most candidates and
    /// 0 for the rest does.
    struct MusicalProfile: Sendable, Equatable {
        /// Weighted tempo modes, bucketed to whole bpm, heaviest first. Capped at `maxModes`
        /// because the tail of a play-weighted histogram is noise and every extra mode widens the
        /// density's support — i.e. costs exactly the selectivity this shape exists to recover.
        var tempoModes: [(bpm: Double, weight: Double)] = []
        /// Camelot code → summed member weight, uppercased ("8A").
        var camelotWeight: [String: Double] = [:]
        /// Peak of the tempo density, precomputed once per round (the normalizer).
        var tempoPeak: Double = 0
        /// Peak of the Camelot density over all 24 codes, precomputed once per round.
        var camelotPeak: Double = 0

        var isEmpty: Bool { tempoModes.isEmpty && camelotWeight.isEmpty }

        static func == (a: MusicalProfile, b: MusicalProfile) -> Bool {
            a.camelotWeight == b.camelotWeight
                && a.tempoPeak == b.tempoPeak && a.camelotPeak == b.camelotPeak
                && a.tempoModes.count == b.tempoModes.count
                && zip(a.tempoModes, b.tempoModes).allSatisfy { $0.bpm == $1.bpm && $0.weight == $1.weight }
        }
    }

    /// At most this many tempo modes. Twelve was measured to saturate; six keeps a genuinely
    /// bimodal listener (a slow half and a fast half) representable while leaving the density
    /// narrow enough to say no.
    static let maxTempoModes = 6

    /// Width of the tempo kernel in OCTAVES (log₂ bpm). At 0.10 a 7% tempo difference — roughly the
    /// range a DJ will pitch-bend into a mix — retains about 38% of the term, and a semitone-ish
    /// 12% difference about 21%. Log-domain rather than absolute bpm so the tolerance is the same
    /// musical interval at 70 bpm as at 170, instead of being over twice as strict at the bottom of
    /// the range (±8 bpm is a 11% move at 70 and a 5% one at 170).
    static let tempoSigmaOctaves = 0.10

    /// Strength of the 2:3 / 3:2 metrical relationships. 1:1 and half/double time are FULL
    /// strength — they are the same pulse counted differently, and the audio indexer's detector
    /// picks between them by heuristic, so the distinction is partly an artifact of analysis. The
    /// triplet pairs are real (a 90 over a 135 is a genuine mix) but a different feel, so they are
    /// discounted; at full strength they made almost every tempo a near-neighbour of every other.
    static let tripletStrength = 0.6

    /// Build the tempo/key shape from `(bpm, camelot, weight)` triples.
    static func musicalProfile(_ members: [(bpm: Double?, camelot: String?, weight: Double)])
        -> MusicalProfile {
        var p = MusicalProfile()
        var buckets: [Double: Double] = [:]
        for m in members {
            let w = max(0, m.weight)
            guard w > 0 else { continue }
            if let b = m.bpm, b > 0 { buckets[(b).rounded(), default: 0] += w }
            if let c = m.camelot?.trimmingCharacters(in: .whitespaces).uppercased(), !c.isEmpty {
                p.camelotWeight[c, default: 0] += w
            }
        }
        // Heaviest modes first; the bpm tiebreak keeps the profile deterministic across runs.
        p.tempoModes = buckets.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(maxTempoModes)
            .map { (bpm: $0.key, weight: $0.value) }
        // The peak of a density made of its own modes is always AT one of them, so this is exact
        // rather than a sampled approximation.
        p.tempoPeak = p.tempoModes.map { tempoDensity($0.bpm, p) }.max() ?? 0
        p.camelotPeak = allCamelotCodes.map { camelotDensity($0, p) }.max() ?? 0
        return p
    }

    /// The twelve hours of the wheel × major/minor.
    static let allCamelotCodes: [String] = (1...12).flatMap { ["\($0)A", "\($0)B"] }

    /// Musical relatedness of two Camelot codes — same code 1.0, relative major/minor 0.75, ±1
    /// around the twelve-hour face 0.6, anything else 0.
    ///
    /// Adjacency, never equality: exact-match on a key is nearly a no-op (24 codes, so a random
    /// pair matches 4% of the time) and it is also musically WRONG — 8A into 9A is the classic
    /// one-step move every DJ makes, and 8A into 8B is the same key's relative.
    static func camelotRelatedness(_ a: String, _ b: String) -> Double {
        guard let x = parseCamelot(a), let y = parseCamelot(b) else { return 0 }
        if x.n == y.n && x.letter == y.letter { return 1.0 }
        if x.n == y.n { return 0.75 }
        guard x.letter == y.letter else { return 0 }
        let up = x.n % 12 + 1, down = (x.n + 10) % 12 + 1
        return (y.n == up || y.n == down) ? 0.6 : 0
    }

    private static func parseCamelot(_ raw: String) -> (n: Int, letter: Character)? {
        let s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard let letter = s.last, letter == "A" || letter == "B",
              let n = Int(s.dropLast()), (1...12).contains(n) else { return nil }
        return (n, letter)
    }

    static func camelotDensity(_ code: String, _ p: MusicalProfile) -> Double {
        var sum = 0.0
        for (c, w) in p.camelotWeight { sum += w * camelotRelatedness(code, c) }
        return sum
    }

    /// 0…1 harmonic fit of one key to the profile's key distribution.
    static func camelotAffinity(_ code: String?, _ p: MusicalProfile) -> Double {
        guard let code, !code.isEmpty, !p.camelotWeight.isEmpty, p.camelotPeak > 0,
              parseCamelot(code) != nil else { return 0 }
        return min(1, camelotDensity(code, p) / p.camelotPeak)
    }

    static func tempoDensity(_ bpm: Double, _ p: MusicalProfile) -> Double {
        guard bpm > 0 else { return 0 }
        var sum = 0.0
        for m in p.tempoModes where m.bpm > 0 {
            sum += m.weight * exp(-abs(log2(bpm / m.bpm)) / tempoSigmaOctaves)
        }
        return sum
    }

    /// 0…1 tempo fit, THROUGH the metrical relationships a DJ actually mixes on: 1:1, half/double
    /// time, and the 2:3 / 3:2 pairs.
    ///
    /// Straight |bpm − mean| is the wrong distance for tempo. A 140-bpm track and a 70-bpm track
    /// are the SAME tempo counted differently — half-time is the single most common relationship
    /// in a hip-hop/R&B library, which is 45% of this one.
    static func bpmAffinity(_ bpm: Double?, _ p: MusicalProfile) -> Double {
        guard let bpm, bpm > 0, !p.tempoModes.isEmpty, p.tempoPeak > 0 else { return 0 }
        let related: [(bpm: Double, strength: Double)] = [
            (bpm, 1.0), (bpm / 2, 1.0), (bpm * 2, 1.0),
            (bpm * 2 / 3, tripletStrength), (bpm * 3 / 2, tripletStrength),
        ]
        var best = 0.0
        for r in related { best = max(best, r.strength * tempoDensity(r.bpm, p) / p.tempoPeak) }
        return min(1, best)
    }

    // ========================================================================
    // MARK: - The musical term, calibrated per round
    // ========================================================================

    /// Fallback neutral for a round whose candidate pool carries too few tempo/key observations to
    /// measure one from. MEASURED, not chosen: over 600,331 scorings of songs that can speak the
    /// term, against 60 random seed profiles on the real catalog, its median is 0.303 and its mean
    /// **0.344** (`scripts/measure-similarity-families.mjs --seeds 60`, section 7). The MEAN is
    /// the right constant here because the round-level neutral this stands in for is a mean.
    static let fallbackNeutralMusicalFit = 0.34

    /// Below this many observations the round mean is noise, so the measured global constant is
    /// used instead. 25 is the same order as the seed sizes this ranks against.
    static let minObservationsForRoundNeutral = 25

    /// Pseudo-observations of the prior in the shrinkage — see mechanism 3 in the type doc. Two
    /// rather than one because a song carries at most TWO real observations (a bpm and a key), so
    /// at `2` even a fully-analysed song sits half-way between its own evidence and the round's
    /// mean. Measured effect on the top-90's over-selection of analysed songs: **2.58× → 1.65×**
    /// against a 10.35% base rate (`--prior 0` vs `--prior 2`).
    static let musicalPrior = 2.0

    /// The round's imputation constant and the shrinkage that goes with it.
    struct MusicalCalibration: Sendable, Equatable {
        /// What a song with NEITHER bpm nor camelot scores on the musical term.
        var neutral: Double = fallbackNeutralMusicalFit
        /// How many candidates actually carried an observation (diagnostic; drives the fallback).
        var observations: Int = 0
        var usedRoundMean: Bool { observations >= minObservationsForRoundNeutral }
    }

    /// RAW musical fit — the mean of whichever of bpm / camelot BOTH sides can speak, together with
    /// how many of the two were observed. `nil` ⇒ this song can speak neither, and the caller
    /// substitutes the round neutral.
    static func rawMusicalFit(bpm: Double?, camelot: String?, profile p: MusicalProfile)
        -> (fit: Double, observations: Int)? {
        var terms: [Double] = []
        if !p.tempoModes.isEmpty, let bpm, bpm > 0 { terms.append(bpmAffinity(bpm, p)) }
        if !p.camelotWeight.isEmpty, let camelot, !camelot.isEmpty {
            terms.append(camelotAffinity(camelot, p))
        }
        guard !terms.isEmpty else { return nil }
        return (terms.reduce(0, +) / Double(terms.count), terms.count)
    }

    /// Measure the round's neutral from the candidate pool the ranking is about to read.
    ///
    /// ROUND-level and never per-song: it is one number computed once, then applied identically to
    /// every candidate, so it cannot reward an individual song for missing metadata. It exists
    /// because the realized mean of the musical term varies enormously with the seed — a seed
    /// whose keys span the wheel drives it up, a tight one drives it down — and imputing a global
    /// constant into either case biases the comparison between analysed and unanalysed songs.
    static func calibrate<S: Sequence>(_ candidates: S, profile p: MusicalProfile)
        -> MusicalCalibration where S.Element == (bpm: Double?, camelot: String?) {
        guard !p.isEmpty else { return MusicalCalibration() }
        var sum = 0.0, n = 0
        for c in candidates {
            guard let r = rawMusicalFit(bpm: c.bpm, camelot: c.camelot, profile: p) else { continue }
            sum += r.fit
            n += 1
        }
        var cal = MusicalCalibration(neutral: fallbackNeutralMusicalFit, observations: n)
        if n >= minObservationsForRoundNeutral { cal.neutral = sum / Double(n) }
        return cal
    }

    /// The musical sub-term as the scorer sees it: observed evidence SHRUNK toward the round's
    /// neutral, or the neutral itself when there is no evidence at all.
    static func musicalFit(bpm: Double?, camelot: String?, profile p: MusicalProfile,
                           calibration c: MusicalCalibration) -> Double {
        guard let r = rawMusicalFit(bpm: bpm, camelot: camelot, profile: p) else { return c.neutral }
        let n = Double(r.observations)
        return (musicalPrior * c.neutral + n * r.fit) / (musicalPrior + n)
    }

    // ========================================================================
    // MARK: - Reporting the families back out (tests + the "why" strings)
    // ========================================================================

    /// The three family scores for one candidate, 0…1 each, or nil for a family this profile
    /// cannot speak at all. Used by the tests that assert each family alone produces a materially
    /// different ranking, and by the row subtitle that explains WHY a song was suggested.
    struct Scores: Equatable, Sendable {
        var artist: Double?
        var genreYear: Double?
        var genreMusical: Double?

        /// The family with the strongest say, for a one-word "why".
        var leading: String? {
            let pairs: [(String, Double)] = [("artist", artist ?? -1),
                                             ("era", genreYear ?? -1),
                                             ("groove", genreMusical ?? -1)]
            guard let best = pairs.max(by: { $0.1 < $1.1 }), best.1 >= 0 else { return nil }
            return best.0
        }
    }

    static func scores(artistFit: Double?, genreFit: Double?, yearFit: Double?,
                       musicalFit: Double?) -> Scores {
        func mean(_ a: Double?, _ b: Double?) -> Double? {
            switch (a, b) {
            case let (x?, y?): return (x + y) / 2
            case let (x?, nil): return x
            case let (nil, y?): return y
            default: return nil
            }
        }
        return Scores(artist: artistFit,
                      genreYear: mean(genreFit, yearFit),
                      genreMusical: mean(genreFit, musicalFit))
    }
}
