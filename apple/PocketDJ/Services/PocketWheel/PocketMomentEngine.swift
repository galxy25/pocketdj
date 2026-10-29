import Foundation

/// One wheel cell (§1.6): what listening at (hour, weekday, mode) looks like, built from local
/// play history. Codable so the whole wheel persists as a device-local cache and paints instantly.
struct PocketMoment: Codable, Equatable, Sendable, Identifiable {
    var key: PocketMomentKey
    var id: PocketMomentKey { key }
    /// Decayed, kernel-weighted count of NON-skipped plays.
    var plays: Double = 0
    /// Decayed, kernel-weighted count of skips (run skips at 1×).
    var skips: Double = 0
    /// Distinct local dates contributing DIRECTLY (not via smoothing), non-skipped.
    var distinctDays: Int = 0
    /// Raw direct counts — the captions' "23 plays" / "4 % skips".
    var directPlays: Int = 0
    var directSkips: Int = 0
    /// §1.5 collection weights from non-skipped plays (L1-normalised, top 8).
    var collections: [String: Double] = [:]
    /// argmax of `collections` when its share ≥ 0.25, else nil ("mixed").
    var dominantCollectionId: String?
    var artists: [String: Double] = [:]
    var genres: [String: Double] = [:]
    /// p25–p75 of folded BPM (≥ 3 songs).
    var bpmLo: Double?
    var bpmHi: Double?
    /// The era window (SimilarityFamilies.eraWindow) of the cell's played-through songs.
    var eraLo: Double?
    var eraHi: Double?
    /// The cell's timbre profile (played-through members with vectors), flattened for Codable.
    var timbreCentroid: [String: Double]?
    var timbreSpread: Double?
    var timbreVectors: Int?
    /// place/trip key distribution ("none" included).
    var ctx: [String: Double] = [:]
    /// songId → strength (played through here), top 40.
    var seeds: [String: Double] = [:]
    /// Cloud listening-pocket patterns whose time bucket + day type overlap this cell.
    var cloudPatternIds: [String] = []
    var lastSeenMs: Double = 0

    init(key: PocketMomentKey) { self.key = key }

    var confidence: Double { 1 - exp(-plays / 6) }
    var skipRate: Double { plays + skips > 0 ? skips / (plays + skips) : 0 }
    var isRecurring: Bool { distinctDays >= 2 }
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
}

/// The whole wheel: every non-empty moment + the colour/legend aggregates.
struct PocketWheelSnapshot: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var builtAtMs: Double = 0
    /// `PlayHistoryStore.revision` this was built from (cache validity).
    var historyRevision: Int = -1
    var moments: [PocketMoment] = []
    /// Collection id → display name (local only).
    var collectionNames: [String: String] = [:]
    /// Every collection dominant in ≥ 1 cell, by global dominance DESCENDING — the palette's
    /// seating order.
    var dominanceOrder: [String] = []
    /// Legend: collection → share of the week's (decayed) plays in cells it dominates.
    var weekShare: [String: Double] = [:]
    /// Non-skipped, non-game plays the build saw (for cold-start tiers).
    var totalDirectPlays: Int = 0

    var isEmpty: Bool { moments.isEmpty }

    func index() -> [PocketMomentKey: PocketMoment] {
        Dictionary(moments.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }
    func name(_ id: String?) -> String? { id.flatMap { collectionNames[$0] } }
}

/// The pure moment builder (§1.3 / §1.5 / §1.6). O(events × kernel) + O(cells); runs off-main.
enum PocketMomentEngine {

    // MARK: Tuning (one place)

    static let halfLifeDays = 45.0
    static let runPlayFactor = 0.5
    static let kernelHour1 = 0.5
    static let kernelHour2 = 0.15
    static let kernelSameDayType = 0.25
    static let kernelRelatedMode = 0.3
    static let dominantMinShare = 0.25
    static let topCollections = 8
    static let topFeatures = 8
    static let topSeeds = 40
    static let fallbackWeight = 0.5
    static let megaMaxSongs = 3_000
    static let megaMaxLibraryShare = 0.25
    static let addHalfLifeDays = 45.0
    static let unknownAddScale = 0.75

    // MARK: Input

    struct SongInfo: Sendable, Equatable {
        var artist: String
        var genre: String?
        var bpm: Double?
        var year: Int?
        var timbre: SimilarityFamilies.TimbreVector?
        init(artist: String, genre: String? = nil, bpm: Double? = nil, year: Int? = nil,
             timbre: SimilarityFamilies.TimbreVector? = nil) {
            self.artist = artist; self.genre = genre; self.bpm = bpm; self.year = year; self.timbre = timbre
        }
    }

    struct CollectionInfo: Sendable, Equatable {
        var id: String
        var name: String
        var songIds: Set<String>
        /// songId → epoch ms last added (absent ⇒ unknown).
        var addedAtMs: [String: Double] = [:]
        init(id: String, name: String, songIds: Set<String>, addedAtMs: [String: Double] = [:]) {
            self.id = id; self.name = name; self.songIds = songIds; self.addedAtMs = addedAtMs
        }
    }

    struct CloudPatternRef: Sendable, Equatable {
        var id: String
        var timeBucket: String?
        var dayType: String?
    }

    struct Input: Sendable {
        var events: [PlayHistoryStore.PlayEvent]
        var collections: [CollectionInfo] = []
        var songs: [String: SongInfo] = [:]
        /// Setlist id → its playlist id (§1.5: setlist origins resolve to their playlist).
        var setlistToPlaylist: [String: String] = [:]
        /// Extra names (source playlists too big to carry membership, reserved ids …).
        var extraNames: [String: String] = [:]
        /// Playable library size — the mega-collection threshold's denominator.
        var librarySize: Int = 0
        var nowMs: Double
        var historyRevision: Int = -1
        var cloudPatterns: [CloudPatternRef] = []

        init(events: [PlayHistoryStore.PlayEvent], collections: [CollectionInfo] = [],
             songs: [String: SongInfo] = [:], setlistToPlaylist: [String: String] = [:],
             extraNames: [String: String] = [:], librarySize: Int = 0, nowMs: Double,
             historyRevision: Int = -1, cloudPatterns: [CloudPatternRef] = []) {
            self.events = events; self.collections = collections; self.songs = songs
            self.setlistToPlaylist = setlistToPlaylist; self.extraNames = extraNames
            self.librarySize = librarySize; self.nowMs = nowMs; self.historyRevision = historyRevision
            self.cloudPatterns = cloudPatterns
        }
    }

    /// Song → hard memberships, with the mega flag precomputed.
    struct MembershipIndex: Sendable {
        var bySong: [String: [(id: String, m: Double)]] = [:]
        var known: Set<String> = []
        var mega: Set<String> = []

        init(_ input: Input, onlySongs wanted: Set<String>) {
            let libraryCap = input.librarySize > 0 ? Double(input.librarySize) * PocketMomentEngine.megaMaxLibraryShare
                                                   : Double.infinity
            for c in input.collections {
                known.insert(c.id)
                if c.songIds.count > PocketMomentEngine.megaMaxSongs || Double(c.songIds.count) > libraryCap {
                    mega.insert(c.id)
                    continue   // mega collections never enter the fallback — skip their members
                }
                for s in c.songIds where wanted.contains(s) {
                    bySong[s, default: []].append((c.id, PocketMomentEngine.membershipScale(c.addedAtMs[s], nowMs: input.nowMs)))
                }
            }
        }
    }

    /// Hard membership with add-time recency: 0.5 + 0.5·e^(−age/45 d); unknown add time ⇒ 0.75.
    static func membershipScale(_ addedAtMs: Double?, nowMs: Double) -> Double {
        guard let t = addedAtMs else { return unknownAddScale }
        let ageDays = max(0, nowMs - t) / 86_400_000
        return 0.5 + 0.5 * exp(-ageDays / addHalfLifeDays)
    }

    // MARK: Attribution (§1.5)

    /// The sparse collection weights of one play: its ORIGIN at 1.0, else 0.5 spread over its
    /// hard (non-mega) memberships ∝ m(s). Soft membership is never used for colour.
    static func attribution(_ e: PlayHistoryStore.PlayEvent, input: Input, index: MembershipIndex) -> [String: Double] {
        if let origin = origin(of: e, input: input, index: index) { return [origin: 1] }
        let song = SongVariant.baseId(e.songId)
        guard let ms = index.bySong[song], !ms.isEmpty else { return [:] }
        let total = ms.reduce(0) { $0 + $1.m }
        guard total > 0 else { return [:] }
        var out: [String: Double] = [:]
        for (id, m) in ms { out[id, default: 0] += fallbackWeight * m / total }
        return out
    }

    /// The first real collection among the run row's collection, the captured origin, and the
    /// context id; setlists resolve to their playlist.
    static func origin(of e: PlayHistoryStore.PlayEvent, input: Input, index: MembershipIndex) -> String? {
        func resolve(_ id: String?) -> String? {
            guard let id, !id.isEmpty else { return nil }
            if let pl = input.setlistToPlaylist[id] { return pl }
            if index.known.contains(id) || input.extraNames[id] != nil { return id }
            if id == PocketWheelIds.favorites { return id }
            return nil
        }
        if let r = e.pocketRun?.rowCollectionId, let id = resolve(r) ?? r.nilIfEmpty { return id }
        if let o = e.originCollectionId, let id = resolve(o) ?? o.nilIfEmpty { return id }
        return resolve(e.contextId)
    }

    // MARK: Build

    private struct Acc {
        var plays = 0.0, skips = 0.0
        var directPlays = 0, directSkips = 0
        var days = Set<Int>()
        var collections: [String: Double] = [:]
        var artists: [String: Double] = [:]
        var artistLabels: [String: String] = [:]
        var genres: [String: Double] = [:]
        var bpms: [(Double, Double)] = []
        var bpmSongs = Set<String>()
        var years: [Double] = []
        var timbre: [String: (SimilarityFamilies.TimbreVector, Double)] = [:]
        var ctx: [String: Double] = [:]
        var seeds: [String: Double] = [:]
        var lastSeen = 0.0
    }

    static let modeCount = PocketMode.precedence.count
    @inline(__always) static func cellIndex(howIndex: Int, mode: PocketMode) -> Int { howIndex * modeCount + mode.rank }

    static func build(_ input: Input) -> PocketWheelSnapshot {
        let events = input.events.filter { $0.source != .game }
        let wanted = Set(events.map { SongVariant.baseId($0.songId) })
        let index = MembershipIndex(input, onlySongs: wanted)
        let defaultTz = mostCommonOffset(events)
        var acc = [Acc?](repeating: nil, count: 168 * modeCount)
        var totalDirect = 0

        for e in events {
            guard let mode = PocketMode.derive(e) else { continue }
            let tz = e.tzOffsetMin ?? defaultTz
            let local = PocketClock.local(atMs: e.playedAt, tzOffsetMin: tz)
            let how = (local.dow - 1) * 24 + local.hour
            let ageDays = max(0, input.nowMs - e.playedAt) / 86_400_000
            let w = pow(0.5, ageDays / halfLifeDays)
            let isRun = e.pocketRun != nil
            let skipped = e.wasSkipped == true
            let song = SongVariant.baseId(e.songId)
            let info = input.songs[song]
            let attr = skipped ? [:] : attribution(e, input: input, index: index)
            let ctxKey = contextKey(e.listeningContext)
            if !skipped { totalDirect += 1 }

            for (cellHow, cellMode, kappa, direct) in kernel(how: how, dow: local.dow, hour: local.hour, mode: mode) {
                let ci = cellIndex(howIndex: cellHow, mode: cellMode)
                var a = acc[ci] ?? Acc()
                let c = w * kappa
                if skipped {
                    a.skips += c
                    if direct { a.directSkips += 1 }
                } else {
                    let pc = c * (isRun ? runPlayFactor : 1)
                    a.plays += pc
                    for (cid, aw) in attr { a.collections[cid, default: 0] += pc * aw }
                    if let info {
                        let ak = info.artist.lowercased()
                        a.artists[ak, default: 0] += pc
                        if a.artistLabels[ak] == nil { a.artistLabels[ak] = info.artist }
                        if let g = info.genre { a.genres[g, default: 0] += pc }
                        if kappa >= 0.25 {
                            if let b = InThePocketScorer.foldBpm(info.bpm) { a.bpms.append((b, pc)); a.bpmSongs.insert(song) }
                            if let y = info.year, y > 0 { a.years.append(Double(y)) }
                        }
                        if kappa >= 0.5, let v = info.timbre {
                            a.timbre[song] = (v, (a.timbre[song]?.1 ?? 0) + pc)
                        }
                    }
                    a.ctx[ctxKey, default: 0] += pc
                    if kappa >= 0.5 { a.seeds[song, default: 0] += pc }
                    if direct {
                        a.directPlays += 1
                        a.days.insert(local.dayIndex)
                    }
                }
                if direct { a.lastSeen = max(a.lastSeen, e.playedAt) }
                acc[ci] = a
            }
        }

        // Finalise.
        var moments: [PocketMoment] = []
        var names: [String: String] = input.extraNames
        for c in input.collections { names[c.id] = c.name }
        names[PocketWheelIds.favorites] = names[PocketWheelIds.favorites] ?? PocketWheelIds.favoritesName
        var dominance: [String: Double] = [:]
        var dominantPlays: [String: Double] = [:]
        var totalPlays = 0.0
        for (ci, maybe) in acc.enumerated() {
            guard let a = maybe, a.plays > 0 || a.skips > 0 else { continue }
            let how = ci / modeCount
            let mode = PocketMode.precedence[ci % modeCount]
            var m = PocketMoment(key: PocketMomentKey(hour: how % 24, dow: how / 24 + 1, mode: mode))
            m.plays = round6(a.plays)
            m.skips = round6(a.skips)
            m.directPlays = a.directPlays
            m.directSkips = a.directSkips
            m.distinctDays = a.days.count
            m.collections = topNormalized(a.collections, topCollections)
            if let best = m.collections.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
               best.value >= dominantMinShare {
                m.dominantCollectionId = best.key
                dominance[best.key, default: 0] += a.plays * best.value
                dominantPlays[best.key, default: 0] += a.plays
            }
            totalPlays += a.plays
            m.artists = topNormalized(a.artists, topFeatures)
            m.genres = topNormalized(a.genres, topFeatures)
            if a.bpmSongs.count >= 3 {
                m.bpmLo = weightedPercentile(a.bpms, 0.25).rounded()
                m.bpmHi = weightedPercentile(a.bpms, 0.75).rounded()
            }
            if let era = SimilarityFamilies.eraWindow(years: a.years) { m.eraLo = era.lo; m.eraHi = era.hi }
            if let tp = SimilarityFamilies.timbreProfile(a.timbre.values.map { (vector: $0.0, weight: $0.1) }) {
                m.timbreCentroid = tp.centroid; m.timbreSpread = tp.spread; m.timbreVectors = tp.vectors
            }
            m.ctx = topNormalized(a.ctx, topFeatures)
            m.seeds = topRaw(a.seeds, topSeeds)
            m.lastSeenMs = a.lastSeen
            m.cloudPatternIds = cloudPatterns(for: m.key, input.cloudPatterns)
            moments.append(m)
        }
        moments.sort { $0.key < $1.key }
        let order = dominance.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        var share: [String: Double] = [:]
        if totalPlays > 0 { for (id, p) in dominantPlays { share[id] = round6(p / totalPlays) } }
        var referenced = Set(order)
        for m in moments { referenced.formUnion(m.collections.keys) }
        return PocketWheelSnapshot(builtAtMs: input.nowMs, historyRevision: input.historyRevision,
                                   moments: moments,
                                   collectionNames: names.filter { referenced.contains($0.key) },
                                   dominanceOrder: order, weekShare: share, totalDirectPlays: totalDirect)
    }

    /// The smoothing kernel (§1.6): (hourOfWeek, mode, weight, isDirect) credits for one play.
    static func kernel(how: Int, dow: Int, hour: Int, mode: PocketMode) -> [(Int, PocketMode, Double, Bool)] {
        var out: [(Int, PocketMode, Double, Bool)] = [(how, mode, 1, true)]
        for (dh, k) in [(-1, kernelHour1), (1, kernelHour1), (-2, kernelHour2), (2, kernelHour2)] {
            out.append((((how + dh) % 168 + 168) % 168, mode, k, false))
        }
        let weekend = dow >= 6
        for d in 1...7 where d != dow && (d >= 6) == weekend {
            out.append(((d - 1) * 24 + hour, mode, kernelSameDayType, false))
        }
        if let r = mode.related { out.append((how, r, kernelRelatedMode, false)) }
        return out
    }

    static func cloudPatterns(for key: PocketMomentKey, _ patterns: [CloudPatternRef]) -> [String] {
        guard !patterns.isEmpty else { return [] }
        let bucket = InThePocketContext.timeBucket(hour: Double(key.hour) + 0.5)
        let dayType = key.isWeekend ? "weekend" : "weekday"
        return patterns.filter { ($0.timeBucket == nil || $0.timeBucket == bucket) && ($0.dayType == nil || $0.dayType == dayType) }
            .map(\.id).sorted()
    }

    static func contextKey(_ tag: ListeningContextTag?) -> String {
        guard let tag else { return "none" }
        if tag.isTrip, let t = tag.tripId { return "trip:\(t)" }
        if tag.isPlace, let p = tag.placeId { return "place:\(p)" }
        return "none"
    }

    static func mostCommonOffset(_ events: [PlayHistoryStore.PlayEvent]) -> Int {
        var counts: [Int: Int] = [:]
        for e in events { if let tz = e.tzOffsetMin { counts[tz, default: 0] += 1 } }
        return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? 0
    }

    static func topNormalized(_ m: [String: Double], _ n: Int) -> [String: Double] {
        let top = m.filter { $0.value > 0 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(n)
        let total = top.reduce(0) { $0 + $1.value }
        guard total > 0 else { return [:] }
        return Dictionary(uniqueKeysWithValues: top.map { ($0.key, round6($0.value / total)) })
    }

    static func topRaw(_ m: [String: Double], _ n: Int) -> [String: Double] {
        let top = m.filter { $0.value > 0 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(n)
        return Dictionary(uniqueKeysWithValues: top.map { ($0.key, round6($0.value)) })
    }

    static func weightedPercentile(_ values: [(Double, Double)], _ p: Double) -> Double {
        let sorted = values.sorted { $0.0 < $1.0 }
        let total = sorted.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return sorted.first?.0 ?? 0 }
        var run = 0.0
        for (v, w) in sorted {
            run += w
            if run >= p * total { return v }
        }
        return sorted.last?.0 ?? 0
    }

    /// Six-decimal rounding keeps cache bytes and the cross-platform goldens stable.
    static func round6(_ x: Double) -> Double { (x * 1_000_000).rounded() / 1_000_000 }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
