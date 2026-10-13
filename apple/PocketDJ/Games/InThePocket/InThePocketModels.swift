import Foundation

// ─────────────────────────────────────────────────────────────────────────────────────────────
// IN THE POCKET — the game's value types. A ROUND is a prediction ("these 3–4 songs, right now,
// here, will play through without a skip") plus what happened and the player's optional rating /
// feedback. Every round is persisted on device and uploaded (opt-in, the listening-pockets gate)
// to `POST /pockets/rounds` as a labelled training example for the pocket analysis.
//
// Context is OPAQUE, exactly as listening pockets: a time-of-day bucket, weekday/weekend, and —
// only while places & trips is on — a `plc_`/`trp_` id. Never coordinates, never home/work.
// ─────────────────────────────────────────────────────────────────────────────────────────────

/// The context a round is built for: the SAME buckets the cloud analysis uses (`params.mjs`
/// `timeBuckets`), so a round can be matched to the pockets and patterns found in it.
struct InThePocketContext: Codable, Equatable, Hashable, Sendable {
    /// night | morning | midday | afternoon | evening
    var timeBucket: String
    /// weekday | weekend
    var dayType: String
    /// 0 = Sunday … 6 = Saturday (local).
    var dow: Int
    /// Current place or trip (a guess), only while places & trips is on. nil = time only.
    var ctx: ListeningContextTag?

    /// [name, startHour, endHour) in LOCAL time — mirrors `POCKET_PARAMS.timeBuckets`; a start
    /// after the end wraps midnight.
    static let timeBuckets: [(name: String, start: Double, end: Double)] = [
        ("night", 22, 5), ("morning", 5, 10), ("midday", 10, 14), ("afternoon", 14, 18), ("evening", 18, 22),
    ]

    static func timeBucket(hour: Double) -> String {
        for b in timeBuckets {
            if b.start < b.end ? (hour >= b.start && hour < b.end) : (hour >= b.start || hour < b.end) {
                return b.name
            }
        }
        return "night"
    }

    /// Local calendar facts for an instant in a UTC offset (minutes) — the cloud's `localTimeOf`.
    static func make(atMs: Double, tzOffsetMin: Int, ctx: ListeningContextTag?) -> InThePocketContext {
        let localSec = (atMs / 1000) + Double(tzOffsetMin) * 60
        let daySec = localSec.truncatingRemainder(dividingBy: 86_400)
        let secOfDay = daySec < 0 ? daySec + 86_400 : daySec
        let hour = secOfDay / 3600
        // 1970-01-01 was a Thursday (4).
        let days = Int((localSec / 86_400).rounded(.down))
        let dow = ((days % 7) + 7 + 4) % 7
        return InThePocketContext(timeBucket: timeBucket(hour: hour),
                                  dayType: (dow == 0 || dow == 6) ? "weekend" : "weekday",
                                  dow: dow, ctx: (ctx?.isPlace == true || ctx?.isTrip == true) ? ctx : nil)
    }

    /// `place:<id>` / `trip:<id>` / nil — the cloud's `ctxKeyOf`.
    var ctxKey: String? {
        if let ctx, ctx.isTrip, let id = ctx.tripId { return "trip:\(id)" }
        if let ctx, ctx.isPlace, let id = ctx.placeId { return "place:\(id)" }
        return nil
    }

    /// The round-learning context keys, most specific first (`learnFromRounds`).
    var learningKeys: [String] {
        let relaxed = "\(dayType)|\(timeBucket)|*"
        if let k = ctxKey { return ["\(dayType)|\(timeBucket)|\(k)", relaxed] }
        return [relaxed]
    }

    /// "Weekday evening".
    var timePhrase: String {
        "\(dayType.prefix(1).uppercased())\(dayType.dropFirst()) \(timeBucket)"
    }
}

/// One thing the scorer aimed at: a categorical feature value (`genre`/`funk`, `artist`/`aria`, a
/// `place`/`trip` id, …) or a numeric band (`bpm`/`118-126`). Uploaded with the round so the cloud
/// can credit the label to exactly what the prediction was built from.
struct InThePocketTarget: Codable, Equatable, Hashable, Sendable {
    var dim: String
    var value: String
    /// Display text ("Funk", "118–126 BPM", "Location A"). Never uploaded.
    var label: String
    var weight: Double
}

/// How a round's songs were chosen.
enum InThePocketMode: String, Codable, Sendable {
    /// From the cloud's pockets + patterns for this context (+ round learning).
    case cloud
    /// No cloud results yet: from this device's own plays in this context.
    case history
    /// Nothing for this context either: from everything this device has played through.
    case cold
}

/// What happened to one song of a round.
enum InThePocketSongState: String, Codable, Equatable, Sendable {
    case pending, playing, completed, skipped, notPlayed
}

/// The round's verdict.
enum InThePocketOutcome: Codable, Equatable, Sendable {
    /// Every song played through, no skip.
    case pocket
    /// The first skip, 1-based ("Broke at song 2").
    case broke(at: Int)
    /// The player moved on (something else played, the set stopped, or it timed out).
    case abandoned

    var token: String {
        switch self {
        case .pocket: return "pocket"
        case .broke: return "broke"
        case .abandoned: return "abandoned"
        }
    }
    var brokeAt: Int? { if case .broke(let n) = self { return n }; return nil }

    enum CodingKeys: String, CodingKey { case outcome, brokeAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .outcome) {
        case "pocket": self = .pocket
        case "broke": self = .broke(at: (try? c.decode(Int.self, forKey: .brokeAt)) ?? 1)
        default: self = .abandoned
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(token, forKey: .outcome)
        try c.encodeIfPresent(brokeAt, forKey: .brokeAt)
    }
}

/// One song as the round holds it.
struct InThePocketSong: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String              // song id (base)
    var title: String
    var artist: String
    var lengthMs: Int?
    /// The scorer's score for it (uploaded — "how sure was the prediction").
    var score: Double
    /// Why it was picked ("Funk · 121 BPM").
    var why: [String]
    var state: InThePocketSongState = .pending
    var eventId: UUID?
    var fraction: Double?
}

/// A whole round — persisted locally (`pocketdj-in-the-pocket.json`) and uploaded as training data.
struct InThePocketRound: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var createdAtMs: Double
    /// When ▶ was pressed (nil = built but not started).
    var startedAtMs: Double?
    var endedAtMs: Double?
    /// Bumped on every change (feedback, rating, outcome) — the server keeps the newest copy.
    var updatedAtMs: Double
    var tzOffsetMin: Int
    var context: InThePocketContext
    /// Human label of `context.ctx` at build time ("Location A", "A → B"). Never uploaded.
    var contextLabel: String?
    var mode: InThePocketMode
    /// UInt64 seed, as a decimal string (JSON numbers can't carry 64 bits).
    var seed: String
    var algoVersion: Int?
    var targets: [InThePocketTarget]
    var songs: [InThePocketSong]
    var outcome: InThePocketOutcome?
    /// 1…5, optional.
    var rating: Int?
    /// Free text (typed or dictated), capped at `InThePocketRound.maxFeedbackChars`.
    var feedback: String?
    var appVersion: String?

    static let maxFeedbackChars = 2000

    var isFinished: Bool { outcome != nil }
    var isActive: Bool { startedAtMs != nil && outcome == nil }

    /// Free text → stored: trimmed, capped at `maxFeedbackChars` UTF-16 units without splitting a
    /// surrogate pair (the server's `capText` applies the same cap), empty → nil.
    static func capFeedback(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let utf16 = Array(trimmed.utf16)
        guard utf16.count > maxFeedbackChars else { return trimmed }
        var cut = maxFeedbackChars
        if UTF16.isLeadSurrogate(utf16[cut - 1]) { cut -= 1 }
        return String(decoding: utf16[..<cut], as: UTF16.self)
    }

    /// The upload row (`POST /pockets/rounds`, rounds.v1). Only FINISHED rounds upload.
    func wire(installId: String) -> InThePocketRoundWire? {
        guard let outcome, let startedAtMs else { return nil }
        return InThePocketRoundWire(
            id: id.uuidString, originInstallId: installId,
            startedAtMs: Self.flooredMinute(startedAtMs),
            endedAtMs: endedAtMs.map { Self.flooredMinute($0) },
            updatedAtMs: Int64(updatedAtMs), tzOffsetMin: tzOffsetMin,
            context: .init(timeBucket: context.timeBucket, dayType: context.dayType, dow: context.dow, ctx: context.ctx),
            mode: mode.rawValue, seed: seed, algoVersion: algoVersion,
            targets: targets.map { .init(dim: $0.dim, value: $0.value, weight: ($0.weight * 1000).rounded() / 1000) },
            songs: songs.map {
                .init(songId: $0.id, artist: $0.artist, score: ($0.score * 1000).rounded() / 1000,
                      outcome: Self.wireSongOutcome($0), fraction: $0.fraction.map { ($0 * 1000).rounded() / 1000 })
            },
            outcome: outcome.token, brokeAt: outcome.brokeAt, rating: rating,
            feedback: Self.capFeedback(feedback), appVersion: appVersion)
    }

    /// Coarse time on the wire (the `ListeningPocketsService.flooredMinute` rule).
    static func flooredMinute(_ ms: Double) -> Int64 {
        Int64((ms / 60_000).rounded(.down)) * 60_000
    }

    private static func wireSongOutcome(_ s: InThePocketSong) -> String {
        switch s.state {
        case .completed: return "completed"
        case .skipped: return "skipped"
        case .notPlayed, .pending: return "notPlayed"
        case .playing: return (s.fraction ?? 0) >= 0.5 ? "completed" : "partial"
        }
    }
}

/// `POST /pockets/rounds` body.
struct InThePocketRoundsBatch: Encodable, Equatable {
    var v = 1
    var deviceId: String?
    var installId: String
    var sentAtMs: Int64
    var rounds: [InThePocketRoundWire]
}

/// One round on the wire (`cleanRound` on the server). Nullable fields encode explicit `null`.
struct InThePocketRoundWire: Encodable, Equatable {
    struct Context: Encodable, Equatable {
        var timeBucket: String
        var dayType: String
        var dow: Int
        var ctx: ListeningContextTag?
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(timeBucket, forKey: .timeBucket)
            try c.encode(dayType, forKey: .dayType)
            try c.encode(dow, forKey: .dow)
            if let ctx {
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
        enum CodingKeys: String, CodingKey { case timeBucket, dayType, dow, ctx }
    }
    struct Target: Encodable, Equatable { var dim: String; var value: String; var weight: Double }
    struct Song: Encodable, Equatable {
        var songId: String
        var artist: String?
        var score: Double
        var outcome: String
        var fraction: Double?
        enum CodingKeys: String, CodingKey { case songId, artist, score, outcome, fraction }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(songId, forKey: .songId)
            try c.encode(artist, forKey: .artist)
            try c.encode(score, forKey: .score)
            try c.encode(outcome, forKey: .outcome)
            try c.encode(fraction, forKey: .fraction)
        }
    }

    var id: String
    var originInstallId: String
    var startedAtMs: Int64
    var endedAtMs: Int64?
    var updatedAtMs: Int64
    var tzOffsetMin: Int
    var context: Context
    var mode: String
    var seed: String
    var algoVersion: Int?
    var targets: [Target]
    var songs: [Song]
    var outcome: String
    var brokeAt: Int?
    var rating: Int?
    var feedback: String?
    var appVersion: String?

    enum CodingKeys: String, CodingKey {
        case id, originInstallId, startedAtMs, endedAtMs, updatedAtMs, tzOffsetMin, context, mode, seed
        case algoVersion, targets, songs, outcome, brokeAt, rating, feedback, appVersion
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(originInstallId, forKey: .originInstallId)
        try c.encode(startedAtMs, forKey: .startedAtMs)
        try c.encode(endedAtMs, forKey: .endedAtMs)
        try c.encode(updatedAtMs, forKey: .updatedAtMs)
        try c.encode(tzOffsetMin, forKey: .tzOffsetMin)
        try c.encode(context, forKey: .context)
        try c.encode(mode, forKey: .mode)
        try c.encode(seed, forKey: .seed)
        try c.encode(algoVersion, forKey: .algoVersion)
        try c.encode(targets, forKey: .targets)
        try c.encode(songs, forKey: .songs)
        try c.encode(outcome, forKey: .outcome)
        try c.encode(brokeAt, forKey: .brokeAt)
        try c.encode(rating, forKey: .rating)
        try c.encode(feedback, forKey: .feedback)
        try c.encode(appVersion, forKey: .appVersion)
    }

    /// Everything that can CHANGE after the first upload — a moved fingerprint re-sends.
    var fingerprint: String {
        "\(updatedAtMs)|\(outcome)|\(brokeAt ?? 0)|\(rating ?? 0)|\(feedback?.count ?? 0)|"
            + songs.map { "\($0.outcome)\(Int((($0.fraction ?? 0) * 100).rounded()))" }.joined(separator: ",")
    }
}
