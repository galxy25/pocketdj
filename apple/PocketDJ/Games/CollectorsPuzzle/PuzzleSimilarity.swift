import Foundation

/// LOCAL-FIRST similarity for Gem Collector: "when targets ARE selected, show me songs LIKE
/// those collections" (Levi 2026-08). Pure — no stores, no main actor, same doctrine as
/// `PuzzleSampler`, which builds the profile off the main actor and calls `shortlist` from
/// inside its existing playable-first `pool()`.
///
/// WHY LOCAL-FIRST AND NOT THE CLOUD ENGINE. `RecommendationService.isEnabled` is the
/// Settings toggle, which DEFAULTS OFF, and every network method guards it first ("toggle-off
/// means literally zero calls"). A design that routes a round's queue through the Lambda
/// therefore ships a feature that does nothing for almost everybody, and hangs a TIMED game on
/// a network for the rest. So: the six signals below run entirely on device, and the cloud —
/// when it is on, reachable, and deployed — contributes a RANK BONUS only (see `cloudWeight`).
/// With the cloud off the composition is a uniform scale, so the local ORDER is identical.
///
/// THE SIX SIGNALS ARE THE ONES THE USER NAMED — artist, genre, lyrical content, year,
/// membership in other collections, and the playback-history graph — weighted by how much each
/// one can actually say. Measured coverage over the real 107,755-song catalog: artist 100%,
/// year 99.2%, genre 89.0%, `sentimentKeywords` (the on-device lyrical proxy) 11.6% and almost
/// entirely inside the vinyl index (`current-index.json` 12,523/12,525; `apple-music-index.json`
/// 0/96,020). Full lyrics text is fetched ON DEMAND, one song at a time, when a detail screen
/// opens (`LyricsStore`) — there is no bulk on-device corpus to mine, and building one would be
/// ~9k HTTP GETs. So the lyrical term is honestly weighted as a TIEBREAKER, and it drops out of
/// the denominator entirely when the target profile carries no keywords at all.
enum PuzzleSimilarity {

    // MARK: - Term weights
    //
    // These are RATIOS, not a partition: `score` divides by `availableWeight` (the sum of the
    // terms the profile can actually speak), so only their relative sizes matter. They summed to
    // 1.0 when there were six; the seventh does not have to be carved out of the others, and
    // rebalancing them to keep the total at 1.0 would perturb shipped ranking for no numerical
    // gain whatsoever.

    /// 100% coverage and the signal a human names first ("more stuff like this").
    static let wArtist = 0.30
    /// 89% coverage, and the pre-existing `genreCategories` filter proves the user already
    /// thinks in these buckets.
    static let wGenre = 0.25
    /// 99% coverage but a weak discriminator alone (a 1994 hip-hop record and a 1994 country
    /// record are not similar), so it modulates rather than drives.
    static let wYear = 0.15
    /// Sparse but high signal-to-noise: the user PERSONALLY put those two songs in one crate.
    static let wCoMember = 0.12
    /// Honest about 11.6% coverage — a tiebreaker inside the vinyl catalog, never a driver.
    static let wLyrics = 0.10
    /// The noisiest of the six (shuffle, a party, an album played straight through all create
    /// spurious adjacency), so it is the smallest.
    static let wCoPlay = 0.08
    /// Relative sizes of the four CONTEXT terms inside `familyScore`'s residual family. They are
    /// the four weights above, reused verbatim rather than re-tuned, so the residual keeps the
    /// same internal proportions the flat scorer gives them.
    static let contextWeights = (coMember: wCoMember, lyrics: wLyrics,
                                 coPlay: wCoPlay, recency: wRecency)
    /// How recently the CANDIDATE itself was played. The smallest term of the seven — a sixth of
    /// `wArtist`, below even `wCoPlay` — for three reasons: it says nothing about the TARGETS (it
    /// is a property of the candidate alone, unlike every other term here), it has ~58% coverage,
    /// and the median dated song only scores 0.134. It is a gradient tiebreak between songs the
    /// other six already rank alike, and at 0.05 of a ~1.0 denominator it can never lift a
    /// non-matching artist above a matching one.
    ///
    /// NOTE there is deliberately NO play-count term here. Lifetime plays already reach this
    /// ranker multiplicatively, through `PuzzleSampler.pool`'s bias weight, which `shortlist`
    /// preserves — adding one would double-count it, and worse, it would fire even when the user
    /// set `playCountBias = .avoid`, so the two would actively fight each other.
    static let wRecency = 0.05

    /// How far toward 1.0 a top-ranked CLOUD hit may lift a song. A pure bonus — see `score`.
    static let cloudWeight = 0.25

    /// Two plays this far apart count as "played together" (the co-play graph edge).
    static let coPlayWindowMs: Double = 30 * 60 * 1000
    /// Co-play saturation: 3 shared listening sessions is already a full-strength edge.
    static let coPlaySaturation = 3.0
    /// `.strict` drops everything below this before the top-K (then the starvation guard runs).
    static let strictFloor = 0.15

    // MARK: - The profile

    /// What the union of the target collections LOOKS like. Built once per sample, off the
    /// main actor, and reused by the mid-round top-up so the round's character can't drift at
    /// song 51.
    struct TargetProfile: Equatable {
        /// normalized artist → share of target members carrying it.
        var artistShare: [String: Double] = [:]
        var maxArtistShare: Double = 0
        /// `Genre.category` → share of target members.
        var genreShare: [String: Double] = [:]
        var maxGenreShare: Double = 0
        var yearMean: Double?
        /// Spread of the members' years. Floored at 8 when scoring: a tight era must not make
        /// everything outside it score exactly 0.
        var yearSigma: Double = 8
        /// Weighted mean BPM of the members that carry one — the tempo half of the owner's
        /// "genre and bpm & key" family. nil when NO member on this device has a bpm, which is
        /// exactly the ROUND-level signal `familyScore` uses to drop the term (never a per-song
        /// renormalization — see `availableWeight`).
        var bpmMean: Double?
        /// Floored at 8 when scoring for the same reason `yearSigma` is: a set of members all at
        /// one tempo must not make every other tempo score exactly zero.
        var bpmSigma: Double = 8
        /// Camelot codes present among the members, uppercased (e.g. "8A"). Empty ⇒ the key term
        /// is not in `familyScore`'s denominator at all.
        var camelots: Set<String> = []
        /// Does this DEVICE know any last-played dates? Stored (not just folded into
        /// `availableWeight`) because `familyScore` needs the same round-level answer to decide
        /// whether the recency term is in the CONTEXT family's denominator.
        var hasRecency = false
        /// lowercased keyword → share of the KEYWORD-BEARING target members carrying it
        /// (top 20 only — the tail is noise).
        var keywordShare: [String: Double] = [:]
        var maxKeywordShare: Double = 0
        /// Songs sharing a NON-target collection with at least one target member.
        var coMemberIds: Set<String> = []
        /// songId → DECAYED strength of the co-play edge: each play inside `coPlayWindowMs` of a
        /// play of a target member contributes `PlayRecency.decay` of its own age, not a flat 1.
        ///
        /// It was a flat count, which made a co-play from 2018 worth exactly as much as one from
        /// last week — on a library whose median play is 5.8 years old that is most of the edges,
        /// so the term described listening habits the user has since abandoned. Decaying at the
        /// same half-life as every other recency use keeps "often played together" meaning
        /// "played together LATELY".
        var coPlayWeight: [String: Double] = [:]
        /// The target members themselves (already filed — they score 0 on membership, and the
        /// sampler's own "already in EVERY target" filter drops the fully-filed ones).
        var memberIds: Set<String> = []

        /// The DENOMINATOR — the sum of the weights of the terms this PROFILE can speak at all.
        ///
        /// Profile-level, never per-song, deliberately. A per-song denominator rewards songs
        /// with MISSING metadata (fewer terms = higher average) — the classic sparse-feature
        /// bug, and with an 11.6%-covered lyrics field it would have been severe. Profile-level
        /// keeps every song in one round comparable, which is all that matters: the score is
        /// only ever used to rank WITHIN one pool.
        var availableWeight: Double = 0
        /// No targets, or targets that resolved to nothing on this device ⇒ similarity is a
        /// no-op and the pool is exactly what it is today.
        var isEmpty: Bool { availableWeight <= 0 }
    }

    /// Normalized artist key: diacritic + case insensitive, trimmed, leading "the " stripped.
    /// Deliberately NOT `FuzzyMatch` — that is a UI ranker over short lists, not a 100k-row
    /// hot loop.
    static func artistKey(_ artist: String) -> String {
        var s = artist.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("the ") { s.removeFirst(4) }
        return s
    }

    /// Build the profile from the target collections' members.
    ///
    /// - Parameters:
    ///   - targetMemberIds: member ids of EACH target collection (the union is the profile).
    ///   - songsById: catalog lookup for the members' rows.
    ///   - genreBySongId: the sampler's existing song → `Genre.category` map.
    ///   - otherCollections: every OTHER collection's membership (the "shared crate" signal).
    ///   - plays: the play log, oldest-or-newest order irrelevant (sorted here).
    ///   - hasRecency: does this DEVICE know any last-played dates at all? ROUND-level, never
    ///     per-song: it decides whether `wRecency` is in the denominator, so on a device with no
    ///     baseline the term vanishes entirely instead of scoring every song a flat zero (which
    ///     would deflate every score by 5% uniformly — harmless to the order, but it would make
    ///     `.strict`'s absolute 0.15 floor quietly stricter than it reads).
    ///   - memberWeights: OPTIONAL per-member weight. `nil` (the default, and what Gem Collector
    ///     passes) means every member counts 1 — byte-identical to the behaviour this function
    ///     shipped with, which is why the puzzle's pinned tests are untouched by this parameter.
    ///
    ///     It exists because In Da Zone builds its profile from PLAY EVENTS rather than from a
    ///     collection's membership, and a play log is not a set: a song played nine times this
    ///     week and one played once last month are not equal evidence of taste. The zone passes
    ///     each seed's recency-decayed play weight here, so "what you have been bumping" is
    ///     literally weighted by how much you have been bumping it. A collection genuinely IS a
    ///     set — that is why the default stays uniform rather than being switched over.
    ///   - nowMs: "now" for the co-play edge decay; injected so tests are deterministic.
    static func profile(targetMemberIds: [[String]],
                        songsById: [String: IndexSong],
                        genreBySongId: [String: String],
                        otherCollections: [[String]],
                        plays: [(songId: String, atMs: Double)],
                        hasRecency: Bool = false,
                        memberWeights: [String: Double]? = nil,
                        nowMs: Double = Date().timeIntervalSince1970 * 1000) -> TargetProfile {
        var p = TargetProfile()
        var members = Set<String>()
        for ids in targetMemberIds { members.formUnion(ids) }
        guard !members.isEmpty else { return p }
        p.memberIds = members

        var artistCount: [String: Double] = [:]
        var genreCount: [String: Double] = [:]
        // (year, weight) rather than a bare year, so the mean/sigma below can be weighted too —
        // with uniform weights the formulas reduce exactly to the unweighted ones.
        var years: [(y: Double, w: Double)] = []
        var bpms: [(v: Double, w: Double)] = []
        var keywordCount: [String: Double] = [:]
        var keywordBearers = 0.0
        var resolved = 0.0

        for id in members {
            guard let song = songsById[id] else { continue }
            // A weight of 0 (or a negative one from a corrupt caller) would contribute nothing but
            // could still divide by zero downstream, so it is floored rather than trusted.
            let w = max(0, memberWeights?[id] ?? 1)
            guard w > 0 else { continue }
            resolved += w
            artistCount[artistKey(song.artist), default: 0] += w
            if let cat = genreBySongId[id] { genreCount[cat, default: 0] += w }
            if let y = song.year { years.append((Double(y), w)) }
            // Tempo/key ride the SAME weighted pass as everything else, so an In Da Zone profile's
            // heavier seeds shape the tempo shape too. Collected unconditionally: they only ever
            // reach a score through `familyScore`, and `score` (Gem Collector) never reads them —
            // which is what keeps the shipped puzzle ranking bit-identical.
            if let b = song.bpm, b > 0 { bpms.append((b, w)) }
            if let c = song.camelot?.uppercased(), !c.isEmpty { p.camelots.insert(c) }
            let kws = (song.sentimentKeywords ?? []).map { $0.lowercased() }
            if !kws.isEmpty {
                keywordBearers += w
                for k in Set(kws) { keywordCount[k, default: 0] += w }
            }
        }
        // Not one target member resolves against this device's catalog (a collection full of
        // songs from a source that isn't loaded) ⇒ no profile, no re-ranking. (`camelots` is
        // cleared on the way out: a weight-0 member could have seeded it, and a profile that is
        // `isEmpty` must carry no shape at all.)
        guard resolved > 0 else { p.camelots = []; return p }

        p.artistShare = artistCount.mapValues { $0 / resolved }
        p.maxArtistShare = p.artistShare.values.max() ?? 0
        p.genreShare = genreCount.mapValues { $0 / resolved }
        p.maxGenreShare = p.genreShare.values.max() ?? 0
        if !years.isEmpty {
            let wSum = years.reduce(0) { $0 + $1.w }
            let mean = years.reduce(0) { $0 + $1.y * $1.w } / wSum
            p.yearMean = mean
            let variance = years.reduce(0) { $0 + $1.w * ($1.y - mean) * ($1.y - mean) } / wSum
            p.yearSigma = max(8, variance.squareRoot())
        }
        if !bpms.isEmpty {
            let wSum = bpms.reduce(0) { $0 + $1.w }
            let mean = bpms.reduce(0) { $0 + $1.v * $1.w } / wSum
            p.bpmMean = mean
            let variance = bpms.reduce(0) { $0 + $1.w * ($1.v - mean) * ($1.v - mean) } / wSum
            p.bpmSigma = max(8, variance.squareRoot())
        }
        p.hasRecency = hasRecency
        if keywordBearers > 0 {
            let shares = keywordCount.mapValues { $0 / keywordBearers }
            // Top 20 only — a long keyword tail dilutes the term into noise.
            p.keywordShare = Dictionary(uniqueKeysWithValues:
                shares.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(20).map { ($0.key, $0.value) })
            p.maxKeywordShare = p.keywordShare.values.max() ?? 0
        }

        // Co-membership: any collection that is NOT one of the targets and that holds at least
        // one target member contributes its OTHER songs.
        let targetSets = targetMemberIds.map(Set.init)
        for ids in otherCollections {
            let set = Set(ids)
            // Skip the target collections themselves (matched by exact membership, since the
            // snapshot is id-free).
            if targetSets.contains(where: { $0 == set }) { continue }
            guard set.contains(where: { members.contains($0) }) else { continue }
            p.coMemberIds.formUnion(set.subtracting(members))
        }

        // Co-play: songs played inside `coPlayWindowMs` of a play of a target member. Built by
        // ONE sorted pass + binary search per event — O(E log M), never O(E²).
        let memberPlayTimes = plays.filter { members.contains($0.songId) }.map(\.atMs).sorted()
        if !memberPlayTimes.isEmpty {
            for e in plays where !members.contains(e.songId) {
                if nearestDistance(e.atMs, in: memberPlayTimes) <= coPlayWindowMs {
                    // The EVENT's own age, so an old listening session fades while a recent one
                    // stays full strength. Floored at 0 by `decay`; a future stamp clamps to 1.
                    p.coPlayWeight[e.songId, default: 0] += PlayRecency.decay(
                        ageDays: (nowMs - e.atMs) / 86_400_000)
                }
            }
        }

        var w = 0.0
        if !p.artistShare.isEmpty { w += wArtist }
        if !p.genreShare.isEmpty { w += wGenre }
        if p.yearMean != nil { w += wYear }
        if !p.keywordShare.isEmpty { w += wLyrics }
        if !p.coMemberIds.isEmpty { w += wCoMember }
        if !p.coPlayWeight.isEmpty { w += wCoPlay }
        if hasRecency { w += wRecency }
        p.availableWeight = w
        return p
    }

    /// Distance from `t` to the closest value in a SORTED array.
    private static func nearestDistance(_ t: Double, in sorted: [Double]) -> Double {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        var best = Double.greatestFiniteMagnitude
        if lo < sorted.count { best = min(best, abs(sorted[lo] - t)) }
        if lo > 0 { best = min(best, abs(t - sorted[lo - 1])) }
        return best
    }

    // MARK: - Term primitives
    //
    // Each returns its own 0…1 value with NO weight applied, so the flat scorer below and the
    // family blend further down share one definition per signal instead of two that can drift.
    // `score` multiplies each by exactly the constant it always did, under exactly the same
    // guard, so extracting them is bit-identical — which is what keeps Gem Collector's shipped
    // ranking (and the tests pinning it) untouched.

    static func artistTerm(_ key: String, _ p: TargetProfile) -> Double {
        let share = p.artistShare[key] ?? 0
        return min(1, share / max(0.05, p.maxArtistShare))
    }

    static func genreTerm(_ genre: String?, _ p: TargetProfile) -> Double {
        guard p.maxGenreShare > 0 else { return 0 }
        let share = genre.flatMap { p.genreShare[$0] } ?? 0
        return min(1, share / p.maxGenreShare)
    }

    static func yearTerm(_ year: Int?, _ p: TargetProfile) -> Double {
        guard let mean = p.yearMean, let year else { return 0 }
        return exp(-abs(Double(year) - mean) / max(8, p.yearSigma))
    }

    /// Tempo fit. Exponential in ABSOLUTE bpm distance (not squared), matching `yearTerm` — the
    /// two are the same "how far from the middle of what you like" shape, and a shared shape is
    /// what makes the era and sonic families numerically comparable.
    static func bpmTerm(_ bpm: Double?, _ p: TargetProfile) -> Double {
        guard let mean = p.bpmMean, let bpm, bpm > 0 else { return 0 }
        return exp(-abs(bpm - mean) / max(6, p.bpmSigma))
    }

    /// Harmonic fit on the Camelot wheel — `ZoneEngine.camelotAffinity` is the one definition
    /// (same code 1.0, relative major/minor 0.75, ±1 around the face 0.6, anything else 0).
    static func camelotTerm(_ camelot: String?, _ p: TargetProfile) -> Double {
        ZoneEngine.camelotAffinity(camelot, to: p.camelots)
    }

    static func keywordTerm(_ keywords: [String]?, _ p: TargetProfile) -> Double {
        guard p.maxKeywordShare > 0 else { return 0 }
        let hits = Set((keywords ?? []).map { $0.lowercased() }).compactMap { p.keywordShare[$0] }
        guard !hits.isEmpty else { return 0 }
        return min(1, hits.reduce(0, +) / p.maxKeywordShare)
    }

    static func coPlayTerm(_ songId: String, _ p: TargetProfile) -> Double {
        let n = p.coPlayWeight[songId] ?? 0
        guard n > 0 else { return 0 }
        return min(1, n / coPlaySaturation)
    }

    // MARK: - Scoring

    /// 0…1 similarity of one song to the profile. `cloudRank` is 0 for everything the cloud
    /// did not name (or when the cloud is off, which is the DEFAULT — see the type doc).
    /// `recency` is this song's 0…1 `PlayRecency` score, already computed by the caller (0 when
    /// the device has no dates, which pairs with `hasRecency: false` dropping the term from the
    /// denominator — so the result is then EXACTLY the six-term score, unscaled).
    ///
    /// THE FLAT SCORER — Gem Collector's, and deliberately frozen. The rec surfaces use
    /// `familyScore` instead; see its doc for why the two coexist rather than one replacing the
    /// other.
    static func score(_ song: IndexSong, profile p: TargetProfile,
                      genre: String?, cloudRank: Double = 0,
                      recency: Double = 0) -> Double {
        var local = 0.0
        if !p.artistShare.isEmpty {
            local += wArtist * artistTerm(artistKey(song.artist), p)
        }
        if !p.genreShare.isEmpty, p.maxGenreShare > 0 {
            local += wGenre * genreTerm(genre, p)
        }
        if p.yearMean != nil, song.year != nil {
            local += wYear * yearTerm(song.year, p)
        }
        if !p.keywordShare.isEmpty, p.maxKeywordShare > 0 {
            local += wLyrics * keywordTerm(song.sentimentKeywords, p)
        }
        if !p.coMemberIds.isEmpty, p.coMemberIds.contains(song.id) { local += wCoMember }
        if !p.coPlayWeight.isEmpty {
            local += wCoPlay * coPlayTerm(song.id, p)
        }
        if recency > 0 { local += wRecency * min(1, recency) }
        let normalized = min(1, max(0, p.availableWeight > 0 ? local / p.availableWeight : 0))
        // The cloud is a pure BONUS: it lifts a song a fraction of the way to 1, so it can only
        // ever RAISE a score, never zero one out, never hard-filter — and with `cloudRank == 0`
        // (the default, since the engine is off by default) the result is EXACTLY the local
        // score. That literal identity is what makes the app safe to ship before the route is
        // deployed: turning the cloud off changes nothing at all, not even the scale.
        guard cloudRank > 0 else { return normalized }
        return min(1, normalized + cloudWeight * min(1, cloudRank) * (1 - normalized))
    }

    // ========================================================================
    // MARK: - The THREE-FAMILY blend (the recommendation surfaces' scorer)
    // ========================================================================

    /// One candidate, flattened — so the blend can score an `IndexSong` (In Da Zone) and a
    /// `ZoneEngine.Track` (collection suggestions) through ONE function instead of two rankers
    /// that quietly disagree.
    struct Candidate: Equatable, Sendable {
        var songId: String
        /// Already normalized through `artistKey` / `IndexArtist.normalize` by the caller.
        var artistKey: String
        /// `Genre.category`, and nil for the catch-all bucket. CANONICAL BY CONSTRUCTION: the
        /// category matcher folds "Hip-Hop/Rap", "Hip Hop/Rap" and "Hip-Hop" onto one key, so
        /// the punctuation variants in the raw index can't split a family.
        var genre: String?
        var year: Int?
        var bpm: Double?
        var camelot: String?
        var keywords: [String]?

        init(songId: String, artistKey: String, genre: String? = nil, year: Int? = nil,
             bpm: Double? = nil, camelot: String? = nil, keywords: [String]? = nil) {
            self.songId = songId; self.artistKey = artistKey; self.genre = genre
            self.year = year; self.bpm = bpm; self.camelot = camelot; self.keywords = keywords
        }

        init(_ song: IndexSong, genre: String?) {
            self.init(songId: song.id, artistKey: PuzzleSimilarity.artistKey(song.artist),
                      genre: genre, year: song.year, bpm: song.bpm, camelot: song.camelot,
                      keywords: song.sentimentKeywords)
        }
    }

    /// The owner's rebalance, as numbers: three comparable similarity FAMILIES plus a small
    /// residual.
    ///
    ///  • **artist** — what shipped, and what he said dominates.
    ///  • **era** — genre + year, evenly.
    ///  • **sonic** — genre + bpm + key, with genre carrying half (see `sonicGenreShare`).
    ///  • **context** — co-membership, lyrical keywords, co-play and candidate recency. NOT one
    ///    of the three; it is the residual that keeps the signals the flat scorer already had
    ///    from vanishing, at roughly a third of a family's pull.
    ///
    /// The three are EXACTLY equal, which is what "evenly" was asked for. Genre deliberately
    /// appears in TWO of them, because that is what the owner specified ("genre and year … and
    /// genre and bpm & key") — and because on this library genre alone is a weak discriminator
    /// (R&B/Soul and Hip-Hop/Rap are ~68% of all plays), so it is only useful PAIRED.
    struct FamilyWeights: Equatable, Sendable {
        var artist = 0.30
        var era = 0.30
        var sonic = 0.30
        var context = 0.10
        /// Genre's share INSIDE the sonic family; bpm and key split the remainder evenly.
        ///
        /// Half, not a third, on purpose. bpm/camelot coverage is NOT universal (they come from
        /// the audio-indexer pass, which has never run over most of the Apple Music rows), and a
        /// song missing both would otherwise be structurally capped at a third of the family
        /// while an analysed one reaches 1.0. At a half the unanalysed song still reaches 0.5 on
        /// genre alone — a real gradient rather than a penalty for metadata it never had.
        var sonicGenreShare = 0.5
        static let balanced = FamilyWeights()
    }

    /// 0…1 similarity under the three-family blend.
    ///
    /// ── WHY THIS EXISTS ALONGSIDE `score` RATHER THAN REPLACING IT ───────────────────────────
    /// `score` ranks songs for a COLLECTION ("does this belong in the same crate"); tempo and key
    /// are irrelevant there, and every shipped Gem Collector round — plus the tests pinning it —
    /// depends on its exact term weights. Moving bpm/key into it would shift every one of those
    /// rankings to buy the puzzle a signal it has no use for. So the rebalance lives here, the
    /// recommendation surfaces call THIS, and the puzzle keeps calling `score`. Both read the
    /// same `TargetProfile` and the same term primitives, so there is one definition per signal.
    ///
    /// ── ROUND-LEVEL RENORMALIZATION, NEVER PER-SONG ──────────────────────────────────────────
    /// A family is in the denominator when the PROFILE can speak at least one of its terms, and
    /// each family's internal denominator is likewise fixed for the whole round by what the
    /// profile has. A candidate missing a field scores 0 on that term with the term still in the
    /// denominator — the same rule `availableWeight` applies, and for the same reason: a per-song
    /// denominator rewards songs with MISSING metadata (the sparse-feature bug, which there is a
    /// test pinning). What "renormalize, never score zero" means here is the ROUND-level drop: on
    /// a device where nothing has a bpm or a key, those two terms are not in any denominator at
    /// all, so no song is deflated for lacking them.
    ///
    /// ── WHEN THE SONIC FAMILY HAS NO TEMPO OR KEY AT ALL ─────────────────────────────────────
    /// It degenerates to genre rather than dropping out. Dropping it would hand its weight to the
    /// two survivors equally and push artist from 30% of the blend to 43% — re-creating the exact
    /// domination the rebalance exists to end. Degenerating instead lands artist 30% / genre 45% /
    /// year 15% / context 10%: genre is double-counted, which is the honest cost of a library with
    /// no audio analysis, and the owner's does have that analysis for its indexed sources.
    static func familyScore(_ c: Candidate, profile p: TargetProfile,
                            cloudRank: Double = 0, recency: Double = 0,
                            weights w: FamilyWeights = .balanced) -> Double {
        var num = 0.0, den = 0.0

        // ── A: artist ────────────────────────────────────────────────────────────────────────
        if !p.artistShare.isEmpty {
            num += w.artist * artistTerm(c.artistKey, p)
            den += w.artist
        }

        let hasGenre = !p.genreShare.isEmpty && p.maxGenreShare > 0
        let hasYear = p.yearMean != nil
        let hasBpm = p.bpmMean != nil
        let hasKey = !p.camelots.isEmpty

        // ── B: era (genre + year, evenly) ────────────────────────────────────────────────────
        if hasGenre || hasYear {
            var n = 0.0, d = 0.0
            if hasGenre { n += genreTerm(c.genre, p); d += 1 }
            if hasYear { n += yearTerm(c.year, p); d += 1 }
            num += w.era * (n / d)
            den += w.era
        }

        // ── C: sonic (genre + bpm + key) ─────────────────────────────────────────────────────
        if hasGenre || hasBpm || hasKey {
            let musical = max(0, (1 - w.sonicGenreShare) / 2)
            var n = 0.0, d = 0.0
            if hasGenre { n += w.sonicGenreShare * genreTerm(c.genre, p); d += w.sonicGenreShare }
            if hasBpm { n += musical * bpmTerm(c.bpm, p); d += musical }
            if hasKey { n += musical * camelotTerm(c.camelot, p); d += musical }
            if d > 0 {
                num += w.sonic * (n / d)
                den += w.sonic
            }
        }

        // ── D: context residual ──────────────────────────────────────────────────────────────
        var cn = 0.0, cd = 0.0
        if !p.coMemberIds.isEmpty {
            cn += contextWeights.coMember * (p.coMemberIds.contains(c.songId) ? 1 : 0)
            cd += contextWeights.coMember
        }
        if !p.keywordShare.isEmpty, p.maxKeywordShare > 0 {
            cn += contextWeights.lyrics * keywordTerm(c.keywords, p)
            cd += contextWeights.lyrics
        }
        if !p.coPlayWeight.isEmpty {
            cn += contextWeights.coPlay * coPlayTerm(c.songId, p)
            cd += contextWeights.coPlay
        }
        if p.hasRecency {
            cn += contextWeights.recency * min(1, max(0, recency))
            cd += contextWeights.recency
        }
        if cd > 0 {
            num += w.context * (cn / cd)
            den += w.context
        }

        let normalized = den > 0 ? min(1, max(0, num / den)) : 0
        // Same pure-bonus composition as `score`: cloudRank 0 (the default, and what a
        // default-OFF engine always yields) returns the local score EXACTLY.
        guard cloudRank > 0 else { return normalized }
        return min(1, normalized + cloudWeight * min(1, cloudRank) * (1 - normalized))
    }

    /// Convenience overload for callers holding an `IndexSong` (In Da Zone).
    static func familyScore(_ song: IndexSong, profile p: TargetProfile, genre: String?,
                            cloudRank: Double = 0, recency: Double = 0,
                            weights: FamilyWeights = .balanced) -> Double {
        familyScore(Candidate(song, genre: genre), profile: p, cloudRank: cloudRank,
                    recency: recency, weights: weights)
    }

    // MARK: - The shortlist

    /// Restrict `candidates` to the songs most similar to the profile, keeping the existing
    /// soft weights (♥ bias, play-count bias) as the WITHIN-shortlist ordering.
    ///
    /// Why a shortlist and not a weight multiplier: with `weight × (1 + s·sim)` over the real
    /// catalog (pool ≈ 96,000, genuinely-similar k ≈ 500, s = 3) the expected share of similar
    /// picks is `4k/(N+3k)` ≈ 2%; even s = 20 gives ~10%. A pure multiplier is cosmetic at this
    /// catalog size. The shortlist is the only thing that actually changes what the player sees.
    ///
    /// It can NEVER starve a round: playability is the outer gate (this only ever reorders and
    /// subsets a set that already passed it), and the top-up rule below refills a thin
    /// shortlist from the remaining candidates.
    ///
    /// `recencies` is songId → 0…1 recency, threaded in like `cloudRanks` rather than stored on
    /// the profile: the profile describes the TARGETS, and recency is a fact about the candidate.
    static func shortlist(_ candidates: [(song: IndexSong, weight: Double)],
                          profile p: TargetProfile,
                          genreBySongId: [String: String],
                          cloudRanks: [String: Double] = [:],
                          recencies: [String: Double] = [:],
                          mode: PuzzleSettings.Similarity,
                          wanted: Int) -> [(song: IndexSong, weight: Double)] {
        // OFF, or nothing to be similar TO ⇒ byte-identical to today's behaviour. This is also
        // the no-targets path, which is why "targets are optional" changes nothing about how a
        // target-less round samples.
        guard mode != .off, !p.isEmpty, !candidates.isEmpty else { return candidates }

        let floor = mode == .strict ? strictFloor : 0
        var scored: [(index: Int, sim: Double)] = []
        scored.reserveCapacity(min(candidates.count, 4096))
        for (i, c) in candidates.enumerated() {
            let s = score(c.song, profile: p, genre: genreBySongId[c.song.id],
                          cloudRank: cloudRanks[c.song.id] ?? 0,
                          recency: recencies[c.song.id] ?? 0)
            if s > floor { scored.append((i, s)) }
        }
        let k = max(400, 8 * max(1, wanted))
        // Deterministic order — the id tiebreak keeps seeded-RNG tests reproducible.
        scored.sort {
            if $0.sim != $1.sim { return $0.sim > $1.sim }
            let a = candidates[$0.index], b = candidates[$1.index]
            if a.weight != b.weight { return a.weight > b.weight }
            // Equal similarity AND equal weight ⇒ prefer the more recently played. Still fully
            // deterministic (the id tiebreak remains last), so seeded-RNG tests stay reproducible.
            let ra = recencies[a.song.id] ?? 0, rb = recencies[b.song.id] ?? 0
            if ra != rb { return ra > rb }
            return a.song.id < b.song.id
        }
        if scored.count > k { scored.removeLast(scored.count - k) }

        // Re-weight INSIDE the shortlist. The 0.25 floor means the least-similar survivor is
        // ~4× less likely than the most similar one but never impossible — the round stays
        // varied instead of showing the same artist twelve times. The existing ♥/play-count
        // weights survive multiplicatively, so "favour favourites" still favours favourites
        // WITHIN the similar set.
        var out = scored.map { (song: candidates[$0.index].song,
                                weight: candidates[$0.index].weight * (0.25 + $0.sim)) }

        // STARVATION GUARD — a similarity setting must never be able to empty a round.
        let minimum = min(candidates.count, max(20, wanted / 2))
        if out.count < minimum {
            let taken = Set(scored.map(\.index))
            let filler = candidates.enumerated()
                .filter { !taken.contains($0.offset) }
                .sorted {
                    if $0.element.weight != $1.element.weight { return $0.element.weight > $1.element.weight }
                    let ra = recencies[$0.element.song.id] ?? 0, rb = recencies[$1.element.song.id] ?? 0
                    if ra != rb { return ra > rb }
                    return $0.element.song.id < $1.element.song.id
                }
                .prefix(minimum - out.count)
                .map { (song: $0.element.song, weight: $0.element.weight) }
            out.append(contentsOf: filler)
        }
        return out
    }
}
