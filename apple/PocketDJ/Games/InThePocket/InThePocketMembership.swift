import Foundation

/// IN THE POCKET × COLLECTIONS — the membership half of the scorer
/// (docs/design/pockets-collections.md). PURE, like the rest of `InThePocketScorer`.
///
/// m(s) — a song's membership vector, collection id → weight:
///   · HARD 1.0 for a (flattened) member, × the add-recency scale
///     `0.5 + 0.5·e^(−ageDays/45)` (unknown add time ⇒ 0.75) — a song freshly added to a
///     playlist expresses that playlist more strongly;
///   · SOFT for a NON-member: `0.6 · sim(s, centroid(c))` when sim ≥ 0.55, where sim blends what
///     the device knows per song — genre share in c, a BPM gaussian vs c's median (folded
///     80–160), the Camelot neighbour fraction, mood Jaccard. This is "a song similar to a
///     playlist's songs" — it lets the playlist's vibe pull in songs that aren't in it yet.
///
/// The PROFILE membership vector (what "a pocket here, now" expresses) comes from the cloud's
/// pattern/pocket `membership` weighted by context match, else from this device's contextual
/// plays (CURRENT hard membership, recency from now — retroactive — plus soft), then is nudged by the live session
/// (what played in the last hour, hard + soft). Each candidate gains `w · cosine(m(s), profile)`.
extension InThePocketScorer {

    // MARK: - Index

    /// Hard membership lookups + per-collection centroids (built lazily, only for the profile's
    /// collections — never for all 500).
    struct MembershipIndex {
        let byId: [String: CollectionInfo]
        /// songId → the collections it is a hard member of.
        let memberOf: [String: [String]]

        init(_ input: Input) {
            var byId: [String: CollectionInfo] = [:]
            var memberOf: [String: [String]] = [:]
            for c in input.collections where byId[c.id] == nil {
                byId[c.id] = c
                for s in c.songIds { memberOf[s, default: []].append(c.id) }
            }
            self.byId = byId
            self.memberOf = memberOf
        }

        var isEmpty: Bool { byId.isEmpty }
        func name(_ id: String?) -> String? { id.flatMap { byId[$0]?.name } }
        func collections(of songId: String) -> Set<String> { Set(memberOf[songId] ?? []) }

        /// Hard membership of `songId` as of `refMs` (add-recency scaled).
        func hard(_ songId: String, refMs: Double) -> [String: Double] {
            guard let ids = memberOf[songId] else { return [:] }
            var out: [String: Double] = [:]
            for id in ids { out[id] = addScale(byId[id]?.addedAtMs[songId], refMs: refMs) }
            return out
        }
    }

    /// `0.5 + 0.5·e^(−ageDays/45)` with ageDays = (refMs − addAt) clamped ≥ 0; unknown ⇒ 0.75.
    /// Callers pass NOW: membership is current and retroactive (Levi, 2026-10-13) — never gated
    /// on the add predating a play.
    static func addScale(_ addedAtMs: Double?, refMs: Double) -> Double {
        guard let a = addedAtMs else { return unknownAddScale }
        let ageDays = max(0, refMs - a) / 86_400_000
        return 0.5 + 0.5 * exp(-ageDays / addHalfLifeDays)
    }

    /// L1-normalised, top `membershipTop` kept (ties → id), weights rounded to 1e-4.
    static func normalizeMembership(_ m: [String: Double]) -> [String: Double] {
        let top = m.filter { $0.value > 0 && $0.value.isFinite }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(membershipTop)
        let total = top.reduce(0) { $0 + $1.value }
        guard total > 0 else { return [:] }
        return Dictionary(uniqueKeysWithValues: top.map { ($0.key, ($0.value / total * 10_000).rounded() / 10_000) })
    }

    // MARK: - Profile

    /// Fill `profile.membership` when the cloud gave none (local contextual plays), then nudge it
    /// with the live session. No collections on this device ⇒ untouched (parity).
    static func applyMembership(_ profile: inout Profile, input: Input, index: MembershipIndex) {
        guard !index.isEmpty else { return }
        // A played song expresses the collections it is IN (hard) and the ones it SOUNDS LIKE
        // (soft) — "playing a song similar to a playlist's songs" is what lets that playlist's
        // songs into the round. Soft is computed for the most-played distinct songs only.
        var centroids: [String: Centroid]?
        var softMemo: [String: [String: Double]] = [:]
        func soft(_ songId: String) -> [String: Double] {
            if let m = softMemo[songId] { return m }
            guard let s = input.catalog[songId] else { softMemo[songId] = [:]; return [:] }
            if centroids == nil {
                var cs: [String: Centroid] = [:]
                for (id, c) in index.byId { if let cen = Centroid(c, catalog: input.catalog) { cs[id] = cen } }
                centroids = cs
            }
            let mine = Set(index.memberOf[songId] ?? [])
            var out: [String: Double] = [:]
            for (id, cen) in centroids ?? [:] where !mine.contains(id) {
                let sim = similarity(s, cen)
                if sim >= softMin { out[id] = softMax * sim }
            }
            softMemo[songId] = out
            return out
        }
        func vector(_ songId: String, refMs: Double, withSoft: Bool) -> [String: Double] {
            var m = index.hard(songId, refMs: refMs)
            if withSoft { for (id, w) in soft(songId) where m[id] == nil { m[id] = w } }
            return m
        }
        if profile.membership.isEmpty {
            let kept = contextBasis(input).plays.filter { !$0.isSkip }
            var counts: [String: Int] = [:]
            for p in kept { counts[p.songId, default: 0] += 1 }
            let softIds = Set(counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(softBasisSongs).map(\.key))
            var acc: [String: Double] = [:]
            for p in kept {
                // Membership is CURRENT and retroactive: a song added to a playlist after this
                // play still expresses it; recency is measured from NOW, never from the play.
                for (id, w) in vector(p.songId, refMs: input.nowMs, withSoft: softIds.contains(p.songId)) {
                    acc[id, default: 0] += w
                }
            }
            profile.membership = normalizeMembership(acc)
        }
        // Live session pull: what's been playing this past hour says where the night is going.
        let since = input.nowMs - liveWindowMs
        var live: [String: Double] = [:]
        for p in input.plays where p.atMs >= since && p.atMs <= input.nowMs && !p.isSkip {
            for (id, w) in vector(p.songId, refMs: input.nowMs, withSoft: true) { live[id, default: 0] += w }
        }
        let liveN = normalizeMembership(live)
        guard !liveN.isEmpty else { return }
        var blended = profile.membership
        for (id, w) in liveN { blended[id, default: 0] += liveWeight * w }
        profile.membership = normalizeMembership(blended)
    }

    /// The round's `collection` targets (top `maxCollectionTargets`, strongest = 1) — recorded so
    /// round learning can re-weight collections. Labels are LOCAL names (never uploaded).
    static func collectionTargets(_ membership: [String: Double], index: MembershipIndex) -> [InThePocketTarget] {
        let top = membership.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(maxCollectionTargets)
        guard let m = top.first?.value, m > 0 else { return [] }
        return top.map {
            InThePocketTarget(dim: "collection", value: $0.key, label: index.name($0.key) ?? "Your collection",
                              weight: ($0.value / m * 1000).rounded() / 1000)
        }
    }

    // MARK: - Centroid + similarity

    /// What a collection sounds like, from its members the catalog can describe.
    struct Centroid: Equatable {
        var genreShare: [String: Double]
        var bpmMedian: Double?
        /// Camelot code (uppercased) → members on it.
        var camelotCounts: [String: Int]
        var keyed: Int
        /// Moods carried by ≥ 20 % of the members (≤ 8).
        var moods: Set<String>

        init?(_ c: CollectionInfo, catalog: [String: Song]) {
            let songs = c.songIds.compactMap { catalog[$0] }
            guard songs.count >= minCentroidMembers else { return nil }
            var g: [String: Double] = [:]
            var genred = 0.0
            var bpms: [Double] = []
            var keys: [String: Int] = [:]
            var keyed = 0
            var moodCounts: [String: Int] = [:]
            for s in songs {
                if let x = s.genre { g[x, default: 0] += 1; genred += 1 }
                if let b = foldBpm(s.bpm) { bpms.append(b) }
                if let k = s.camelot?.uppercased(), !k.isEmpty { keys[k, default: 0] += 1; keyed += 1 }
                for m in Set(s.moods) { moodCounts[m, default: 0] += 1 }
            }
            genreShare = genred > 0 ? g.mapValues { $0 / genred } : [:]
            bpms.sort()
            bpmMedian = bpms.isEmpty ? nil : bpms[bpms.count / 2]
            camelotCounts = keys
            self.keyed = keyed
            let minMood = max(1, Int((Double(songs.count) * 0.2).rounded(.up)))
            moods = Set(moodCounts.filter { $0.value >= minMood }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(8).map(\.key))
        }
    }

    /// sim(s, centroid) ∈ [0, 1]: the weighted blend over the dims BOTH sides have; 0 when they
    /// share too little to judge (< `simMinCoverage` of the weight).
    static func similarity(_ s: Song, _ c: Centroid) -> Double {
        var sum = 0.0, wsum = 0.0
        if let g = s.genre, !c.genreShare.isEmpty {
            sum += simGenreWeight * (c.genreShare[g] ?? 0); wsum += simGenreWeight
        }
        if let b = foldBpm(s.bpm), let med = c.bpmMedian {
            let d = b - med
            sum += simBpmWeight * exp(-(d * d) / (2 * simBpmSigma * simBpmSigma)); wsum += simBpmWeight
        }
        if let k = s.camelot?.uppercased(), !k.isEmpty, c.keyed > 0 {
            var near = 0
            for (code, n) in c.camelotCounts where code == k || RecAudioShortlist.camelotAdjacent(code, k) { near += n }
            sum += simCamelotWeight * Double(near) / Double(c.keyed); wsum += simCamelotWeight
        }
        if !s.moods.isEmpty, !c.moods.isEmpty {
            let mine = Set(s.moods)
            sum += simMoodWeight * Double(mine.intersection(c.moods).count) / Double(mine.union(c.moods).count)
            wsum += simMoodWeight
        }
        guard wsum >= simMinCoverage else { return 0 }
        return sum / wsum
    }

    // MARK: - The pull

    /// cosine(m(s), profile) for candidates. m(s) is hard over EVERY collection the song is in
    /// (so a song in many unrelated collections is not over-credited) and soft over the profile's
    /// collections only (those are the only ones the dot product can see).
    struct MembershipPull {
        let profile: [String: Double]
        let profileNorm: Double
        let index: MembershipIndex
        let centroids: [String: Centroid]

        init?(profile: [String: Double], index: MembershipIndex, input: Input) {
            guard !profile.isEmpty, !index.isEmpty else { return nil }
            let norm = sqrt(profile.values.reduce(0) { $0 + $1 * $1 })
            guard norm > 0 else { return nil }
            self.profile = profile
            self.profileNorm = norm
            self.index = index
            var cs: [String: Centroid] = [:]
            for id in profile.keys {
                if let c = index.byId[id], let cen = Centroid(c, catalog: input.catalog) { cs[id] = cen }
            }
            self.centroids = cs
        }

        /// The membership vector the pull uses for `s` (hard everywhere, soft on the profile).
        func vector(_ s: Song, nowMs: Double) -> [String: Double] {
            var m = index.hard(s.id, refMs: nowMs)
            for (id, cen) in centroids where m[id] == nil {
                let sim = similarity(s, cen)
                if sim >= softMin { m[id] = softMax * sim }
            }
            return m
        }

        /// (cosine, the profile collection that contributed most) — nil when m(s) is empty.
        func cosine(_ s: Song, nowMs: Double) -> (Double, String?)? {
            let m = vector(s, nowMs: nowMs)
            guard !m.isEmpty else { return nil }
            let norm = sqrt(m.values.reduce(0) { $0 + $1 * $1 })
            guard norm > 0 else { return nil }
            var dot = 0.0
            var best: (String, Double)?
            for (id, p) in profile {
                guard let w = m[id] else { continue }
                dot += p * w
                if best == nil || p * w > best!.1 || (p * w == best!.1 && id < best!.0) { best = (id, p * w) }
            }
            guard dot > 0 else { return nil }
            return (dot / (norm * profileNorm), best?.0)
        }
    }
}
