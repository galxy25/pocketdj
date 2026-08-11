import Foundation

/// WHICH SONGS ARE WORTH LISTENING TO — the device half of targeted audio analysis.
///
/// ── WHY THIS EXISTS ──────────────────────────────────────────────────────────────────────────
/// Today a 👍 can only move METADATA signals. `RecFeedbackStore` projects a verdict onto the row's
/// ARTIST and its GENRE, and `ZoneEngine` / the Lambda score against artist, genre, year, bpm and
/// Camelot. So "I like this" collapses to "I like this artist" or "I like this genre" — the two
/// coarsest facts about a record. A listener who likes the sparse, dry, mid-tempo half of an
/// artist's catalog and dislikes the loud maximalist half has no way to say so, because both
/// halves carry the same artist and the same genre.
///
/// Audio features are the missing axis, and they are expensive: a librosa pass costs ~11 s of CPU
/// per song against a 107,757-row catalog — 330 CPU-hours to sweep it, and most of those rows will
/// never be recommended to anyone. So the analysis has to be TARGETED. Owner, verbatim: *"it
/// doesn't need to do audio analysis on the entire collection, only use v1 to get a list of
/// candidates, and then for whatever it thinks are the most novel and most similar to what i have
/// recently listened to (again restricting to only in-catalog items) run audio analysis on them"*.
///
/// This type is that selection, and it is deliberately a PURE FUNCTION over value types: it runs
/// on the same `Task.detached` hop as `ForYouFeedBuilder.build`, whose output it consumes, and it
/// has to be testable without a store, a network or a clock.
///
/// ── IN-CATALOG COMES FOR FREE, AND THAT IS WHY THE INPUT IS THE SNAPSHOT ─────────────────────
/// The candidates are the ids `ForYouFeedBuilder` just froze — In Da Zone plus every crate's
/// suggestion list. Those are drawn from `inputs.songs`, i.e. THIS DEVICE'S CATALOG, so the
/// "restrict to in-catalog items" rule is a property of the input rather than a filter that could
/// be forgotten. Nothing unowned can reach this list, which is what keeps the nightly job bounded
/// and is why the 13-day bulk-rip problem does not apply.
///
/// ── BOTH CRITERIA, STRICTLY ALTERNATING ─────────────────────────────────────────────────────
/// Novel-only analyses noise: the most novel rows in a 107k catalog are the ones with the least
/// evidence behind them, and spending a night of CPU on records the ranker admitted at the bottom
/// of the pool teaches the model about songs he will never be offered. Similar-only analyses what
/// he already knows: rows near the centre of recent listening are the ones the metadata signals
/// already rank correctly, so a feature vector there changes nothing.
///
/// So `select` interleaves them — novel, similar, novel, similar — rather than taking a fixed
/// half of each. Interleaving is what makes the guarantee hold when one side runs short: with a
/// 50/50 split, a night where only three rows are eligible on the novel side ships a shortlist
/// that is 94% similar and calls it balanced. Alternating degrades to "whatever the other side
/// has left" only after the short side is exhausted, and the boundary is visible in the order.
enum RecAudioShortlist {

    // ========================================================================
    // MARK: - Inputs
    // ========================================================================

    /// One row of v1's answer, reduced to what the two criteria actually read.
    struct Candidate: Equatable, Sendable {
        var songId: String
        /// `RecNovelty.primaryArtistKey(credit)` — the same bucket the per-artist caps use, so
        /// "Drake & Future" cannot walk around Drake's budget here either.
        var artistKey: String
        var genre: String?
        var bpm: Double?
        var camelot: String?

        init(songId: String, artistKey: String, genre: String? = nil,
             bpm: Double? = nil, camelot: String? = nil) {
            self.songId = songId
            self.artistKey = artistKey
            self.genre = genre
            self.bpm = bpm
            self.camelot = camelot
        }
    }

    /// The centre of gravity of RECENT listening, as value types.
    ///
    /// A CENTROID and not a nearest-neighbour sweep: "similar to what I have recently listened to"
    /// over a 200-row candidate list against a 30-day play window is 200 × N comparisons on the
    /// refresh path, and the answer barely differs — recent listening on this profile is
    /// concentrated enough (two genres are ~68% of all plays) that the centroid and the maximum
    /// pick nearly the same rows. Cheap and explicable beats exact here.
    struct RecentProfile: Equatable, Sendable {
        /// Genre category → share of recent plays, summing to ≤ 1.
        var genreShare: [String: Double] = [:]
        /// Mean tempo of recent plays that HAVE one. `nil` ⇒ this axis is dead (see `similarity`).
        var meanBpm: Double?
        /// Camelot codes seen in recent listening. Empty ⇒ dead axis.
        var camelotCodes: Set<String> = []

        init(genreShare: [String: Double] = [:], meanBpm: Double? = nil,
             camelotCodes: Set<String> = []) {
            self.genreShare = genreShare
            self.meanBpm = meanBpm
            self.camelotCodes = camelotCodes
        }

        /// Fold a recent-play window into a profile. Rows with no genre/tempo/key simply do not
        /// vote on that axis — they are not zeroed, which would drag every mean toward nothing.
        init(recent: [Candidate]) {
            var counts: [String: Double] = [:]
            var genreVotes = 0.0
            var bpmSum = 0.0
            var bpmVotes = 0.0
            var codes = Set<String>()
            for r in recent {
                if let g = r.genre, !g.isEmpty { counts[g, default: 0] += 1; genreVotes += 1 }
                if let b = r.bpm, b > 0 { bpmSum += b; bpmVotes += 1 }
                if let c = r.camelot, !c.isEmpty { codes.insert(c.uppercased()) }
            }
            if genreVotes > 0 { for (k, v) in counts { counts[k] = v / genreVotes } }
            genreShare = genreVotes > 0 ? counts : [:]
            meanBpm = bpmVotes > 0 ? bpmSum / bpmVotes : nil
            camelotCodes = codes
        }

        var isLive: Bool { !genreShare.isEmpty || meanBpm != nil || !camelotCodes.isEmpty }
    }

    struct Inputs: Sendable {
        /// v1's candidates, BEST FIRST. Order is not used as a score — it is the tiebreak, so the
        /// shortlist is deterministic for a fixed input and a test can pin it.
        var candidates: [Candidate] = []
        /// Songs that already carry a timbre vector AT THE CURRENT VERSION. Skipping them is what
        /// makes successive nights cumulative instead of repeating the same work — and, on a
        /// catalog where 10.6% of rows already have bpm/key, it is also why a corpus that looks
        /// hopeless at 107,757 rows is reachable at 40 rows a night.
        var analysedIds: Set<String> = []
        /// Ids already queued and not yet analysed. The queue is server-side and drains over
        /// several nights, so re-sending them would re-rank a list the worker is already holding.
        var pendingIds: Set<String> = []
        var recent = RecentProfile()
        var familiarity = RecNovelty.ArtistFamiliarity()
        /// How many songs one night may be asked to analyse. See `perNight` for the arithmetic.
        var perNight: Int = defaultPerNight
        /// Per-artist ceiling inside ONE shortlist, mirroring the 3-per-artist cap the tiles use.
        var perArtistCap: Int = 3

        init() {}
    }

    // ========================================================================
    // MARK: - Tuning
    // ========================================================================

    /// THE NIGHT'S BUDGET, derived rather than picked.
    ///
    /// The window is 02:00–06:00 (four hours, the established `am-sync-nightly` /
    /// `digital-sync-nightly` slot). A timbre pass measured on this machine costs ~11 s of CPU
    /// plus ~2 s to pull the mp3 from S3, and the job runs the analyses back to back, so a night
    /// could physically clear ~1,100 songs that ALREADY HAVE LOCAL AUDIO.
    ///
    /// It is not analysis that bounds the night — it is the rip. Only 1,939 of the 107,757
    /// catalog rows have a local capture today (1.8%), so almost every shortlist row has to be
    /// captured from Apple Music first, and that is REAL TIME: a 4-minute song takes 4 minutes.
    /// Four hours of real-time capture is ~50 songs, and a rip queue that is still draining at
    /// 06:00 has to be cut off mid-song. 40 leaves headroom for the tail of a long track and for
    /// the analysis passes interleaved with it, which is the difference between "stops cleanly"
    /// and "stops cleanly most nights".
    static let defaultPerNight = 40

    /// Weight of the genre term inside the similarity score. Highest of the three because it is
    /// the only one with real coverage: 89.0% of the catalog carries a genre category against
    /// 10.6% for bpm and Camelot.
    ///
    /// THAT IMBALANCE IS THE ARGUMENT FOR THIS WHOLE FEATURE, so it is worth stating plainly here
    /// rather than burying it in a commit message: for ~89% of candidates "similar to what I have
    /// recently listened to" currently means "same genre category", one of fourteen buckets. A
    /// timbre vector is the first axis that would be defined for every row the job analyses.
    static let genreWeight = 0.5
    static let bpmWeight = 0.3
    static let keyWeight = 0.2
    /// Tempo distance, in BPM, at which the tempo term reaches zero. A fifth of a typical tempo —
    /// wide enough that a half-time/double-time neighbour is not scored as identical, narrow
    /// enough that 92 and 128 are not called similar.
    static let bpmTolerance = 24.0

    // ========================================================================
    // MARK: - Scoring
    // ========================================================================

    /// 0…1. How close this candidate sits to the centre of recent listening.
    ///
    /// RENORMALIZED over the axes that are LIVE, the same doctrine `RecNovelty.aux` and
    /// `SimilarityFamilies.termWeights` follow: a device with no tempo data anywhere must not
    /// score every candidate a uniformly deflated 0.5 × genre, because a constant factor across
    /// every row is not a signal — it is a rescaling that makes the number unreadable next to
    /// novelty. A dead profile (no recent listening at all) scores 0 for everyone, which lets the
    /// caller fall back to novelty alone rather than to noise.
    static func similarity(_ c: Candidate, _ p: RecentProfile) -> Double {
        var sum = 0.0
        var den = 0.0
        if !p.genreShare.isEmpty {
            den += genreWeight
            if let g = c.genre, let share = p.genreShare[g] {
                // Share is ≤ 1 but usually small (a 14-bucket distribution), so it is read
                // RELATIVE TO THE TOP genre rather than absolutely — otherwise the term would sit
                // near 0.2 for the listener's favourite genre and the axis would never speak.
                let top = p.genreShare.values.max() ?? 1
                sum += genreWeight * (top > 0 ? min(1, share / top) : 0)
            }
        }
        if let mean = p.meanBpm, mean > 0 {
            den += bpmWeight
            if let b = c.bpm, b > 0 {
                sum += bpmWeight * max(0, 1 - abs(b - mean) / bpmTolerance)
            }
        }
        if !p.camelotCodes.isEmpty {
            den += keyWeight
            if let code = c.camelot?.uppercased(), !code.isEmpty {
                if p.camelotCodes.contains(code) {
                    sum += keyWeight
                } else if p.camelotCodes.contains(where: { camelotAdjacent(code, $0) }) {
                    // A harmonic neighbour is most of a match, not none of one — the same
                    // relationship the mix decks call compatible.
                    sum += keyWeight * 0.6
                }
            }
        }
        guard den > 0 else { return 0 }
        return sum / den
    }

    /// Camelot adjacency: same number ± mode, or ±1 on the wheel in the same mode.
    static func camelotAdjacent(_ a: String, _ b: String) -> Bool {
        guard let x = parseCamelot(a), let y = parseCamelot(b) else { return false }
        if x.n == y.n && x.mode != y.mode { return true }
        guard x.mode == y.mode else { return false }
        let d = abs(x.n - y.n)
        return d == 1 || d == 11
    }

    private static func parseCamelot(_ s: String) -> (n: Int, mode: Character)? {
        let t = s.trimmingCharacters(in: .whitespaces).uppercased()
        guard let mode = t.last, mode == "A" || mode == "B" else { return nil }
        guard let n = Int(t.dropLast()), (1...12).contains(n) else { return nil }
        return (n, mode)
    }

    // ========================================================================
    // MARK: - Selection
    // ========================================================================

    /// The night's shortlist — ids only, best-first, bounded, deterministic.
    ///
    /// IDS ONLY is the contract, not an optimisation: the server's copy of this exists so the
    /// worker knows WHICH FILES to open, and it has the metadata already. Sending anything more
    /// would widen what leaves the device for no gain.
    static func select(_ inputs: Inputs) -> [String] {
        guard inputs.perNight > 0 else { return [] }
        let eligible = inputs.candidates.filter {
            !inputs.analysedIds.contains($0.songId) && !inputs.pendingIds.contains($0.songId)
        }
        guard !eligible.isEmpty else { return [] }

        // Rank ONCE per axis. `enumerated` supplies v1's own order as the tiebreak, which is what
        // makes the output a function of the input rather than of the sort's stability.
        let indexed = Array(eligible.enumerated())
        let byNovelty = indexed
            .sorted { a, b in
                let na = inputs.familiarity.novelty(a.element.artistKey)
                let nb = inputs.familiarity.novelty(b.element.artistKey)
                return na == nb ? a.offset < b.offset : na > nb
            }
            .map(\.element)
        let bySimilarity = indexed
            .sorted { a, b in
                let sa = similarity(a.element, inputs.recent)
                let sb = similarity(b.element, inputs.recent)
                return sa == sb ? a.offset < b.offset : sa > sb
            }
            .map(\.element)

        var picked: [String] = []
        var taken = Set<String>()
        var perArtist: [String: Int] = [:]
        var i = 0
        var j = 0
        var wantNovel = true

        // Advance ONE list past everything already taken or capped, and take its head.
        func take(_ list: [Candidate], _ cursor: inout Int) -> Bool {
            while cursor < list.count {
                let c = list[cursor]
                cursor += 1
                if taken.contains(c.songId) { continue }
                if (perArtist[c.artistKey] ?? 0) >= inputs.perArtistCap { continue }
                taken.insert(c.songId)
                perArtist[c.artistKey, default: 0] += 1
                picked.append(c.songId)
                return true
            }
            return false
        }

        while picked.count < inputs.perNight {
            let tookOne = wantNovel ? take(byNovelty, &i) : take(bySimilarity, &j)
            if !tookOne {
                // This side is exhausted; let the other one finish the night alone. When BOTH are
                // exhausted the shortlist is simply shorter than the budget, which is correct —
                // padding it would mean re-queueing rows the cap already refused.
                let otherTook = wantNovel ? take(bySimilarity, &j) : take(byNovelty, &i)
                if !otherTook { break }
            }
            wantNovel.toggle()
        }
        return picked
    }
}
