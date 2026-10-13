import Foundation

// ─────────────────────────────────────────────────────────────────────────────────────────────
// LISTENING POCKETS — wire types for the `pocketdj-listening-pockets` Lambda (mounted at
// `/pockets` on the rec-engine HTTP API). Upload v1 (`POST /pockets/events`) is ENCODED here
// exactly as the design spec §5.1 lays it out; results v1 (`GET /pockets/results`, §5.2) decode
// LENIENTLY — arrays per element, numbers either integral or not, unknown keys ignored, an
// unknown feature `dim` kept as its raw string — so a newer server can never blank the tab.
//
// Naming: "ListeningPocket…" — the app already has `Pocket` collections (the Pocket DAG).
// ─────────────────────────────────────────────────────────────────────────────────────────────

// MARK: - Upload v1

/// `POST /pockets/events` body.
struct ListeningPocketsUploadBatch: Encodable, Equatable {
    var v = 1
    var deviceId: String?
    var installId: String
    var sentAtMs: Int64
    var events: [ListeningPocketsUploadEvent]
    /// Only while location is ACTIVE (opted in + permitted); omitted otherwise.
    var places: [ListeningPocketsPlaceWire]?
    var trips: [ListeningPocketsTripWire]?
}

/// One play as uploaded. Nullable fields encode an explicit `null` (the §5.1 shape), so the
/// server never has to tell "absent" from "unknown".
struct ListeningPocketsUploadEvent: Encodable, Equatable {
    var id: String
    var songId: String
    /// Play START, epoch ms FLOORED to the minute (coarse time on the wire).
    var atMs: Int64
    /// Order among the plays sharing `atMs` + stream (originInstallId ?? installId) — over the
    /// whole history, so it is stable across uploads (`ListeningPocketsService.ordinals`).
    var ord: Int
    var tzOffsetMin: Int?
    var source: String?
    /// completed | skipped | partial | unknown (`PlayEvent.PlayOutcome`).
    var outcome: String
    var fraction: Double?
    var originInstallId: String?
    var artist: String?
    var carPlay: Bool?
    var ctx: ListeningContextTag?

    enum CodingKeys: String, CodingKey {
        case id, songId, atMs, ord, tzOffsetMin, source, outcome, fraction, originInstallId, artist, carPlay, ctx
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(songId, forKey: .songId)
        try c.encode(atMs, forKey: .atMs)
        try c.encode(ord, forKey: .ord)
        try c.encode(tzOffsetMin, forKey: .tzOffsetMin)
        try c.encode(source, forKey: .source)
        try c.encode(outcome, forKey: .outcome)
        try c.encode(fraction, forKey: .fraction)
        try c.encode(originInstallId, forKey: .originInstallId)
        try c.encode(artist, forKey: .artist)
        try c.encode(carPlay, forKey: .carPlay)
        if let ctx {
            // Only the ids the kind uses — never an empty-string id the server's patterns reject.
            var n = c.nestedContainer(keyedBy: ListeningContextTag.CodingKeys.self, forKey: .ctx)
            try n.encode(ctx.kind, forKey: .kind)
            try n.encodeIfPresent(ctx.placeId, forKey: .placeId)
            try n.encodeIfPresent(ctx.tripId, forKey: .tripId)
            try n.encodeIfPresent(ctx.origin, forKey: .origin)
            try n.encodeIfPresent(ctx.destination, forKey: .destination)
        } else {
            try c.encodeNil(forKey: .ctx)
        }
    }
}

/// A place's display label as of upload (the cloud titles pockets with it; the app re-labels
/// locally at display time, so a reshuffled rank never shows a stale letter here).
struct ListeningPocketsPlaceWire: Codable, Equatable {
    var id: String
    var rank: Int
    var label: String
    var share: Double?
}

struct ListeningPocketsTripWire: Codable, Equatable {
    var id: String
    var origin: String
    var destination: String?
    var label: String
    var occurrences: Int?

    enum CodingKeys: String, CodingKey { case id, origin, destination, label, occurrences }

    init(id: String, origin: String, destination: String?, label: String, occurrences: Int?) {
        self.id = id; self.origin = origin; self.destination = destination
        self.label = label; self.occurrences = occurrences
    }

    /// `destination` is nullable on the wire (a trip that never arrived anywhere known).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(origin, forKey: .origin)
        try c.encode(destination, forKey: .destination)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(occurrences, forKey: .occurrences)
    }
}

/// `200 {"ok":true,"accepted":…}` — every count optional (only the 2xx matters to the client).
struct ListeningPocketsUploadResponse: Decodable, Equatable {
    var ok: Bool?
    var accepted: Int?
    var updated: Int?
    var unchanged: Int?
    var rejected: Int?
    var total: Int?
    var dirty: Bool?
}

// MARK: - Results v1

/// `GET /pockets/results`. A profile with no state is the EMPTY shape (`generatedAtMs: nil`).
struct ListeningPocketsResults: Decodable, Equatable {
    var v: Int
    var generatedAtMs: Double?
    /// Events changed since this compute (a recompute is queued).
    var stale: Bool
    var algoVersion: Int?
    var baseline: Baseline?
    var labels: Labels?
    var pockets: [ListeningPocket]
    var patterns: [ListeningPocketPattern]
    /// "In the Pocket" round labels folded into per-context target multipliers (`rounds` on the
    /// wire, present only once the profile has played the game). See `learnFromRounds`.
    var roundLearning: ListeningPocketsRoundLearning? = nil

    struct Baseline: Decodable, Equatable {
        var plays: Int?
        var windowDays: Double?
        var thin: Bool?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: LPKey.self)
            plays = c.lpInt("plays"); windowDays = c.lpDouble("windowDays"); thin = c.lpBool("thin")
        }
    }

    /// The label snapshot the server last received (echo) — the fallback names for place/trip
    /// ids on a device that has no location engine of its own (Mac, TV, Vision Pro).
    struct Labels: Decodable, Equatable {
        var places: [ListeningPocketsPlaceWire]
        var trips: [ListeningPocketsTripWire]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: LPKey.self)
            places = c.lpArray(ListeningPocketsPlaceWire.self, "places")
            trips = c.lpArray(ListeningPocketsTripWire.self, "trips")
        }
    }

    static let empty = ListeningPocketsResults(v: 1, generatedAtMs: nil, stale: false, algoVersion: nil,
                                               baseline: nil, labels: nil, pockets: [], patterns: [])

    init(v: Int, generatedAtMs: Double?, stale: Bool, algoVersion: Int?, baseline: Baseline?,
         labels: Labels?, pockets: [ListeningPocket], patterns: [ListeningPocketPattern]) {
        self.v = v; self.generatedAtMs = generatedAtMs; self.stale = stale
        self.algoVersion = algoVersion; self.baseline = baseline; self.labels = labels
        self.pockets = pockets; self.patterns = patterns
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LPKey.self)
        v = c.lpInt("v") ?? 1
        generatedAtMs = c.lpDouble("generatedAtMs")
        stale = c.lpBool("stale") ?? false
        algoVersion = (try? c.nestedContainer(keyedBy: LPKey.self, forKey: LPKey("algo")))?.lpInt("version")
        baseline = (try? c.decodeIfPresent(Baseline.self, forKey: LPKey("baseline"))) ?? nil
        labels = (try? c.decodeIfPresent(Labels.self, forKey: LPKey("labels"))) ?? nil
        pockets = c.lpArray(ListeningPocket.self, "pockets")
        patterns = c.lpArray(ListeningPocketPattern.self, "patterns")
        roundLearning = (try? c.decodeIfPresent(ListeningPocketsRoundLearning.self, forKey: LPKey("rounds"))) ?? nil
    }

    /// Server-side label for a place/trip id (the uploaded snapshot), if it has one.
    func snapshotLabel(for tag: ListeningContextTag) -> String? {
        if tag.kind == ListeningContextTag.kindPlace, let id = tag.placeId {
            return labels?.places.first { $0.id == id }?.label
        }
        if tag.kind == ListeningContextTag.kindTrip, let id = tag.tripId {
            return labels?.trips.first { $0.id == id }?.label
        }
        return nil
    }
}

/// The dimensions the analysis can call DEFINING. An open set on the wire — anything this build
/// doesn't know stays a raw string on the feature (`ListeningPocketFeature.dim`).
enum ListeningPocketDim: String {
    case artist, genre, mood, camelot, source, timeBucket, dayType, dow, place, trip, carPlay
    /// The ones that describe the MUSIC (vs when/where/how it played).
    var isMusical: Bool { [.artist, .genre, .mood, .camelot].contains(self) }
}

/// One categorical feature: `share` of the pocket vs `baselineShare` of all listening.
struct ListeningPocketFeature: Decodable, Equatable, Hashable {
    var dim: String
    var value: String
    var label: String
    var share: Double
    var baselineShare: Double?
    var lift: Double
    var score: Double
    var count: Int?

    var kind: ListeningPocketDim? { ListeningPocketDim(rawValue: dim) }

    init(dim: String, value: String, label: String, share: Double, baselineShare: Double? = nil,
         lift: Double, score: Double, count: Int? = nil) {
        self.dim = dim; self.value = value; self.label = label; self.share = share
        self.baselineShare = baselineShare; self.lift = lift; self.score = score; self.count = count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LPKey.self)
        guard let dim = c.lpString("dim"), let value = c.lpString("value") else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "feature without dim/value"))
        }
        self.dim = dim
        self.value = value
        label = c.lpString("label") ?? value
        share = c.lpDouble("share") ?? 0
        baselineShare = c.lpDouble("baselineShare")
        lift = c.lpDouble("lift") ?? 1
        score = c.lpDouble("score") ?? 0
        count = c.lpInt("count")
    }

    /// The location tag this feature names (place / trip), for on-device re-labelling.
    var contextTag: ListeningContextTag? {
        switch kind {
        case .place: return .place(value)
        case .trip:  return ListeningContextTag(kind: ListeningContextTag.kindTrip, tripId: value)
        default:     return nil
        }
    }
}

/// A numeric dimension (bpm / energy / year): the pocket's range vs the baseline spread.
struct ListeningPocketNumeric: Decodable, Equatable, Hashable {
    var center: Double
    var lo: Double
    var hi: Double
    var coverage: Double
    var dispersionRatio: Double?
    var baselineCenter: Double?
    var defining: Bool

    init(center: Double, lo: Double, hi: Double, coverage: Double, dispersionRatio: Double?,
         baselineCenter: Double?, defining: Bool) {
        self.center = center; self.lo = lo; self.hi = hi; self.coverage = coverage
        self.dispersionRatio = dispersionRatio; self.baselineCenter = baselineCenter; self.defining = defining
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LPKey.self)
        guard let center = c.lpDouble("center") else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "numeric without center"))
        }
        self.center = center
        lo = c.lpDouble("lo") ?? center
        hi = c.lpDouble("hi") ?? center
        coverage = c.lpDouble("coverage") ?? 0
        dispersionRatio = c.lpDouble("dispersionRatio")
        baselineCenter = c.lpDouble("baselineCenter")
        defining = c.lpBool("defining") ?? false
    }
}

/// Harmonic flow: how often consecutive members sit on neighbouring Camelot keys.
struct ListeningPocketHarmonic: Decodable, Equatable, Hashable {
    var rate: Double
    var baselineRate: Double?
    var pairs: Int?
    var defining: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LPKey.self)
        guard let rate = c.lpDouble("rate") else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "harmonic without rate"))
        }
        self.rate = rate
        baselineRate = c.lpDouble("baselineRate")
        pairs = c.lpInt("pairs")
        defining = c.lpBool("defining") ?? false
    }
}

/// One play inside a pocket (only the un-skipped ones are members).
struct ListeningPocketMember: Decodable, Equatable, Hashable {
    var eventId: String
    var songId: String
    var atMs: Double
    var outcome: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LPKey.self)
        guard let songId = c.lpString("songId") else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "member without songId"))
        }
        self.songId = songId
        eventId = c.lpString("eventId") ?? ""
        atMs = c.lpDouble("atMs") ?? 0
        outcome = c.lpString("outcome")
    }
}

/// One detected pocket: ≥3 un-skipped plays in a row, and what defines them.
struct ListeningPocket: Decodable, Equatable, Hashable, Identifiable {
    var id: String
    var startMs: Double
    var endMs: Double
    var tzOffsetMin: Int?
    var localDate: String?
    var localStartHour: Double?
    var dow: Int?
    var dayType: String?
    var timeBucket: String?
    var installId: String?
    var memberCount: Int
    var skippedCount: Int
    var sessionPlays: Int?
    var members: [ListeningPocketMember]
    var ctx: ListeningContextTag?
    var features: [ListeningPocketFeature]
    var numeric: [String: ListeningPocketNumeric]
    var harmonic: ListeningPocketHarmonic?
    var title: String
    var patternId: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LPKey.self)
        guard let id = c.lpString("id") else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "pocket without id"))
        }
        self.id = id
        startMs = c.lpDouble("startMs") ?? 0
        endMs = c.lpDouble("endMs") ?? startMs
        tzOffsetMin = c.lpInt("tzOffsetMin")
        localDate = c.lpString("localDate")
        localStartHour = c.lpDouble("localStartHour")
        dow = c.lpInt("dow")
        dayType = c.lpString("dayType")
        timeBucket = c.lpString("timeBucket")
        installId = c.lpString("installId")
        members = c.lpArray(ListeningPocketMember.self, "members")
        memberCount = c.lpInt("memberCount") ?? members.count
        skippedCount = c.lpInt("skippedCount") ?? 0
        sessionPlays = c.lpInt("sessionPlays")
        ctx = c.lpContext("ctx")
        features = c.lpArray(ListeningPocketFeature.self, "features")
        numeric = c.lpNumericMap("numeric")
        harmonic = (try? c.decodeIfPresent(ListeningPocketHarmonic.self, forKey: LPKey("harmonic"))) ?? nil
        title = c.lpString("title") ?? "Listening pocket"
        patternId = c.lpString("patternId")
    }

    /// Member song ids in play order (Play / Save as playlist).
    var songIds: [String] { members.map(\.songId) }
}

/// A recurring pocket: pockets that share day type, time bucket, context and genre across days.
struct ListeningPocketPattern: Decodable, Equatable, Hashable, Identifiable {
    var id: String
    var key: String
    var title: String
    var pocketIds: [String]
    var occurrences: Int
    var distinctDays: Int
    var firstMs: Double?
    var lastMs: Double?
    var dayType: String?
    var timeBucket: String?
    var ctx: ListeningContextTag?
    var features: [ListeningPocketFeature]
    var numeric: [String: ListeningPocketNumeric]
    var harmonic: ListeningPocketHarmonic?
    var topSongs: [TopSong]

    struct TopSong: Decodable, Equatable, Hashable {
        var songId: String
        var plays: Int
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: LPKey.self)
            guard let songId = c.lpString("songId") else {
                throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "topSong without songId"))
            }
            self.songId = songId
            plays = c.lpInt("plays") ?? 0
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LPKey.self)
        guard let id = c.lpString("id") else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "pattern without id"))
        }
        self.id = id
        key = c.lpString("key") ?? id
        title = c.lpString("title") ?? "Recurring pocket"
        pocketIds = c.lpArray(String.self, "pocketIds")
        occurrences = c.lpInt("occurrences") ?? pocketIds.count
        distinctDays = c.lpInt("distinctDays") ?? occurrences
        firstMs = c.lpDouble("firstMs")
        lastMs = c.lpDouble("lastMs")
        dayType = c.lpString("dayType")
        timeBucket = c.lpString("timeBucket")
        ctx = c.lpContext("ctx")
        features = c.lpArray(ListeningPocketFeature.self, "features")
        numeric = c.lpNumericMap("numeric")
        harmonic = (try? c.decodeIfPresent(ListeningPocketHarmonic.self, forKey: LPKey("harmonic"))) ?? nil
        topSongs = c.lpArray(TopSong.self, "topSongs")
    }

    var songIds: [String] { topSongs.map(\.songId) }
}

/// The `rounds` section of results: how "In the Pocket" rounds have gone, and per context which
/// scorer targets predicted well (multiplier > 1) or badly (< 1). Lenient like everything here.
struct ListeningPocketsRoundLearning: Decodable, Equatable {
    var total: Int
    var pocket: Int
    var broke: Int
    var abandoned: Int
    var pocketRate: Double?
    var contexts: [Context]

    struct Context: Decodable, Equatable {
        /// `dayType|timeBucket|*` or `dayType|timeBucket|place:<id>` / `trip:<id>`.
        var key: String
        var rounds: Int
        var weights: [Weight]
        init(key: String, rounds: Int, weights: [Weight]) {
            self.key = key; self.rounds = rounds; self.weights = weights
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: LPKey.self)
            guard let key = c.lpString("key") else {
                throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "context without key"))
            }
            self.key = key
            rounds = c.lpInt("rounds") ?? 0
            weights = c.lpArray(Weight.self, "weights")
        }
    }

    struct Weight: Decodable, Equatable {
        var dim: String
        var value: String
        var pos: Int
        var neg: Int
        var multiplier: Double
        init(dim: String, value: String, pos: Int, neg: Int, multiplier: Double) {
            self.dim = dim; self.value = value; self.pos = pos; self.neg = neg; self.multiplier = multiplier
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: LPKey.self)
            guard let dim = c.lpString("dim"), let value = c.lpString("value"),
                  let m = c.lpDouble("multiplier") else {
                throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "weight without dim/value/multiplier"))
            }
            self.dim = dim; self.value = value; multiplier = m
            pos = c.lpInt("pos") ?? 0
            neg = c.lpInt("neg") ?? 0
        }
    }

    init(total: Int = 0, pocket: Int = 0, broke: Int = 0, abandoned: Int = 0,
         pocketRate: Double? = nil, contexts: [Context]) {
        self.total = total; self.pocket = pocket; self.broke = broke; self.abandoned = abandoned
        self.pocketRate = pocketRate; self.contexts = contexts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LPKey.self)
        total = c.lpInt("total") ?? 0
        pocket = c.lpInt("pocket") ?? 0
        broke = c.lpInt("broke") ?? 0
        abandoned = c.lpInt("abandoned") ?? 0
        pocketRate = c.lpDouble("pocketRate")
        contexts = c.lpArray(Context.self, "contexts")
    }
}

// MARK: - Lenient decoding helpers (file-private)

/// A string-backed coding key, so the lenient decoders can address any field by name.
struct LPKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Per-element tolerant wrapper (the `LenientEvent` idiom): a bad element yields nil.
private struct LPLossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

fileprivate extension KeyedDecodingContainer where K == LPKey {
    func lpString(_ k: String) -> String? {
        (try? decodeIfPresent(String.self, forKey: LPKey(k))) ?? nil
    }
    func lpDouble(_ k: String) -> Double? {
        guard let d = (try? decodeIfPresent(Double.self, forKey: LPKey(k))) ?? nil, d.isFinite else { return nil }
        return d
    }
    /// Integral on the wire, but a `3.0` (or `3.2`) still reads rather than dropping the row.
    func lpInt(_ k: String) -> Int? {
        if let i = (try? decodeIfPresent(Int.self, forKey: LPKey(k))) ?? nil { return i }
        guard let d = lpDouble(k), abs(d) < 9e15 else { return nil }
        return Int(d.rounded())
    }
    func lpBool(_ k: String) -> Bool? {
        (try? decodeIfPresent(Bool.self, forKey: LPKey(k))) ?? nil
    }
    func lpArray<T: Decodable>(_ t: T.Type, _ k: String) -> [T] {
        ((try? decodeIfPresent([LPLossy<T>].self, forKey: LPKey(k))) ?? nil)?.compactMap(\.value) ?? []
    }
    /// `{ "bpm": {...}, "energy": {...} }` — each value lenient on its own.
    func lpNumericMap(_ k: String) -> [String: ListeningPocketNumeric] {
        guard let raw = (try? decodeIfPresent([String: LPLossy<ListeningPocketNumeric>].self, forKey: LPKey(k))) ?? nil
        else { return [:] }
        return raw.compactMapValues(\.value)
    }
    /// A ctx object, or nil for `null` / garbage / `kind: "none"`.
    func lpContext(_ k: String) -> ListeningContextTag? {
        guard let tag = (try? decodeIfPresent(ListeningContextTag.self, forKey: LPKey(k))) ?? nil,
              tag.isPlace || tag.isTrip else { return nil }
        return tag
    }
}
