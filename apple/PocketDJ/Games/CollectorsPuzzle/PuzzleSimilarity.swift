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

    // MARK: - Term weights (sum to 1.0 when every signal is available)

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
        /// lowercased keyword → share of the KEYWORD-BEARING target members carrying it
        /// (top 20 only — the tail is noise).
        var keywordShare: [String: Double] = [:]
        var maxKeywordShare: Double = 0
        /// Songs sharing a NON-target collection with at least one target member.
        var coMemberIds: Set<String> = []
        /// songId → number of plays inside `coPlayWindowMs` of a play of a target member.
        var coPlayCount: [String: Int] = [:]
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
    static func profile(targetMemberIds: [[String]],
                        songsById: [String: IndexSong],
                        genreBySongId: [String: String],
                        otherCollections: [[String]],
                        plays: [(songId: String, atMs: Double)]) -> TargetProfile {
        var p = TargetProfile()
        var members = Set<String>()
        for ids in targetMemberIds { members.formUnion(ids) }
        guard !members.isEmpty else { return p }
        p.memberIds = members

        var artistCount: [String: Double] = [:]
        var genreCount: [String: Double] = [:]
        var years: [Double] = []
        var keywordCount: [String: Double] = [:]
        var keywordBearers = 0.0
        var resolved = 0.0

        for id in members {
            guard let song = songsById[id] else { continue }
            resolved += 1
            artistCount[artistKey(song.artist), default: 0] += 1
            if let cat = genreBySongId[id] { genreCount[cat, default: 0] += 1 }
            if let y = song.year { years.append(Double(y)) }
            let kws = (song.sentimentKeywords ?? []).map { $0.lowercased() }
            if !kws.isEmpty {
                keywordBearers += 1
                for k in Set(kws) { keywordCount[k, default: 0] += 1 }
            }
        }
        // Not one target member resolves against this device's catalog (a collection full of
        // songs from a source that isn't loaded) ⇒ no profile, no re-ranking.
        guard resolved > 0 else { return p }

        p.artistShare = artistCount.mapValues { $0 / resolved }
        p.maxArtistShare = p.artistShare.values.max() ?? 0
        p.genreShare = genreCount.mapValues { $0 / resolved }
        p.maxGenreShare = p.genreShare.values.max() ?? 0
        if !years.isEmpty {
            let mean = years.reduce(0, +) / Double(years.count)
            p.yearMean = mean
            let variance = years.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(years.count)
            p.yearSigma = max(8, variance.squareRoot())
        }
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
                    p.coPlayCount[e.songId, default: 0] += 1
                }
            }
        }

        var w = 0.0
        if !p.artistShare.isEmpty { w += wArtist }
        if !p.genreShare.isEmpty { w += wGenre }
        if p.yearMean != nil { w += wYear }
        if !p.keywordShare.isEmpty { w += wLyrics }
        if !p.coMemberIds.isEmpty { w += wCoMember }
        if !p.coPlayCount.isEmpty { w += wCoPlay }
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

    // MARK: - Scoring

    /// 0…1 similarity of one song to the profile. `cloudRank` is 0 for everything the cloud
    /// did not name (or when the cloud is off, which is the DEFAULT — see the type doc).
    static func score(_ song: IndexSong, profile p: TargetProfile,
                      genre: String?, cloudRank: Double = 0) -> Double {
        var local = 0.0
        if !p.artistShare.isEmpty {
            let share = p.artistShare[artistKey(song.artist)] ?? 0
            local += wArtist * min(1, share / max(0.05, p.maxArtistShare))
        }
        if !p.genreShare.isEmpty, p.maxGenreShare > 0 {
            let share = genre.flatMap { p.genreShare[$0] } ?? 0
            local += wGenre * min(1, share / p.maxGenreShare)
        }
        if let mean = p.yearMean, let y = song.year {
            local += wYear * exp(-abs(Double(y) - mean) / max(8, p.yearSigma))
        }
        if !p.keywordShare.isEmpty, p.maxKeywordShare > 0 {
            let hits = Set((song.sentimentKeywords ?? []).map { $0.lowercased() })
                .compactMap { p.keywordShare[$0] }
            if !hits.isEmpty {
                local += wLyrics * min(1, hits.reduce(0, +) / p.maxKeywordShare)
            }
        }
        if !p.coMemberIds.isEmpty, p.coMemberIds.contains(song.id) { local += wCoMember }
        if !p.coPlayCount.isEmpty {
            let n = Double(p.coPlayCount[song.id] ?? 0)
            if n > 0 { local += wCoPlay * min(1, n / coPlaySaturation) }
        }
        let normalized = min(1, max(0, p.availableWeight > 0 ? local / p.availableWeight : 0))
        // The cloud is a pure BONUS: it lifts a song a fraction of the way to 1, so it can only
        // ever RAISE a score, never zero one out, never hard-filter — and with `cloudRank == 0`
        // (the default, since the engine is off by default) the result is EXACTLY the local
        // score. That literal identity is what makes the app safe to ship before the route is
        // deployed: turning the cloud off changes nothing at all, not even the scale.
        guard cloudRank > 0 else { return normalized }
        return min(1, normalized + cloudWeight * min(1, cloudRank) * (1 - normalized))
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
    static func shortlist(_ candidates: [(song: IndexSong, weight: Double)],
                          profile p: TargetProfile,
                          genreBySongId: [String: String],
                          cloudRanks: [String: Double] = [:],
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
                          cloudRank: cloudRanks[c.song.id] ?? 0)
            if s > floor { scored.append((i, s)) }
        }
        let k = max(400, 8 * max(1, wanted))
        // Deterministic order — the id tiebreak keeps seeded-RNG tests reproducible.
        scored.sort {
            if $0.sim != $1.sim { return $0.sim > $1.sim }
            let a = candidates[$0.index], b = candidates[$1.index]
            if a.weight != b.weight { return a.weight > b.weight }
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
                    return $0.element.song.id < $1.element.song.id
                }
                .prefix(minimum - out.count)
                .map { (song: $0.element.song, weight: $0.element.weight) }
            out.append(contentsOf: filler)
        }
        return out
    }
}
