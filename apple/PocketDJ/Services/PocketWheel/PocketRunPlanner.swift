import Foundation

/// The adaptive 100-song pocket run (§4): initial selection (pool → score → compose with quotas,
/// caps and a seeded tempo/key flow → bench), the live re-plan's slot-wise replacement rule, and
/// the bench top-up W2 needs (100 PLAYED-THROUGH songs: a skipped row is topped up). PURE and
/// deterministic per seed.
enum PocketRunPlanner {

    // MARK: Tuning

    static let slots = 100
    static let artistCap = 6
    static let artistSpacing = 4           // no artist twice within 4 slots
    static let newcomerFloor = 0.2         // ≥ 20 % of slots: artists outside the cell's top 10
    static let dominantMinSlotShare = 0.4  // when the dominant collection's share ≥ 0.25
    static let softCap = 0.25              // soft neighbours ≤ 25 % of the pool
    static let softMinFit = 0.6
    static let benchCap = 400
    static let poolCap = 600
    static let firstDrawFrom = 8
    static let nextDrawFrom = 6
    static let instantLeadSlots = 3
    static let replanFloorShareOfMedian = 0.6
    static let minPocketFit = 0.3

    // MARK: Input

    struct Candidate: Sendable, Equatable {
        var id: String
        var title: String
        var artist: String
        var lengthMs: Int?
        var features: PocketTuning.Features
        var camelot: String?
        /// Hard membership (add-time recency, 0.5…1) by collection; soft ≤ 0.6 for non-members.
        var memberships: [String: Double] = [:]
        /// Starts with no network round trip (burned / AM pre-resolvable / cached presign).
        var startsInstantly = false
        var foldedBpm: Double? { InThePocketScorer.foldBpm(features.bpm) }
    }

    struct Input: Sendable {
        var profile: PocketProfile
        /// Every PLAYABLE candidate (the playability rule is the caller's).
        var candidates: [String: Candidate]
        /// Played in the last 12 h, lifetime 👎, …
        var excluded: Set<String> = []
        /// InThePocketScorer.familiarity over history.
        var familiarity: [String: Double] = [:]
        var tuning: PocketTuning.Multipliers = .neutral
        var seed: UInt64
        var slots: Int = PocketRunPlanner.slots
        init(profile: PocketProfile, candidates: [String: Candidate], excluded: Set<String> = [],
             familiarity: [String: Double] = [:], tuning: PocketTuning.Multipliers = .neutral,
             seed: UInt64, slots: Int = PocketRunPlanner.slots) {
            self.profile = profile; self.candidates = candidates; self.excluded = excluded
            self.familiarity = familiarity; self.tuning = tuning; self.seed = seed; self.slots = slots
        }
    }

    struct Row: Sendable, Equatable, Codable {
        var songId: String
        var slot: Int
        var collectionId: String?
        var score: Double
    }

    struct BenchEntry: Sendable, Equatable, Codable {
        var songId: String
        var score: Double
    }

    struct Plan: Sendable, Equatable {
        var rows: [Row]
        var bench: [BenchEntry]
    }

    // MARK: Scoring (§4.2 step 2)

    struct Scorer: Sendable {
        let profile: PocketProfile
        let tuning: PocketTuning.Multipliers
        let familiarity: [String: Double]
        let maxSeed: Double
        let maxGenre: Double
        let timbreCal: SimilarityFamilies.TimbreCalibration?

        init(profile: PocketProfile, tuning: PocketTuning.Multipliers, familiarity: [String: Double],
             pool: [Candidate]) {
            self.profile = profile; self.tuning = tuning; self.familiarity = familiarity
            maxSeed = profile.seeds.values.max() ?? 0
            maxGenre = profile.genres.values.max() ?? 0
            if let pos = profile.timbre {
                timbreCal = SimilarityFamilies.timbreCalibrate(pool.map(\.features.timbre), positive: pos,
                                                               negative: tuning.negativeTimbre, rejectionWeight: 0.5)
            } else { timbreCal = nil }
        }

        /// The §4.2 score with the CURRENT tuning multipliers.
        func score(_ c: Candidate) -> Double {
            var s = 0.0
            for (cid, w) in profile.collections { s += 1.5 * w * (c.memberships[cid] ?? 0) }
            if maxSeed > 0, let v = profile.seeds[c.id] { s += 0.8 * v / maxSeed }
            if let band = profile.bpmBand {
                if let b = c.foldedBpm {
                    let d = band.contains(b) ? 0 : min(abs(b - band.lowerBound), abs(b - band.upperBound))
                    s += 0.6 * (d == 0 ? 1 : exp(-d / 8))
                } else { s += 0.6 * 0.5 }   // unknown tempo: neutral (AM rows carry no BPM)
            }
            if let era = profile.era {
                if let y = c.features.year, y > 0 { s += 0.5 * SimilarityFamilies.eraFit(year: Double(y), window: era) }
                else { s += 0.5 * SimilarityFamilies.fallbackNeutralEraFit }
            }
            if let pos = profile.timbre, let cal = timbreCal {
                s += 0.7 * SimilarityFamilies.timbreFit(c.features.timbre, positive: pos, negative: tuning.negativeTimbre,
                                                        rejectionWeight: 0.5, calibration: cal)
            }
            if maxGenre > 0, let g = c.features.genre, let v = profile.genres[g] { s += 0.4 * v / maxGenre }
            s += familiarity[c.id] ?? 0
            return max(0, s) * tuning.factor(c.features)
        }
    }

    // MARK: Pool (§4.2 step 1)

    static func pool(_ input: Input) -> [Candidate] {
        let p = input.profile
        var core: [Candidate] = []
        var soft: [Candidate] = []
        for c in input.candidates.values where !input.excluded.contains(c.id) && !input.tuning.isBanned(c.features) {
            let member = p.collections.keys.contains { (c.memberships[$0] ?? 0) >= 0.5 }
            if member || p.seeds[c.id] != nil || p.candidateBoost[c.id] != nil {
                core.append(c)
                continue
            }
            if softFit(c, profile: p) >= softMinFit { soft.append(c) }
        }
        let scorer = Scorer(profile: p, tuning: input.tuning, familiarity: input.familiarity, pool: core + soft)
        func ranked(_ a: [Candidate]) -> [Candidate] {
            a.map { ($0, scorer.score($0)) }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }.map(\.0)
        }
        let coreRanked = ranked(core)
        let softQuota = max(0, Int(Double(min(poolCap, coreRanked.count + soft.count)) * softCap))
        return Array((Array(coreRanked.prefix(poolCap)) + ranked(soft).prefix(softQuota)).prefix(poolCap))
    }

    /// The soft-neighbour test for a NON-member: timbre fit to the profile centroid, else the
    /// B + C families (genre + era, genre + bpm + key).
    static func softFit(_ c: Candidate, profile p: PocketProfile) -> Double {
        if let pos = p.timbre, let v = c.features.timbre, let fit = SimilarityFamilies.timbreFit(v, profile: pos) { return fit }
        guard let g = c.features.genre, let gw = p.genres[g], gw > 0 else { return 0 }
        let gNorm = gw / (p.genres.values.max() ?? gw)
        var parts: [Double] = []
        if let era = p.era, let y = c.features.year { parts.append(SimilarityFamilies.eraFit(year: Double(y), window: era)) }
        if let band = p.bpmBand, let b = c.foldedBpm {
            let d = band.contains(b) ? 0 : min(abs(b - band.lowerBound), abs(b - band.upperBound))
            parts.append(exp(-d / 8))
        }
        let rest = parts.isEmpty ? 0.5 : parts.reduce(0, +) / Double(parts.count)
        return gNorm * (0.5 + 0.5 * rest)
    }

    // MARK: Compose (§4.2 step 3)

    /// The collection a candidate fills a quota slot for: the profile collection with the largest
    /// w_c · m_c(song), or nil ("other").
    static func bucket(_ c: Candidate, profile p: PocketProfile) -> String? {
        p.collections.compactMap { cid, w -> (String, Double)? in
            let m = c.memberships[cid] ?? 0
            return m >= 0.5 ? (cid, w * m) : nil
        }.max { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 > $1.0 }?.0
    }

    /// Slots per collection ∝ w_c, the dominant at ≥ 40 % when its share is ≥ 0.25.
    static func quotas(profile p: PocketProfile, slots: Int) -> [String: Int] {
        guard !p.collections.isEmpty else { return [:] }
        var w = p.collections
        let total = w.values.reduce(0, +)
        guard total > 0 else { return [:] }
        for k in w.keys { w[k]! /= total }
        if let d = p.dominantCollectionId, let share = w[d], share >= 0.25, share < dominantMinSlotShare {
            let rest = 1 - share
            for k in w.keys where k != d { w[k]! *= (1 - dominantMinSlotShare) / max(rest, 1e-9) }
            w[d] = dominantMinSlotShare
        }
        return w.mapValues { Int(($0 * Double(slots)).rounded()) }
    }

    static func flow(_ c: Candidate, after prev: Candidate?) -> Double {
        guard let prev else { return 0 }
        var f = 0.0
        if let a = c.foldedBpm, let b = prev.foldedBpm { f += 0.3 * exp(-abs(a - b) / 10) }
        if let a = c.camelot, let b = prev.camelot { f += 0.2 * SimilarityFamilies.camelotRelatedness(a, b) }
        return f
    }

    static func plan(_ input: Input) -> Plan {
        let pool = pool(input)
        let scorer = Scorer(profile: input.profile, tuning: input.tuning, familiarity: input.familiarity, pool: pool)
        var scored = pool.map { (c: $0, s: scorer.score($0), bucket: bucket($0, profile: input.profile)) }
        let slots = min(input.slots, scored.count)
        let quotas = quotas(profile: input.profile, slots: slots)
        let topArtists = Set(input.profile.artists.sorted { $0.value > $1.value }.prefix(10).map(\.key))
        let newcomersNeeded = Int((Double(slots) * newcomerFloor).rounded(.up))
        var rng = SplitMix64(seed: input.seed)
        var rows: [Row] = []
        var placed: [Candidate] = []
        var artistCount: [String: Int] = [:]
        var bucketCount: [String: Int] = [:]
        var newcomers = 0
        func isNewcomer(_ c: Candidate) -> Bool { !c.features.artistKeys.contains { topArtists.contains($0) } }

        while rows.count < slots, !scored.isEmpty {
            let slot = rows.count + 1
            let recent = placed.suffix(artistSpacing - 1).flatMap(\.features.artistKeys)
            let remaining = slots - rows.count
            let mustNewcomer = !topArtists.isEmpty && newcomersNeeded - newcomers >= remaining
            func eligible(_ e: (c: Candidate, s: Double, bucket: String?), strict: Bool) -> Bool {
                let keys = e.c.features.artistKeys
                if keys.contains(where: { (artistCount[$0] ?? 0) >= artistCap }) { return false }
                if keys.contains(where: { recent.contains($0) }) { return false }
                if mustNewcomer && !isNewcomer(e.c) { return false }
                if strict, let b = e.bucket, let q = quotas[b], (bucketCount[b] ?? 0) >= q { return false }
                if strict, e.bucket == nil, !quotas.isEmpty {
                    let quotaTotal = quotas.values.reduce(0, +)
                    if (bucketCount["\u{0}other"] ?? 0) >= max(0, slots - quotaTotal) { return false }
                }
                return true
            }
            var idx = scored.indices.filter { eligible(scored[$0], strict: true) }
            if idx.isEmpty { idx = scored.indices.filter { eligible(scored[$0], strict: false) } }
            if idx.isEmpty { idx = Array(scored.indices) }   // constraints unsatisfiable: best effort
            if slot <= instantLeadSlots {
                let instant = idx.filter { scored[$0].c.startsInstantly }
                if !instant.isEmpty { idx = instant }
            }
            let prev = placed.last
            let ranked = idx.map { ($0, scored[$0].s + flow(scored[$0].c, after: prev)) }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : scored[$0.0].c.id < scored[$1.0].c.id }
            let window = Array(ranked.prefix(slot == 1 ? firstDrawFrom : nextDrawFrom))
            let pick = InThePocketScorer.weightedDraw(window, rng: &rng)
            let e = scored.remove(at: pick)
            rows.append(Row(songId: e.c.id, slot: slot, collectionId: e.bucket, score: (e.s * 1e6).rounded() / 1e6))
            placed.append(e.c)
            for k in e.c.features.artistKeys { artistCount[k, default: 0] += 1 }
            bucketCount[e.bucket ?? "\u{0}other", default: 0] += 1
            if isNewcomer(e.c) { newcomers += 1 }
        }
        let bench = scored.sorted { $0.s != $1.s ? $0.s > $1.s : $0.c.id < $1.c.id }.prefix(benchCap)
            .map { BenchEntry(songId: $0.c.id, score: ($0.s * 1e6).rounded() / 1e6) }
        return Plan(rows: rows, bench: Array(bench))
    }

    // MARK: Re-plan (§4.4)

    /// A row of the live queue the planner may consider (the caller already applied the
    /// protection rules: playing row, next-row runway, pinned/manual rows, in-flight rips).
    struct LiveRow: Sendable, Equatable {
        var uid: UUID
        var songId: String
        var slot: Int
        var collectionId: String?
        /// Replacement must start instantly (an in-flight capture is never traded for another).
        var requiresInstant: Bool = false
    }

    struct Replacement: Sendable, Equatable {
        var uid: UUID
        var songId: String
        var slot: Int
        var collectionId: String?
        var score: Double
    }

    struct ReplanResult: Sendable, Equatable {
        var replacements: [Replacement]
        var removals: [UUID]
        var banned: [String]
    }

    /// "Similar musically, different artist": B (genre + era) + C (genre + bpm + key) + timbre
    /// distance when both have vectors. NO artist family.
    static func musicalSim(_ x: Candidate, _ r: Candidate) -> Double {
        var parts: [Double] = []
        let sameGenre: Double = (x.features.genre != nil && x.features.genre == r.features.genre) ? 1 : 0
        if x.features.genre != nil || r.features.genre != nil { parts.append(sameGenre) }
        if let a = x.features.year, let b = r.features.year { parts.append(exp(-Double(abs(a - b)) / 4)) }
        if let a = x.foldedBpm, let b = r.foldedBpm { parts.append(exp(-abs(a - b) / 10)) }
        if let a = x.camelot, let b = r.camelot { parts.append(SimilarityFamilies.camelotRelatedness(a, b)) }
        if let a = x.features.timbre, let b = r.features.timbre, let d = SimilarityFamilies.timbreDistance(a, b) {
            parts.append(exp(-d / SimilarityFamilies.timbreDecay))
            parts.append(exp(-d / SimilarityFamilies.timbreDecay))   // timbre counts double when known
        }
        return parts.isEmpty ? 0 : parts.reduce(0, +) / Double(parts.count)
    }

    /// Replace upcoming rows that now fall below the floor (banned artist, or a score under
    /// 0.6 × the median placed score) with the best "similar, different artist" candidate from the
    /// bench + pool; a row with no candidate clearing `pocketFit ≥ 0.3` is removed.
    static func replan(profile: PocketProfile, candidates: [String: Candidate], tuning: PocketTuning.Multipliers,
                       familiarity: [String: Double], live: [LiveRow], inRun: Set<String>,
                       neighbours: [UUID: (prev: String?, next: String?)], excluded: Set<String> = []) -> ReplanResult {
        let pool = candidates.values.filter { !excluded.contains($0.id) }
        let scorer = Scorer(profile: profile, tuning: tuning, familiarity: familiarity, pool: Array(pool))
        let placedScores = live.compactMap { candidates[$0.songId].map(scorer.score) }.sorted()
        let median = placedScores.isEmpty ? 0 : placedScores[placedScores.count / 2]
        let maxScore = max(pool.map(scorer.score).max() ?? 1, 1e-9)
        var used = inRun
        var artistCount: [String: Int] = [:]
        for row in live { for k in candidates[row.songId]?.features.artistKeys ?? [] { artistCount[k, default: 0] += 1 } }
        var replacements: [Replacement] = []
        var removals: [UUID] = []
        for row in live.sorted(by: { $0.slot < $1.slot }) {
            guard let r = candidates[row.songId] else { continue }
            let banned = tuning.isBanned(r.features)
            let s = scorer.score(r)
            guard banned || s < replanFloorShareOfMedian * median else { continue }
            let atCap = Set(artistCount.filter { $0.value >= artistCap }.map(\.key))
            let nb = neighbours[row.uid]
            var best: (Candidate, Double, Double)?
            for x in pool where !used.contains(x.id) {
                if x.features.artistKeys.contains(where: { tuning.bannedArtists.contains($0) || atCap.contains($0) }) { continue }
                if Set(x.features.artistKeys).intersection(r.features.artistKeys).count > 0 { continue }
                if row.requiresInstant && !x.startsInstantly { continue }
                let fit = scorer.score(x) / maxScore
                guard fit >= minPocketFit else { continue }
                let prev = nb?.prev.flatMap { candidates[$0] }, next = nb?.next.flatMap { candidates[$0] }
                let fl = (flow(x, after: prev) + flow(x, after: next)) / 2
                let total = 0.55 * musicalSim(x, r) + 0.35 * fit + 0.10 * fl
                if best == nil || total > best!.1 || (total == best!.1 && x.id < best!.0.id) { best = (x, total, scorer.score(x)) }
            }
            for k in r.features.artistKeys { artistCount[k, default: 0] -= 1 }
            if let (x, _, xs) = best {
                used.insert(x.id)
                for k in x.features.artistKeys { artistCount[k, default: 0] += 1 }
                replacements.append(Replacement(uid: row.uid, songId: x.id, slot: row.slot,
                                                collectionId: bucket(x, profile: profile), score: (xs * 1e6).rounded() / 1e6))
            } else {
                removals.append(row.uid)
            }
        }
        return ReplanResult(replacements: replacements, removals: removals, banned: tuning.bannedArtists.sorted())
    }

    /// W2 top-up: the next `count` songs to APPEND after a skip (so 100 played-through stays
    /// reachable), best-scored first, respecting bans, the artist cap and spacing after `tail`.
    static func topUp(count: Int, profile: PocketProfile, candidates: [String: Candidate],
                      tuning: PocketTuning.Multipliers, familiarity: [String: Double],
                      inRun: Set<String>, tail: [String], excluded: Set<String> = []) -> [BenchEntry] {
        guard count > 0 else { return [] }
        let pool = candidates.values.filter { !excluded.contains($0.id) && !inRun.contains($0.id) && !tuning.isBanned($0.features) }
        let scorer = Scorer(profile: profile, tuning: tuning, familiarity: familiarity, pool: Array(pool))
        var artistCount: [String: Int] = [:]
        for id in inRun { for k in candidates[id]?.features.artistKeys ?? [] { artistCount[k, default: 0] += 1 } }
        var recent = Array(tail.suffix(artistSpacing - 1).flatMap { candidates[$0]?.features.artistKeys ?? [] })
        var out: [BenchEntry] = []
        let ranked = pool.map { ($0, scorer.score($0)) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
        for (c, s) in ranked where out.count < count {
            let keys = c.features.artistKeys
            if keys.contains(where: { (artistCount[$0] ?? 0) >= artistCap || recent.contains($0) }) { continue }
            out.append(BenchEntry(songId: c.id, score: (s * 1e6).rounded() / 1e6))
            for k in keys { artistCount[k, default: 0] += 1 }
            recent = Array((recent + keys).suffix((artistSpacing - 1) * 2))
        }
        return out
    }
}
