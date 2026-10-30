import Foundation

/// What a pocket run is built FROM — one value for every cold-start tier (§3.3), so the run
/// planner has no special cases. Codable: it rides the run file so a relaunch mid-run keeps it.
struct PocketProfile: Codable, Equatable, Sendable {
    enum Tier: String, Codable, Sendable { case rich, neighbourhood, cloud, history, empty }

    var tier: Tier
    /// The winning moment (T0) — nil for blended / cloud / cold profiles.
    var key: PocketMomentKey?
    /// Every moment that contributed (the tuning fold reads these).
    var momentKeys: [PocketMomentKey] = []
    /// Line 1 / line 2 of the centre caption.
    var caption: String
    var detail: String
    /// Collection → weight (the DOMINANT feature). L1-normalised.
    var collections: [String: Double] = [:]
    var artists: [String: Double] = [:]
    var genres: [String: Double] = [:]
    var bpmLo: Double?
    var bpmHi: Double?
    var eraLo: Double?
    var eraHi: Double?
    var timbreCentroid: [String: Double]?
    var timbreSpread: Double?
    var timbreVectors: Int?
    /// songId → strength.
    var seeds: [String: Double] = [:]
    /// The cloud's `collectionCandidates` (songId → strength).
    var candidateBoost: [String: Double] = [:]
    /// The listening mode the profile is FOR (W7: `.mix` plays through Mix Auto-DJ).
    var mode: PocketMode?

    var dominantCollectionId: String? {
        collections.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
    }
    var bpmBand: ClosedRange<Double>? {
        guard let lo = bpmLo, let hi = bpmHi, hi >= lo else { return nil }
        return lo...hi
    }
    var era: SimilarityFamilies.EraWindow? {
        guard let lo = eraLo, let hi = eraHi else { return nil }
        return .init(lo: lo, hi: hi)
    }
    var timbre: SimilarityFamilies.TimbreProfile? {
        guard let c = timbreCentroid, let s = timbreSpread else { return nil }
        return .init(centroid: c, spread: s, vectors: timbreVectors ?? 0)
    }

    static func from(moment m: PocketMoment, names: [String: String], tier: Tier = .rich) -> PocketProfile {
        PocketProfile(tier: tier, key: m.key, momentKeys: [m.key], caption: m.key.shortLabel,
                      detail: PocketBestMatch.detail(collectionId: m.dominantCollectionId, plays: m.directPlays, names: names),
                      collections: m.collections, artists: m.artists, genres: m.genres,
                      bpmLo: m.bpmLo, bpmHi: m.bpmHi, eraLo: m.eraLo, eraHi: m.eraHi,
                      timbreCentroid: m.timbreCentroid, timbreSpread: m.timbreSpread, timbreVectors: m.timbreVectors,
                      seeds: m.seeds, mode: m.key.mode)
    }
}

/// The centre ▶ (§3): score every cell against NOW (time, day, mode, place, previous activity),
/// pick the best, and fall back through the cold-start tiers. PURE.
enum PocketBestMatch {

    struct Now: Sendable, Equatable {
        /// Local fractional hour and ISO weekday.
        var hour: Double
        var dow: Int
        /// nil = unknown (the surface modes aren't inferable while looking at the wheel).
        var mode: PocketMode?
        /// "place:…" / "trip:…" (PocketMomentEngine.contextKey), or nil.
        var ctx: String?
        /// Collection attribution of the last 45 min of plays (empty = none).
        var recentCollections: [String: Double] = [:]
        /// Skip rate over those plays (nil = none).
        var recentSkipRate: Double?

        var isWeekend: Bool { dow >= 6 }
    }

    struct Scored: Equatable, Sendable {
        var key: PocketMomentKey
        var match: Double
        var quality: Double
        var continuity: Double
        var score: Double
    }

    struct Result: Equatable, Sendable {
        var profile: PocketProfile
        var winner: Scored?
        /// Up to 3 runners-up with a DIFFERENT dominant collection.
        var alternatives: [PocketProfile]
    }

    /// Optional extra profiles for the cloud / empty tiers (the caller builds them; nil ⇒ skip).
    struct Fallbacks: Sendable {
        /// T2: `InThePocketScorer.cloudProfile`, converted (opt-in on + patterns match the bucket).
        var cloud: PocketProfile?
        /// T4: the most recently played collection, else Favorites, else For You's top tile.
        var empty: PocketProfile?
        /// Cloud patterns with round-learning `pocketRate ≥ 0.5` (×1.15 boost).
        var boostedPatternIds: Set<String> = []
        init(cloud: PocketProfile? = nil, empty: PocketProfile? = nil, boostedPatternIds: Set<String> = []) {
            self.cloud = cloud; self.empty = empty; self.boostedPatternIds = boostedPatternIds
        }
    }

    // MARK: Tuning

    static let richMinMatch = 0.35
    static let richMinPlays = 3.0
    static let neighbourhoodHours = 3.0
    static let neighbourhoodMinPlays = 5
    static let coldMinPlays = 20
    static let continuityWeight = 0.35
    static let cloudBoost = 1.15
    static let skipStreakRate = 0.5

    // MARK: Kernels (§3.2)

    static func circularHours(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 24)
        return min(d, 24 - d)
    }
    static func kt(_ now: Now, _ k: PocketMomentKey) -> Double {
        let dh = circularHours(now.hour, Double(k.hour) + 0.5)
        return exp(-dh * dh / 2)
    }
    static func kd(_ now: Now, _ k: PocketMomentKey) -> Double {
        if k.dow == now.dow { return 1 }
        return k.isWeekend == now.isWeekend ? 0.6 : 0.25
    }
    static func km(_ now: Now, _ k: PocketMomentKey) -> Double {
        guard let m = now.mode else { return 0.6 }
        if m == k.mode { return 1 }
        return m.related == k.mode ? 0.7 : 0.35
    }
    static func kl(_ now: Now, _ m: PocketMoment) -> Double {
        guard let ctx = now.ctx, !m.ctx.isEmpty else { return 1 }
        return 0.3 + 0.7 * (m.ctx[ctx] ?? 0)
    }
    static func quality(_ m: PocketMoment) -> Double {
        m.confidence * pow(1 - m.skipRate, 1.5) * (m.isRecurring ? 1 : 0.7)
    }
    static func cosine(_ a: [String: Double], _ b: [String: Double]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var dot = 0.0
        for (k, v) in a { dot += v * (b[k] ?? 0) }
        let na = sqrt(a.values.reduce(0) { $0 + $1 * $1 }), nb = sqrt(b.values.reduce(0) { $0 + $1 * $1 })
        return na > 0 && nb > 0 ? dot / (na * nb) : 0
    }

    static func score(_ m: PocketMoment, now: Now, boosted: Set<String>) -> Scored {
        let match = kt(now, m.key) * kd(now, m.key) * km(now, m.key) * kl(now, m)
        let q = quality(m)
        var cont = cosine(now.recentCollections, m.collections)
        if let r = now.recentSkipRate, r > skipStreakRate { cont = -cont }   // unhappy ⇒ steer away
        var s = match * (0.4 + 0.6 * q) + continuityWeight * cont * sqrt(match)
        if !boosted.isEmpty, m.cloudPatternIds.contains(where: boosted.contains) { s *= cloudBoost }
        return Scored(key: m.key, match: match, quality: q, continuity: cont, score: s)
    }

    // MARK: Best match + tiers

    static func best(snapshot: PocketWheelSnapshot, now: Now, fallbacks: Fallbacks = .init()) -> Result {
        let candidates = snapshot.moments.filter { $0.plays > 0 }
        let index = snapshot.index()
        let ranked = candidates.map { score($0, now: now, boosted: fallbacks.boostedPatternIds) }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                let a = index[$0.key]?.lastSeenMs ?? 0, b = index[$1.key]?.lastSeenMs ?? 0
                return a != b ? a > b : $0.key < $1.key
            }
        let names = snapshot.collectionNames

        func alternatives(excluding dominant: String?) -> [PocketProfile] {
            var seen: Set<String> = dominant.map { [$0] } ?? []
            var out: [PocketProfile] = []
            for s in ranked.dropFirst() {
                guard let m = index[s.key], let d = m.dominantCollectionId, !seen.contains(d) else { continue }
                seen.insert(d)
                out.append(PocketProfile.from(moment: m, names: names))
                if out.count == 3 { break }
            }
            return out
        }

        // T0 — a rich winner.
        if let w = ranked.first, let m = index[w.key], w.match >= richMinMatch, m.plays >= richMinPlays {
            return Result(profile: .from(moment: m, names: names), winner: w,
                          alternatives: alternatives(excluding: m.dominantCollectionId))
        }
        // T1 — the neighbourhood: same day type within ±3 h has ≥ 5 plays → blend the top 5.
        let near = candidates.filter {
            $0.key.isWeekend == now.isWeekend && circularHours(now.hour, Double($0.key.hour) + 0.5) <= neighbourhoodHours
        }
        if near.reduce(0, { $0 + $1.directPlays }) >= neighbourhoodMinPlays {
            let top = ranked.filter { s in near.contains { $0.key == s.key } }.prefix(5)
            let profile = blend(top.compactMap { s in index[s.key].map { ($0, max(s.score, 1e-6)) } },
                                tier: .neighbourhood, caption: neighbourhoodPhrase(now), names: names)
            return Result(profile: profile, winner: top.first, alternatives: alternatives(excluding: profile.dominantCollectionId))
        }
        // T2 — the cloud's listening pockets.
        if let cloud = fallbacks.cloud {
            return Result(profile: cloud, winner: nil, alternatives: [])
        }
        // T3 — the whole history, recency-weighted.
        if snapshot.totalDirectPlays >= coldMinPlays {
            let all = candidates.map { m -> (PocketMoment, Double) in
                (m, m.plays * exp(-max(0, snapshot.builtAtMs - m.lastSeenMs) / (30 * 86_400_000)))
            }.filter { $0.1 > 0 }
            let profile = blend(all, tier: .history, caption: "Your recent favourites", names: names)
            return Result(profile: profile, winner: nil, alternatives: alternatives(excluding: profile.dominantCollectionId))
        }
        // T4 — nothing.
        let empty = fallbacks.empty ?? PocketProfile(tier: .empty, caption: "Getting to know you",
                                                     detail: "Play for a week to paint your wheel")
        return Result(profile: empty, winner: nil, alternatives: [])
    }

    /// Weighted blend of moments into one profile (T1 / T3).
    static func blend(_ parts: [(PocketMoment, Double)], tier: PocketProfile.Tier, caption: String,
                      names: [String: String]) -> PocketProfile {
        var colls: [String: Double] = [:], artists: [String: Double] = [:], genres: [String: Double] = [:]
        var seeds: [String: Double] = [:]
        var bLo = 0.0, bHi = 0.0, bW = 0.0, eLo = 0.0, eHi = 0.0, eW = 0.0
        var timbreBest: (PocketMoment, Double)?
        var plays = 0
        var modeW: [PocketMode: Double] = [:]
        for (m, w) in parts {
            for (k, v) in m.collections { colls[k, default: 0] += w * v }
            for (k, v) in m.artists { artists[k, default: 0] += w * v }
            for (k, v) in m.genres { genres[k, default: 0] += w * v }
            for (k, v) in m.seeds { seeds[k, default: 0] += w * v }
            if let lo = m.bpmLo, let hi = m.bpmHi { bLo += w * lo; bHi += w * hi; bW += w }
            if let lo = m.eraLo, let hi = m.eraHi { eLo += w * lo; eHi += w * hi; eW += w }
            if m.timbreCentroid != nil, w > (timbreBest?.1 ?? 0) { timbreBest = (m, w) }
            plays += m.directPlays
            modeW[m.key.mode, default: 0] += w
        }
        var p = PocketProfile(tier: tier, key: nil, momentKeys: parts.map(\.0.key), caption: caption, detail: "",
                              collections: PocketMomentEngine.topNormalized(colls, 8),
                              artists: PocketMomentEngine.topNormalized(artists, 8),
                              genres: PocketMomentEngine.topNormalized(genres, 8),
                              seeds: PocketMomentEngine.topRaw(seeds, 60))
        if bW > 0 { p.bpmLo = (bLo / bW).rounded(); p.bpmHi = (bHi / bW).rounded() }
        if eW > 0 { p.eraLo = eLo / eW; p.eraHi = eHi / eW }
        if let t = timbreBest?.0 { p.timbreCentroid = t.timbreCentroid; p.timbreSpread = t.timbreSpread; p.timbreVectors = t.timbreVectors }
        p.mode = modeW.max { $0.value != $1.value ? $0.value < $1.value : $0.key.rank > $1.key.rank }?.key
        p.detail = detail(collectionId: p.dominantCollectionId, plays: plays, names: names)
        return p
    }

    /// "Potential · 23 plays".
    static func detail(collectionId: String?, plays: Int, names: [String: String]) -> String {
        let name = collectionId.flatMap { names[$0] } ?? "Mixed"
        return "\(name) · \(plays) \(plays == 1 ? "play" : "plays")"
    }

    /// "Weekday mornings" / "Weekend evenings".
    static func neighbourhoodPhrase(_ now: Now) -> String {
        let bucket = InThePocketContext.timeBucket(hour: now.hour)
        let plural: String
        switch bucket {
        case "morning": plural = "mornings"
        case "midday": plural = "middays"
        case "afternoon": plural = "afternoons"
        case "evening": plural = "evenings"
        default: plural = "nights"
        }
        return (now.isWeekend ? "Weekend " : "Weekday ") + plural
    }

    /// `mode_now` (§3.1): CarPlay connected → carPlay; running/walking in the last 5 min → that;
    /// automotive or a trip guess → trip; else unknown.
    static func modeNow(carPlayConnected: Bool, motion: String?, contextGuess: ListeningContextTag?) -> PocketMode? {
        if carPlayConnected { return .carPlay }
        if motion == MotionToken.running { return .running }
        if motion == MotionToken.walking { return .walking }
        if motion == MotionToken.automotive || motion == MotionToken.cycling || contextGuess?.isTrip == true { return .trip }
        return nil
    }

    /// The previous-activity inputs (§3.1) from the last 45 minutes of plays.
    static func recentActivity(events: [PlayHistoryStore.PlayEvent], nowMs: Double,
                               attribute: (PlayHistoryStore.PlayEvent) -> [String: Double],
                               windowMs: Double = 45 * 60_000) -> (collections: [String: Double], skipRate: Double?) {
        var colls: [String: Double] = [:]
        var n = 0, skips = 0
        for e in events.reversed() {
            if nowMs - e.playedAt > windowMs { break }
            guard e.source != .game, e.playedAt <= nowMs else { continue }
            n += 1
            if e.wasSkipped == true { skips += 1; continue }
            for (k, v) in attribute(e) { colls[k, default: 0] += v }
        }
        return (colls, n > 0 ? Double(skips) / Double(n) : nil)
    }

    /// Convert the cloud scorer's profile (T2) — exactly `InThePocketScorer`'s `.cloud` builder.
    static func cloudProfile(_ p: InThePocketScorer.Profile) -> PocketProfile {
        var artists: [String: Double] = [:], genres: [String: Double] = [:]
        for t in p.targets {
            if t.dim == "artist" { artists[t.value] = t.weight }
            if t.dim == "genre" { genres[t.value] = t.weight }
        }
        return PocketProfile(tier: .cloud, caption: "From your listening pockets", detail: "Patterns the cloud found",
                             collections: PocketMomentEngine.topNormalized(p.membership, 8),
                             artists: PocketMomentEngine.topNormalized(artists, 8),
                             genres: PocketMomentEngine.topNormalized(genres, 8),
                             bpmLo: p.bpmBand?.lowerBound, bpmHi: p.bpmBand?.upperBound,
                             seeds: p.seedSongs, candidateBoost: p.candidateBoost)
    }
}
