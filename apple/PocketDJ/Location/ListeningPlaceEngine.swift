import Foundation

// ─────────────────────────────────────────────────────────────────────────────────────────────
// LISTENING PLACE ENGINE — the pure, platform-neutral core of the on-device location context.
//
// Plain Doubles + Dates in, opaque ids out: no CoreLocation here, so every rule (clustering,
// merge, trips, lookup, ranks, prune) is unit-testable on iOS AND macOS with synthetic visits.
// `ListeningLocationStore` persists one of these and feeds it from `CoreLocationVisitSource`.
//
// Privacy shape of the persisted state: place CENTROIDS (rounded to `centroidDecimals`) and raw
// visit samples (kept `rawRetentionDays`) are the ONLY coordinates. The timeline, trip table and
// aliases hold ids + times only. None of it ever leaves the device — only the opaque ids that
// `lookup` hands out are stamped onto plays.
// ─────────────────────────────────────────────────────────────────────────────────────────────

/// One CLVisit, de-CoreLocation'd.
struct LocationVisitSample: Codable, Equatable {
    var latitude: Double; var longitude: Double; var horizontalAccuracy: Double
    /// nil = CLVisit `distantPast` (arrival unknown).
    var arrival: Date?
    /// nil = CLVisit `distantFuture` (still there).
    var departure: Date?
}

/// A significant-change fix — used only as an early DEPARTURE hint (CLVisit departures arrive
/// late). Never stored.
struct LocationFixSample: Codable, Equatable {
    var latitude: Double; var longitude: Double; var horizontalAccuracy: Double; var at: Date
}

struct ListeningPlaceEngine: Codable {

    /// ONE place for every knob. Not persisted — a build with new defaults applies them to the
    /// existing state on the next launch.
    struct Params {
        var maxAccuracyM = 200.0          // drop worse visits (they would mis-cluster places)
        /// Movement hints are significant-change fixes — mostly cell-based, hundreds of metres to
        /// kilometres. They only ever CLOSE a stay, and only when farther than radius + accuracy,
        /// so a coarse fix is safe; the 200 m visit bound would discard nearly all of them.
        var maxMovementAccuracyM = 3_000.0
        var placeRadiusM = 150.0          // visit joins nearest place within this
        var mergeRadiusM = 100.0          // two places whose centroids drift this close merge
        var minVisitDwell: TimeInterval = 5 * 60
        var minDwellForLabel: TimeInterval = 60 * 60     // over the rank window
        var rankWindowDays = 60.0
        var maxTripDuration: TimeInterval = 4 * 60 * 60  // longer gap between dwells = no trip
        var minTripOccurrencesForLabel = 2
        var rawRetentionDays = 30.0       // raw visit samples (the only coordinates besides centroids)
        var timelineRetentionDays = 180.0 // dwell segments (ids + times, NO coordinates)
        var placeRetentionDays = 180.0    // places unseen this long are deleted (+ their aliases)
        var centroidDecimals = 4          // ~11 m; centroids are stored rounded
        /// A re-delivered CLVisit whose arrival is within this of an existing segment's start (same
        /// place) updates that segment instead of opening a second one.
        var segmentMatchTolerance: TimeInterval = 15 * 60
    }

    /// A clustered dwell location. The id is minted once and never changes; the centroid drifts
    /// (dwell-weighted mean of its visits) and is stored ROUNDED.
    struct Place: Codable, Equatable {
        var id: String
        var latitude: Double
        var longitude: Double
        /// Dwell seconds behind the centroid's weighted mean.
        var weight: Double
        var createdAt: Date
        var lastSeenAt: Date
    }

    /// One stay at a place. No coordinates. `end == nil` = still there (runs to now).
    struct DwellSegment: Codable, Equatable {
        var placeId: String
        var start: Date
        var end: Date?
        /// `end` is a GUESS, not a CLVisit departure: the next stay's arrival clamped an open stay
        /// (`normalizeTimeline`), or a movement hint closed it (`noteMovement`). The real
        /// departure — back-dated, often hours late — may still move it EARLIER, so a recent time
        /// inside the stay isn't settled yet (see `lookup`). nil/false = a reported departure (and
        /// every segment persisted before this field existed).
        var endIsEstimate: Bool? = nil

        init(placeId: String, start: Date, end: Date?, endIsEstimate: Bool? = nil) {
            self.placeId = placeId; self.start = start; self.end = end; self.endIsEstimate = endIsEstimate
        }

        /// Still open, or closed only by a guess.
        var endIsProvisional: Bool { end == nil || endIsEstimate == true }
    }

    /// A raw CLVisit as received, kept `rawRetentionDays` (re-clustering headroom + dedupe of
    /// CoreLocation's redeliveries).
    struct StoredVisit: Codable, Equatable {
        var visit: LocationVisitSample
        var receivedAt: Date
    }

    var params = Params()
    private(set) var places: [Place] = []
    /// Sorted by start, non-overlapping (see `normalizeTimeline`).
    private(set) var timeline: [DwellSegment] = []
    private(set) var rawVisits: [StoredVisit] = []
    /// `"<origin>><destination>"` (or `"<origin>>?"` for a departure that never arrived) → `trp_…`.
    /// Minted the FIRST time an ordered pair is seen and reused forever after, which is what makes
    /// a recurring same-direction trip one stable id (and A→B ≠ B→A).
    private(set) var tripIds: [String: String] = [:]
    /// Merged-away id → survivor id (places AND trips), so tags already written still resolve.
    private(set) var aliases: [String: String] = [:]
    /// Set when the user turns location on; lookups before it are `.unavailable`.
    var trackingStartedAt: Date?

    init(params: Params = Params()) { self.params = params }

    enum CodingKeys: String, CodingKey { case places, timeline, rawVisits, tripIds, aliases, trackingStartedAt }

    /// Lenient: a field that fails to decode resets to empty instead of failing the document.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        places = (try? c.decodeIfPresent([Place].self, forKey: .places)) ?? []
        timeline = (try? c.decodeIfPresent([DwellSegment].self, forKey: .timeline)) ?? []
        rawVisits = (try? c.decodeIfPresent([StoredVisit].self, forKey: .rawVisits)) ?? []
        tripIds = (try? c.decodeIfPresent([String: String].self, forKey: .tripIds)) ?? [:]
        aliases = (try? c.decodeIfPresent([String: String].self, forKey: .aliases)) ?? [:]
        trackingStartedAt = (try? c.decodeIfPresent(Date.self, forKey: .trackingStartedAt)) ?? nil
        normalizeTimeline()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(places, forKey: .places)
        try c.encode(timeline, forKey: .timeline)
        try c.encode(rawVisits, forKey: .rawVisits)
        try c.encode(tripIds, forKey: .tripIds)
        try c.encode(aliases, forKey: .aliases)
        try c.encodeIfPresent(trackingStartedAt, forKey: .trackingStartedAt)
    }

    static let placePrefix = "plc_"
    static let tripPrefix = "trp_"

    /// 16 random lowercase hex — the opaque suffix of every place/trip id. `newId` closures
    /// return THIS (the engine adds the `plc_`/`trp_` prefix).
    static func randomHex16() -> String {
        let s = String(UInt64.random(in: .min ... .max), radix: 16)
        return String(repeating: "0", count: max(0, 16 - s.count)) + s
    }

    // MARK: - Ingest

    /// Fold one CLVisit in: cluster it into a place, open/close its dwell segment, merge places
    /// that drifted together, mint ids for any new trip pairs, prune.
    mutating func ingest(_ v: LocationVisitSample, now: Date,
                         newId: () -> String = ListeningPlaceEngine.randomHex16) {
        guard v.latitude.isFinite, v.longitude.isFinite,
              v.horizontalAccuracy >= 0, v.horizontalAccuracy <= params.maxAccuracyM else { return }
        guard v.arrival != nil || v.departure != nil else { return }   // nothing to anchor in time
        var dwell: TimeInterval = 0
        if let a = v.arrival, let d = v.departure {
            dwell = d.timeIntervalSince(a)
            guard dwell >= params.minVisitDwell else { return }
        }
        // CoreLocation redelivers visits (relaunch, duplicate callbacks): an identical sample is
        // already counted — re-adding it would double its weight.
        guard !rawVisits.contains(where: { $0.visit == v }) else { return }
        rawVisits.append(StoredVisit(visit: v, receivedAt: now))

        let seen = v.departure ?? now
        let placeId: String
        if let i = nearestPlaceIndex(latitude: v.latitude, longitude: v.longitude, within: params.placeRadiusM) {
            if dwell > 0 {
                let w = places[i].weight
                places[i].latitude = roundCoord((places[i].latitude * w + v.latitude * dwell) / (w + dwell))
                places[i].longitude = roundCoord((places[i].longitude * w + v.longitude * dwell) / (w + dwell))
                places[i].weight = w + dwell
            }
            places[i].lastSeenAt = max(places[i].lastSeenAt, seen)
            placeId = places[i].id
        } else {
            placeId = Self.placePrefix + newId()
            places.append(Place(id: placeId, latitude: roundCoord(v.latitude), longitude: roundCoord(v.longitude),
                                weight: dwell, createdAt: v.arrival ?? now, lastSeenAt: seen))
        }

        upsertSegment(placeId: placeId, arrival: v.arrival, departure: v.departure)
        mergeNearbyPlaces()
        normalizeTimeline()
        ensureTripIds(newId: newId)
        prune(now: now)
    }

    /// A significant-change fix far enough from the open segment's place closes that segment at
    /// the fix time — the early departure hint (the CLVisit departure lands later and, being
    /// back-dated to the real departure, overwrites it).
    mutating func noteMovement(_ f: LocationFixSample, now: Date,
                               newId: () -> String = ListeningPlaceEngine.randomHex16) {
        guard f.latitude.isFinite, f.longitude.isFinite,
              f.horizontalAccuracy >= 0, f.horizontalAccuracy <= params.maxMovementAccuracyM else { return }
        guard let i = timeline.indices.last, timeline[i].end == nil, f.at > timeline[i].start,
              let place = places.first(where: { $0.id == timeline[i].placeId }) else { return }
        let d = Self.distanceM(place.latitude, place.longitude, f.latitude, f.longitude)
        guard d > params.placeRadiusM + f.horizontalAccuracy else { return }
        timeline[i].end = f.at
        timeline[i].endIsEstimate = true   // the departure was AT OR BEFORE the fix — not exactly at it
        ensureTripIds(newId: newId)
    }

    // MARK: - Lookup

    /// What was the context at `t`? See `ListeningContextLookup` and the rules in the design spec
    /// (§3.2). INVARIANT: a `t` older than `pendingHorizon` before `now` is never `.pending`.
    func lookup(at t: Date, now: Date) -> ListeningContextLookup {
        guard let started = trackingStartedAt, t >= started else { return .unavailable }
        guard t >= now.addingTimeInterval(-params.timelineRetentionDays * 86_400) else { return .unavailable }
        let recent = now.timeIntervalSince(t) < ListeningContextConstants.pendingHorizon
        // Nothing claims `t` yet: a back-dated CLVisit still could while `t` is recent.
        let unresolved: ListeningContextLookup = recent ? .pending : .settled(.none)

        guard let i = lastSegmentIndex(startingAtOrBefore: t) else { return unresolved }
        let seg = timeline[i]
        guard let end = seg.end, t > end else {
            // Inside a stay whose end isn't REPORTED yet (still open, or clamped by a guess): the
            // CLVisit departure lands late and back-dated, so a recent `t` may turn out to be on
            // the trip out. Settling is write-once, so wait — past the horizon it's the place.
            if seg.endIsProvisional && recent { return .pending }
            return .settled(.place(seg.placeId))
        }
        let sinceDeparture = t.timeIntervalSince(end)

        if i + 1 < timeline.count {
            let next = timeline[i + 1]
            if next.start.timeIntervalSince(end) <= params.maxTripDuration {
                return tripTag(origin: seg.placeId, destination: next.placeId).map { .settled($0) } ?? unresolved
            }
            if sinceDeparture <= params.maxTripDuration {
                return tripTag(origin: seg.placeId, destination: nil).map { .settled($0) } ?? unresolved
            }
            return unresolved
        }
        // Departed and not (yet) arrived anywhere.
        if now.timeIntervalSince(end) < params.maxTripDuration {
            return recent ? .pending : .settled(.none)   // `recent` always holds here; kept for the invariant
        }
        if sinceDeparture <= params.maxTripDuration {
            return tripTag(origin: seg.placeId, destination: nil).map { .settled($0) } ?? unresolved
        }
        return unresolved
    }

    // MARK: - Labels

    /// Places ranked by share of dwell time over the rank window, only those with at least
    /// `minDwellForLabel`. Ranks are computed per call (ids stay put; letters may reshuffle).
    func rankedPlaces(now: Date) -> [ListeningPlaceLabel] {
        let order = rankOrder(now: now)
        return order.eligible.enumerated().map { idx, e in
            ListeningPlaceLabel(id: e.id, rank: idx + 1, label: "Location " + Self.letters(idx + 1),
                                shareOfTime: order.total > 0 ? e.dwell / order.total : 0)
        }
    }

    /// Trips seen at least `minTripOccurrencesForLabel` times (over the retained timeline), most
    /// frequent first.
    func trips(now: Date) -> [ListeningTripLabel] {
        let ranks = rankOrder(now: now).letterRank
        return tripOccurrences(now: now)
            .filter { $0.value >= params.minTripOccurrencesForLabel }
            .compactMap { key, count -> ListeningTripLabel? in
                guard let id = tripIds[key] else { return nil }
                let (o, d) = Self.splitKey(key)
                return ListeningTripLabel(id: id, origin: o, destination: d,
                                          label: Self.tripLabel(origin: o, destination: d, ranks: ranks),
                                          occurrences: count)
            }
            .sorted { $0.occurrences != $1.occurrences ? $0.occurrences > $1.occurrences : $0.id < $1.id }
    }

    /// "Location A" / "A → B" / "A ↺" / "Leaving A"; nil for kind none/unknown or an id this
    /// engine no longer knows. Follows merge aliases. A known place below the label threshold
    /// still gets a letter (after every ranked place) so a tag never reads as unknown while its
    /// place exists.
    func label(for tag: ListeningContextTag, now: Date) -> String? {
        let ranks = rankOrder(now: now).letterRank
        switch tag.kind {
        case ListeningContextTag.kindPlace:
            guard let raw = tag.placeId, let rank = ranks[resolve(raw)] else { return nil }
            return "Location " + Self.letters(rank)
        case ListeningContextTag.kindTrip:
            guard let raw = tag.tripId else { return nil }
            let id = resolve(raw)
            guard let key = tripIds.first(where: { $0.value == id })?.key else { return nil }
            let (o, d) = Self.splitKey(key)
            guard ranks[o] != nil else { return nil }
            return Self.tripLabel(origin: o, destination: d, ranks: ranks)
        default:
            return nil
        }
    }

    /// 1 → "A" … 26 → "Z", 27 → "AA", 28 → "AB" (bijective base-26).
    static func letters(_ rank: Int) -> String {
        var n = max(1, rank)
        var out = ""
        while n > 0 {
            n -= 1
            out = String(UnicodeScalar(UInt8(65 + n % 26))) + out
            n /= 26
        }
        return out
    }

    // MARK: - Prune

    /// Retention: raw visits `rawRetentionDays`, dwell segments `timelineRetentionDays`, places
    /// (with their trip pairs + aliases) unseen for `placeRetentionDays`.
    mutating func prune(now: Date) {
        let day: TimeInterval = 86_400
        let rawCutoff = now.addingTimeInterval(-params.rawRetentionDays * day)
        rawVisits.removeAll { ($0.visit.departure ?? $0.visit.arrival ?? $0.receivedAt) < rawCutoff }

        let timelineCutoff = now.addingTimeInterval(-params.timelineRetentionDays * day)
        timeline.removeAll { ($0.end ?? now) < timelineCutoff }

        let placeCutoff = now.addingTimeInterval(-params.placeRetentionDays * day)
        let gone = Set(places.filter { $0.lastSeenAt < placeCutoff }.map(\.id))
        if !gone.isEmpty {
            places.removeAll { gone.contains($0.id) }
            timeline.removeAll { gone.contains($0.placeId) }
            tripIds = tripIds.filter { key, _ in
                let (o, d) = Self.splitKey(key)
                return !gone.contains(o) && !(d.map(gone.contains) ?? false)
            }
        }
        let live = Set(places.map(\.id)).union(tripIds.values)
        aliases = aliases.filter { live.contains(resolve($0.key)) }
    }

    // MARK: - Internals

    private func roundCoord(_ x: Double) -> Double {
        let m = pow(10.0, Double(params.centroidDecimals))
        return (x * m).rounded() / m
    }

    /// Great-circle distance in metres (haversine).
    static func distanceM(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    private func nearestPlaceIndex(latitude: Double, longitude: Double, within radius: Double) -> Int? {
        var best: (Int, Double)?
        for (i, p) in places.enumerated() {
            let d = Self.distanceM(p.latitude, p.longitude, latitude, longitude)
            if d <= radius, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    private mutating func upsertSegment(placeId: String, arrival: Date?, departure: Date?) {
        if let a = arrival {
            if let i = timeline.lastIndex(where: {
                $0.placeId == placeId && abs($0.start.timeIntervalSince(a)) <= params.segmentMatchTolerance
            }) {
                timeline[i].start = a
                if let d = departure { timeline[i].end = d; timeline[i].endIsEstimate = nil }
            } else {
                timeline.append(DwellSegment(placeId: placeId, start: a, end: departure))
            }
        } else if let d = departure,
                  let i = timeline.lastIndex(where: { $0.placeId == placeId && $0.endIsProvisional }) {
            // Arrival unknown: the departure closes (or corrects the guessed end of) the stay we
            // already have there.
            timeline[i].end = max(d, timeline[i].start)
            timeline[i].endIsEstimate = nil
        }
    }

    /// Sorted by start; a stay ends no later than the next one starts (one place at a time); two
    /// consecutive stays at the same place a few minutes apart are one stay.
    private mutating func normalizeTimeline() {
        timeline.sort { $0.start != $1.start ? $0.start < $1.start : $0.placeId < $1.placeId }
        var out: [DwellSegment] = []
        for var seg in timeline {
            if let e = seg.end, e < seg.start { seg.end = seg.start }
            if var prev = out.last {
                // An open stay ends when the next one starts — a GUESS (its departure is unreported).
                if prev.end == nil { prev.end = seg.start; prev.endIsEstimate = true }
                if prev.end! > seg.start { prev.end = seg.start }
                if prev.placeId == seg.placeId,
                   let pe = prev.end, seg.start.timeIntervalSince(pe) <= params.minVisitDwell {
                    if let se = seg.end, se >= pe {
                        prev.end = se; prev.endIsEstimate = seg.endIsEstimate
                    } else if seg.end == nil {
                        prev.end = nil; prev.endIsEstimate = nil
                    }
                    out[out.count - 1] = prev
                    continue
                }
                out[out.count - 1] = prev
            }
            out.append(seg)
        }
        timeline = out
    }

    /// Merge places whose centroids drifted within `mergeRadiusM`. The OLDER id survives and the
    /// younger becomes an alias, so already-written tags still resolve.
    private mutating func mergeNearbyPlaces() {
        var merged = true
        while merged {
            merged = false
            search: for i in places.indices {
                for j in places.indices where j > i {
                    let d = Self.distanceM(places[i].latitude, places[i].longitude,
                                           places[j].latitude, places[j].longitude)
                    if d <= params.mergeRadiusM { merge(i, j); merged = true; break search }
                }
            }
        }
    }

    private mutating func merge(_ i: Int, _ j: Int) {
        let iOlder = places[i].createdAt != places[j].createdAt
            ? places[i].createdAt < places[j].createdAt : places[i].id < places[j].id
        let (si, vi) = iOlder ? (i, j) : (j, i)
        var s = places[si]
        let v = places[vi]
        let w = s.weight + v.weight
        if w > 0 {
            s.latitude = roundCoord((s.latitude * s.weight + v.latitude * v.weight) / w)
            s.longitude = roundCoord((s.longitude * s.weight + v.longitude * v.weight) / w)
        }
        s.weight = w
        s.createdAt = min(s.createdAt, v.createdAt)
        s.lastSeenAt = max(s.lastSeenAt, v.lastSeenAt)
        places[si] = s
        places.remove(at: vi)

        for k in timeline.indices where timeline[k].placeId == v.id { timeline[k].placeId = s.id }
        addAlias(from: v.id, to: s.id)

        // Re-key the trip table. Pairs that didn't involve the victim keep their ids; a re-keyed
        // pair that collides with an existing one becomes an alias of it.
        var rekeyed: [String: String] = [:]
        var moved: [(String, String)] = []
        for (key, tid) in tripIds {
            let (o, d) = Self.splitKey(key)
            if o == v.id || d == v.id {
                moved.append((Self.tripKey(o == v.id ? s.id : o, d == v.id ? s.id : d), tid))
            } else {
                rekeyed[key] = tid
            }
        }
        for (key, tid) in moved.sorted(by: { $0.1 < $1.1 }) {
            if let existing = rekeyed[key] { addAlias(from: tid, to: existing) } else { rekeyed[key] = tid }
        }
        tripIds = rekeyed
    }

    private mutating func addAlias(from old: String, to new: String) {
        guard old != new else { return }
        for (k, val) in aliases where val == old { aliases[k] = new }
        aliases[old] = new
    }

    /// Follows the alias chain (bounded — a corrupted cycle can't hang a lookup).
    func resolve(_ id: String) -> String {
        var cur = id
        for _ in 0..<16 { guard let next = aliases[cur] else { break }; cur = next }
        return cur
    }

    /// Mint an id for every ordered pair the timeline now contains (a gap ≤ maxTripDuration
    /// between consecutive stays), and an `<origin>>?` id for every departure (used if no arrival
    /// follows in time).
    private mutating func ensureTripIds(newId: () -> String) {
        func mint(_ key: String) {
            if tripIds[key] == nil { tripIds[key] = Self.tripPrefix + newId() }
        }
        for (k, seg) in timeline.enumerated() {
            guard let end = seg.end else { continue }
            if k + 1 < timeline.count {
                let next = timeline[k + 1]
                if next.start.timeIntervalSince(end) <= params.maxTripDuration {
                    mint(Self.tripKey(seg.placeId, next.placeId))
                    continue
                }
            }
            mint(Self.tripKey(seg.placeId, nil))
        }
    }

    /// Completed trips by pair key over the retained timeline (an in-flight departure isn't one).
    private func tripOccurrences(now: Date) -> [String: Int] {
        var counts: [String: Int] = [:]
        for (k, seg) in timeline.enumerated() {
            guard let end = seg.end else { continue }
            if k + 1 < timeline.count, timeline[k + 1].start.timeIntervalSince(end) <= params.maxTripDuration {
                counts[Self.tripKey(seg.placeId, timeline[k + 1].placeId), default: 0] += 1
            } else if k + 1 < timeline.count || now.timeIntervalSince(end) >= params.maxTripDuration {
                counts[Self.tripKey(seg.placeId, nil), default: 0] += 1
            }
        }
        return counts
    }

    private func tripTag(origin: String, destination: String?) -> ListeningContextTag? {
        guard let id = tripIds[Self.tripKey(origin, destination)] else { return nil }
        return .trip(id, origin: origin, destination: destination)
    }

    private func lastSegmentIndex(startingAtOrBefore t: Date) -> Int? {
        var lo = 0, hi = timeline.count   // first index with start > t
        while lo < hi {
            let mid = (lo + hi) / 2
            if timeline[mid].start <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    private struct RankOrder {
        var eligible: [(id: String, dwell: Double)]
        var total: Double
        /// Every known place → letter rank: ranked places first, then the rest by dwell.
        var letterRank: [String: Int]
    }

    private func rankOrder(now: Date) -> RankOrder {
        let windowStart = now.addingTimeInterval(-params.rankWindowDays * 86_400)
        var dwell: [String: Double] = [:]
        for seg in timeline {
            let s = max(seg.start, windowStart), e = min(seg.end ?? now, now)
            if e > s { dwell[seg.placeId, default: 0] += e.timeIntervalSince(s) }
        }
        let total = dwell.values.reduce(0, +)
        let sorted = places.sorted { a, b in
            let da = dwell[a.id] ?? 0, db = dwell[b.id] ?? 0
            if da != db { return da > db }
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id < b.id
        }
        let eligible = sorted.filter { (dwell[$0.id] ?? 0) >= params.minDwellForLabel }
            .map { (id: $0.id, dwell: dwell[$0.id] ?? 0) }
        let eligibleIds = Set(eligible.map(\.id))
        var letterRank: [String: Int] = [:]
        for (i, e) in eligible.enumerated() { letterRank[e.id] = i + 1 }
        var next = eligible.count + 1
        for p in sorted where !eligibleIds.contains(p.id) { letterRank[p.id] = next; next += 1 }
        return RankOrder(eligible: eligible, total: total, letterRank: letterRank)
    }

    static func tripKey(_ origin: String, _ destination: String?) -> String {
        origin + ">" + (destination ?? "?")
    }

    static func splitKey(_ key: String) -> (String, String?) {
        let parts = key.split(separator: ">", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let d = parts.count > 1 ? parts[1] : "?"
        return (parts.first ?? "", d == "?" ? nil : d)
    }

    static func tripLabel(origin: String, destination: String?, ranks: [String: Int]) -> String {
        let o = ranks[origin].map(letters) ?? "?"
        guard let d = destination else { return "Leaving " + o }
        if d == origin { return o + " ↺" }
        return o + " → " + (ranks[d].map(letters) ?? "?")
    }
}
