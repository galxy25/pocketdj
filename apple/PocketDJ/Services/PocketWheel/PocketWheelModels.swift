import Foundation

// ─────────────────────────────────────────────────────────────────────────────────────────────
// POCKET WHEEL — shared value types (docs/design/pocket-wheel.md).
//
// Naming: the app already has `Pocket` (the collection DAG) and `ListeningPocket` (the cloud's
// grooves). This feature's two nouns are deliberately different:
//   · PocketMoment — one wheel cell, keyed (hour, weekday, mode);
//   · PocketRun    — one adaptive 100-song playback started from the wheel.
// The UI just says "pocket".
//
// PLATFORM FENCE: everything in this file is pure Foundation and compiles on every platform.
// Only the CoreMotion adapter (Location/CoreMotionActivitySource.swift) is fenced to iOS.
// ─────────────────────────────────────────────────────────────────────────────────────────────

/// How a play was listened to — one per play, derived at aggregation time (§1.3).
/// Raw values are persisted tokens (cache, palette, run file): never rename.
enum PocketMode: String, Codable, CaseIterable, Hashable, Sendable {
    case carPlay, running, walking, trip, mix, browse, collection

    /// The fixed precedence order (§1.3) — also the sliver order inside a wheel cell.
    static let precedence: [PocketMode] = [.carPlay, .running, .walking, .trip, .mix, .browse, .collection]

    /// Chip / caption label. `collection` is "Home" (W6, decided 2026-10-29).
    var label: String {
        switch self {
        case .carPlay:    return "CarPlay"
        case .running:    return "Run"
        case .walking:    return "Walk"
        case .trip:       return "Trip"
        case .mix:        return "Mix"
        case .browse:     return "Browse"
        case .collection: return "Home"
        }
    }

    /// SF Symbol for the focused-ring glyph and the mode chips.
    var symbol: String {
        switch self {
        case .carPlay:    return "car.fill"
        case .running:    return "figure.run"
        case .walking:    return "figure.walk"
        case .trip:       return "point.topleft.down.to.point.bottomright.curvepath"
        case .mix:        return "slider.horizontal.3"
        case .browse:     return "list.bullet"
        case .collection: return "house.fill"
        }
    }

    /// The related-mode pairs (§1.6 smoothing, §3.2 Km): carPlay↔trip, running↔walking, mix↔collection.
    var related: PocketMode? {
        switch self {
        case .carPlay:    return .trip
        case .trip:       return .carPlay
        case .running:    return .walking
        case .walking:    return .running
        case .mix:        return .collection
        case .collection: return .mix
        case .browse:     return nil
        }
    }

    /// Precedence rank (0 = highest).
    var rank: Int { Self.precedence.firstIndex(of: self) ?? Self.precedence.count }

    /// The ONE mode derivation (§1.3) — first match wins. nil ⇒ excluded (games).
    /// Cycling folds into `trip` (W6, decided 2026-10-29).
    static func derive(source: PlayHistoryStore.PlaySource, carPlay: Bool?, motion: String?,
                       context: ListeningContextTag?) -> PocketMode? {
        if source == .game { return nil }
        if carPlay == true { return .carPlay }
        switch motion {
        case MotionToken.running: return .running
        case MotionToken.walking: return .walking
        default: break
        }
        if context?.isTrip == true || motion == MotionToken.automotive || motion == MotionToken.cycling {
            return .trip
        }
        switch source {
        case .mix: return .mix
        case .browser, .album, .artist: return .browse
        default: return .collection
        }
    }

    static func derive(_ e: PlayHistoryStore.PlayEvent) -> PocketMode? {
        derive(source: e.source, carPlay: e.carPlay, motion: e.motion, context: e.listeningContext)
    }
}

/// The raw motion tokens stored on `PlayEvent.motion` (CoreMotion's activity classes).
enum MotionToken {
    static let running = "running"
    static let walking = "walking"
    static let cycling = "cycling"
    static let automotive = "automotive"
    static let stationary = "stationary"
    /// Tie-break order: the more active state wins (§1.4).
    static let activityOrder = [running, walking, cycling, automotive, stationary]
    static func activityRank(_ t: String) -> Int { activityOrder.firstIndex(of: t) ?? activityOrder.count }
}

/// One wheel cell's key. `dow` is ISO (1 = Monday … 7 = Sunday); `hour` local 0–23.
struct PocketMomentKey: Hashable, Codable, Sendable, Comparable {
    var hour: Int
    var dow: Int
    var mode: PocketMode

    /// "h08|d2|carPlay" — the token a run's plays carry (`PocketRunTag.momentKey`).
    var token: String { String(format: "h%02d|d%d|", hour, dow) + mode.rawValue }

    init(hour: Int, dow: Int, mode: PocketMode) {
        self.hour = ((hour % 24) + 24) % 24
        self.dow = min(7, max(1, dow))
        self.mode = mode
    }

    init?(token: String) {
        let parts = token.split(separator: "|").map(String.init)
        guard parts.count == 3, parts[0].hasPrefix("h"), parts[1].hasPrefix("d"),
              let h = Int(parts[0].dropFirst()), let d = Int(parts[1].dropFirst()),
              let m = PocketMode(rawValue: parts[2]), (0..<24).contains(h), (1...7).contains(d) else { return nil }
        self.init(hour: h, dow: d, mode: m)
    }

    static func < (a: PocketMomentKey, b: PocketMomentKey) -> Bool {
        (a.dow, a.hour, a.mode.rank) < (b.dow, b.hour, b.mode.rank)
    }

    /// Weekend = Saturday/Sunday (the cloud's dayType split).
    var isWeekend: Bool { dow >= 6 }

    static let weekdayShort = ["M", "T", "W", "T", "F", "S", "S"]
    static let weekdayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    static let weekdayAbbrev = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// "8 AM", "12 PM", "11 PM".
    static func hourLabel(_ h: Int) -> String {
        let hh = ((h % 24) + 24) % 24
        let twelve = hh % 12 == 0 ? 12 : hh % 12
        return "\(twelve) \(hh < 12 ? "AM" : "PM")"
    }

    /// "Tue 8 AM · CarPlay".
    var shortLabel: String { "\(Self.weekdayAbbrev[dow - 1]) \(Self.hourLabel(hour)) · \(mode.label)" }
    /// "Tuesday 8 AM · CarPlay".
    var longLabel: String { "\(Self.weekdayNames[dow - 1]) \(Self.hourLabel(hour)) · \(mode.label)" }
}

/// The local (hour, ISO weekday) of an epoch-ms instant at a fixed UTC offset — pure, so the
/// moment engine, the best-match and the tests all agree without a Calendar/TimeZone.
enum PocketClock {
    static func local(atMs: Double, tzOffsetMin: Int) -> (hour: Int, dow: Int, fractionalHour: Double, dayIndex: Int) {
        let localMs = atMs + Double(tzOffsetMin) * 60_000
        let dayMs = 86_400_000.0
        let dayIndex = Int(floor(localMs / dayMs))
        let msInDay = localMs - Double(dayIndex) * dayMs
        let fh = msInDay / 3_600_000
        // 1970-01-01 was a Thursday (ISO 4).
        let dow = ((dayIndex % 7 + 7) % 7 + 3) % 7 + 1
        return (min(23, max(0, Int(fh))), dow, fh, dayIndex)
    }
}

/// Marks a play started by a Pocket Wheel run (`PlayEvent.pocketRun`). Lenient decode: a field
/// shaped differently by a newer build reads as a missing tag, never a dropped play.
struct PocketRunTag: Codable, Hashable, Sendable {
    var runId: UUID
    /// `PocketMomentKey.token` of the moment the run was built for.
    var momentKey: String
    /// The collection this ROW was placed for (the run planner's quota bucket), if any.
    var rowCollectionId: String?
    /// 1-based slot in the run.
    var slot: Int

    init(runId: UUID, momentKey: String, rowCollectionId: String?, slot: Int) {
        self.runId = runId; self.momentKey = momentKey; self.rowCollectionId = rowCollectionId; self.slot = slot
    }

    enum CodingKeys: String, CodingKey { case runId, momentKey, rowCollectionId, slot }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runId = try c.decode(UUID.self, forKey: .runId)
        momentKey = (try? c.decode(String.self, forKey: .momentKey)) ?? ""
        rowCollectionId = (try? c.decodeIfPresent(String.self, forKey: .rowCollectionId)) ?? nil
        slot = (try? c.decode(Int.self, forKey: .slot)) ?? 0
    }
}

/// Reserved synthetic collection ids the wheel understands.
enum PocketWheelIds {
    /// The Favorites set (FavoritesStore) as a collection: name "Favorite songs". It is not a
    /// stored collection, so it only ever enters attribution as a membership (§1.5 fallback) or
    /// as an explicit origin a caller stamps.
    static let favorites = "fav_songs"
    static let favoritesName = "Favorite songs"
    /// The sequencer run-tag prefix for a Pocket Wheel run (`pwr_<runId>`).
    static let runTagPrefix = "pwr_"
    static func runTag(_ id: UUID) -> String { runTagPrefix + id.uuidString }
    static func runId(fromTag tag: String?) -> UUID? {
        guard let tag, tag.hasPrefix(runTagPrefix) else { return nil }
        return UUID(uuidString: String(tag.dropFirst(runTagPrefix.count)))
    }
}
