import Foundation

/// What a pocket run LEARNS (§4.3 / §4.6): per-feature evidence from the run's own verdicts,
/// turned into score multipliers, an artist ban for the rest of the run, and a negative timbre
/// profile. Also the cross-run fold: evidence for a moment is DERIVED from the append-only play
/// history (every run play carries `pocketRun.momentKey`), so it survives relaunch, merges across
/// devices for free, and is erased with "Delete history". PURE.
enum PocketTuning {

    // MARK: Features

    /// The features a song is judged on. Built once per candidate by the planner's input builder.
    struct Features: Sendable, Equatable {
        var artistKeys: [String]
        var album: String?
        var genre: String?
        var year: Int?
        var bpm: Double?
        var collectionId: String?
        var timbre: SimilarityFamilies.TimbreVector?

        /// "artist:drake", "album:alb_1", "genre:r&b", "era:2015", "bpm:96", "collection:pl_x".
        var keys: [String] {
            var out = artistKeys.map { "artist:" + $0 }
            if let a = album { out.append("album:" + a) }
            if let g = genre { out.append("genre:" + g) }
            if let y = year, y > 0 { out.append("era:\(y / 5 * 5)") }
            if let b = InThePocketScorer.foldBpm(bpm) { out.append("bpm:\(Int(b) / 8 * 8)") }
            if let c = collectionId { out.append("collection:" + c) }
            return out
        }
    }

    /// One finished run row's verdict.
    struct Verdict: Sendable, Equatable {
        var songId: String
        var skipped: Bool
        var fraction: Double?
        var atMs: Double
        var momentKey: String
        var rowCollectionId: String?

        /// §4.3 signal strength: fast skip −1.0, skip −0.6, completed +0.5, partial +0.2.
        /// nil = no verdict yet (unknown fraction and not skipped).
        var strength: Double? {
            if skipped { return (fraction ?? 0) < 0.15 ? -1.0 : -0.6 }
            guard let f = fraction else { return nil }
            if f >= 0.9 { return 0.5 }
            if f >= 0.5 { return 0.2 }
            return -0.6   // advanced away under half without a skip flag = the SkipTracker rule
        }
    }

    /// Per-feature evidence sums.
    struct Evidence: Sendable, Equatable, Codable {
        var pos: [String: Double] = [:]
        var neg: [String: Double] = [:]
        /// Vectors of skipped rows (the run's NEGATIVE timbre profile).
        var skippedVectors: [[String: Double]] = []

        mutating func add(_ keys: [String], strength s: Double, scale: Double = 1, vector: SimilarityFamilies.TimbreVector? = nil) {
            for k in keys {
                if s > 0 { pos[k, default: 0] += s * scale } else { neg[k, default: 0] += -s * scale }
            }
            if s < 0, let v = vector, scale >= 1 { skippedVectors.append(v) }
        }
        mutating func merge(_ o: Evidence, scale: Double) {
            for (k, v) in o.pos { pos[k, default: 0] += v * scale }
            for (k, v) in o.neg { neg[k, default: 0] += v * scale }
        }
    }

    /// The multipliers a score is multiplied by, the ban list, and the negative sound.
    struct Multipliers: Sendable, Equatable {
        var byKey: [String: Double] = [:]
        var bannedArtists: Set<String> = []
        var negativeTimbre: SimilarityFamilies.TimbreProfile?

        static let neutral = Multipliers()

        /// Π multipliers over a song's features.
        func factor(_ f: Features) -> Double {
            var x = 1.0
            for k in f.keys { x *= byKey[k] ?? 1 }
            return x
        }
        func isBanned(_ f: Features) -> Bool { f.artistKeys.contains { bannedArtists.contains($0) } }
    }

    // MARK: Formulas

    static let banAtOrBelow = 0.35

    /// Artist / album: NEGATIVE evidence counts double. The §4.3 formula as printed
    /// (`2·(pos+0.5)/(pos+neg+1)`) gives 0.5 for one fast skip — contradicting its own worked
    /// example (0.33) and the ban rule ("one fast skip, or two ordinary skips" ⇒ ≤ 0.35). Doubling
    /// `neg` reproduces exactly the stated behaviour: 1 fast skip = 0.333, 2 ordinary skips =
    /// 0.294 (banned), 1 ordinary skip = 0.455 (not banned).
    static func artistMultiplier(pos: Double, neg: Double) -> Double {
        clamp(2 * (pos + 0.5) / (pos + 2 * neg + 1), 0.15, 1.6)
    }
    static func collectionMultiplier(pos: Double, neg: Double) -> Double {
        clamp(2 * (pos + 2) / (pos + neg + 4), 0.5, 1.4)
    }
    static func musicalMultiplier(pos: Double, neg: Double) -> Double {
        clamp(2 * (pos + 1) / (pos + neg + 2), 0.35, 1.5)
    }
    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, x)) }

    /// Evidence → multipliers. `allowBans` is true inside a run and FALSE across runs (W5: bans
    /// don't persist — a banned artist enters the next run at its multiplier, rare not forbidden).
    static func multipliers(_ e: Evidence, allowBans: Bool) -> Multipliers {
        var out = Multipliers()
        for k in Set(e.pos.keys).union(e.neg.keys) {
            let p = e.pos[k] ?? 0, n = e.neg[k] ?? 0
            let m: Double
            if k.hasPrefix("artist:") || k.hasPrefix("album:") { m = artistMultiplier(pos: p, neg: n) }
            else if k.hasPrefix("collection:") { m = collectionMultiplier(pos: p, neg: n) }
            else { m = musicalMultiplier(pos: p, neg: n) }
            out.byKey[k] = (m * 1000).rounded() / 1000
            if allowBans, k.hasPrefix("artist:"), m <= banAtOrBelow { out.bannedArtists.insert(String(k.dropFirst(7))) }
        }
        let vecs = e.skippedVectors.map { (vector: $0, weight: 1.0) }
        out.negativeTimbre = SimilarityFamilies.timbreProfile(vecs, minVectors: 1)
        return out
    }

    /// One run's evidence from its verdicts.
    static func runEvidence(_ verdicts: [Verdict], features: (String) -> Features?) -> Evidence {
        var e = Evidence()
        for v in verdicts {
            guard let s = v.strength, var f = features(v.songId) else { continue }
            if let c = v.rowCollectionId { f.collectionId = c }
            e.add(f.keys, strength: s, vector: f.timbre)
        }
        return e
    }

    // MARK: Cross-run fold (§4.6)

    static let foldHalfLifeDays = 30.0
    static let relatedScale = 0.5
    static let globalScale = 0.15

    /// Verdicts of every finished run play in history (optionally excluding one run — the live one).
    static func verdicts(from events: [PlayHistoryStore.PlayEvent], excludingRun: UUID? = nil,
                         excludingEvent: UUID? = nil) -> [(runId: UUID, verdict: Verdict)] {
        events.compactMap { e in
            guard let tag = e.pocketRun, tag.runId != excludingRun, e.id != excludingEvent else { return nil }
            return (tag.runId, Verdict(songId: SongVariant.baseId(e.songId), skipped: e.wasSkipped == true,
                                       fraction: e.listenedFraction, atMs: e.playedAt, momentKey: tag.momentKey,
                                       rowCollectionId: tag.rowCollectionId))
        }
    }

    /// Is moment `b` a smoothing-kernel neighbour of `a` (§1.6)?
    static func isRelated(_ a: PocketMomentKey, _ b: PocketMomentKey) -> Bool {
        guard a != b else { return false }
        let ha = (a.dow - 1) * 24 + a.hour, hb = (b.dow - 1) * 24 + b.hour
        let dh = min((ha - hb + 168) % 168, (hb - ha + 168) % 168)
        if a.mode == b.mode && dh <= 2 { return true }
        if a.mode == b.mode && a.hour == b.hour && a.isWeekend == b.isWeekend { return true }
        if a.hour == b.hour && a.dow == b.dow && a.mode.related == b.mode { return true }
        return false
    }

    /// The prior evidence a NEW run of `moment` starts with: own moment ×1, related ×0.5,
    /// everything ×0.15, each verdict decayed with a 30-day half-life.
    static func fold(verdicts: [Verdict], for moment: PocketMomentKey?, nowMs: Double,
                     features: (String) -> Features?) -> Evidence {
        var e = Evidence()
        for v in verdicts {
            guard let s = v.strength, var f = features(v.songId) else { continue }
            if let c = v.rowCollectionId { f.collectionId = c }
            let decay = pow(0.5, max(0, nowMs - v.atMs) / 86_400_000 / foldHalfLifeDays)
            var scale = globalScale
            if let m = moment, let k = PocketMomentKey(token: v.momentKey) {
                if k == m { scale = 1 } else if isRelated(m, k) { scale = relatedScale }
            }
            e.add(f.keys, strength: s, scale: scale * decay, vector: scale == 1 ? f.timbre : nil)
        }
        return e
    }
}
