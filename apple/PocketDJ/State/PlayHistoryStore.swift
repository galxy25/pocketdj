import Foundation
import Observation

/// The where/when/what-context of every song play on this device — a durable, APPEND-ONLY
/// event log that powers the History mode (a scrollable timeline of everything you've played,
/// in whichever Mix / Playlist / Pocket / Set list / Browser it happened in).
///
/// This is deliberately NOT `PlayStatsStore` (which is an AGGREGATE — one count + one
/// last-played per song, all the storage prune needs). History needs per-event granularity:
/// the SAME song played three times in three different sessions is three timeline rows, each
/// carrying its own timestamp and the name of the set/mix it played in.
///
/// ── Future cross-profile merge ──────────────────────────────────────────────────────────
/// History is device-local today, but it is shaped so profiles can be merged later WITHOUT
/// rework: every event has a stable `UUID` and the document carries an `installId`. A merge is
/// then just `union(events, by: id)` across installs, re-sorted by `playedAt` — dedupe is by
/// event id, so re-importing the same log twice is idempotent. (Aggregate counters can't merge
/// like this — you can't un-double a summed count — which is the other reason this is its own
/// append-only store.)
///
/// Persists to Application Support `pocketdj-play-history.json` (mirrors CollectionsStore /
/// PlayStatsStore durable-JSON: atomic save, decode-on-init, PDJ_USE_FIXTURE test seam).
@MainActor
@Observable
final class PlayHistoryStore {

    /// Which surface a play happened in. Raw values are the persisted tokens — never rename.
    enum PlaySource: String, Codable, CaseIterable, Hashable {
        case browser, playlist, pocket, album, setlist, mix, artist

        /// Human label for the timeline accessory ("in <label>").
        var label: String {
            switch self {
            case .browser:  return "Browser"
            case .playlist: return "Playlist"
            case .pocket:   return "Pocket"
            case .album:    return "Album"
            case .setlist:  return "Set list"
            case .mix:      return "Mix"
            case .artist:   return "Artist"
            }
        }

        /// SF Symbol for the timeline accessory.
        var symbol: String {
            switch self {
            case .browser:  return "list.bullet"
            case .playlist: return "music.note.list"
            case .pocket:   return "square.stack"
            case .album:    return "square.stack.fill"
            case .setlist:  return "music.note.list"
            case .mix:      return "slider.horizontal.3"
            case .artist:   return "music.mic"
            }
        }
    }

    /// One play. `contextName` is what the user recognizes ("Friday Night Mix", "Roadtrip"),
    /// resolved at record time from the live set/mix — a snapshot so history stays readable
    /// even after the set is renamed or deleted. `title`/`artist` are snapshotted for the same
    /// reason (a played song can later leave the catalog).
    struct PlayEvent: Codable, Identifiable, Equatable, Hashable {
        var id: UUID
        var songId: String
        /// Epoch ms of the play.
        var playedAt: Double
        var source: PlaySource
        /// The set/mix collection id this played in (nil for Browser singles).
        var contextId: String?
        /// The set/mix display name this played in (nil for Browser singles).
        var contextName: String?
        var title: String?
        var artist: String?
    }

    /// The persisted, versioned document.
    struct Document: Codable {
        var schemaVersion: Int = playHistorySchemaVersion
        /// Stable identity of THIS install — the merge attribution key (see class doc).
        var installId: String
        var events: [PlayEvent] = []
    }

    /// The append-only log, oldest → newest (insertion order == chronological for live plays).
    private(set) var events: [PlayEvent] = []
    /// Stable id of this install (for a future cross-profile merge).
    private(set) var installId: String
    /// Monotonic, bumped on every real mutation — the History view keys its recompute on this so
    /// a new play refreshes the timeline even when `events.count` is pinned at the cap.
    private(set) var revision = 0

    @ObservationIgnored private let fileURL: URL
    /// O(1) dedupe + last-played reads: songId → most-recent playedAt. Rebuilt from `events`.
    @ObservationIgnored private var lastPlayedIndex: [String: Double] = [:]
    /// songId → number of events (History's group-by-song count). Rebuilt from `events`.
    @ObservationIgnored private var countIndex: [String: Int] = [:]

    /// Repeated plays of the SAME song inside this window collapse to one event (a seek /
    /// restart, or the burned-play double-hook where rips + coordinator both fire, isn't a
    /// second listen). Matches PlayStatsStore.recountWindowMs so the two stores agree.
    nonisolated static let recountWindowMs: Double = 30_000

    /// The log is append-only and would otherwise grow without bound (unlike the aggregate
    /// stats, which are bounded by song count). Cap it and drop the oldest events past the cap.
    nonisolated static let maxEvents = 20_000

    init(fileURL: URL = PlayHistoryStore.defaultURL()) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            events = doc.events
            installId = doc.installId
        } else {
            installId = UUID().uuidString
        }
        rebuildIndexes()
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-play-history.json")
    }

    /// Under UI tests use an isolated, freshly-cleared file (deterministic, never touches the
    /// user's real history). Mirrors PlayStatsStore.launchURL / CollectionsStore.launchURL.
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-play-history.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    /// Context describing WHERE a play happened, resolved at the hook site.
    struct PlayContext {
        var source: PlaySource
        var contextId: String?
        var contextName: String?

        static let browser = PlayContext(source: .browser, contextId: nil, contextName: nil)
    }

    /// Record a play. `at` is injectable for tests; callers use the default (now).
    /// Returns the appended event, or nil if it was deduped / ignored.
    @discardableResult
    func record(songId: String, title: String? = nil, artist: String? = nil,
                context: PlayContext,
                at nowMs: Double = Date().timeIntervalSince1970 * 1000) -> PlayEvent? {
        guard !songId.isEmpty else { return nil }
        // Collapse the double-hook / seek-restart re-notes: if this song was JUST played (this
        // play lands within the window AT OR AFTER the last one), it's the same listen — add
        // nothing (one timeline row). An OLDER timestamp (nowMs < last, e.g. an out-of-order or
        // clock-skewed play) is a genuinely distinct play and IS recorded — `nowMs >= last`
        // guards that so a negative delta never reads as "within the window".
        if let last = lastPlayedIndex[songId], nowMs >= last, nowMs - last < Self.recountWindowMs {
            return nil
        }
        let event = PlayEvent(id: UUID(), songId: songId, playedAt: nowMs,
                              source: context.source, contextId: context.contextId,
                              contextName: context.contextName, title: title, artist: artist)
        events.append(event)
        lastPlayedIndex[songId] = max(lastPlayedIndex[songId] ?? 0, nowMs)
        countIndex[songId, default: 0] += 1
        if events.count > Self.maxEvents { trimToCap() }
        revision &+= 1
        save()
        return event
    }

    /// Epoch ms of the last play of this song, or nil if never played.
    func lastPlayedAt(_ songId: String) -> Double? { lastPlayedIndex[songId] }
    /// Number of recorded plays of this song.
    func playCount(_ songId: String) -> Int { countIndex[songId] ?? 0 }

    /// Test/merge seam: replace the whole log (rebuilds indexes + persists).
    func replaceAll(_ newEvents: [PlayEvent]) {
        events = newEvents
        if events.count > Self.maxEvents { trimToCap() }
        rebuildIndexes()
        revision &+= 1
        save()
    }

    /// UI-test / demo seam: when `PDJ_SEED_HISTORY` is set and the log is empty, seed a handful
    /// of varied plays (distinct sources + set names, spread over the last week) so History
    /// renders populated deterministically. Self-contained (title/artist snapshots render even
    /// before the catalog loads) and bypasses the re-count window (distinct times). No-op outside
    /// the seam / when the log already has events.
    func seedDemoIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["PDJ_SEED_HISTORY"] != nil, events.isEmpty else { return }
        let now = Date().timeIntervalSince1970 * 1000
        let hour = 60.0 * 60 * 1000
        // Large-set knob (PDJ_SEED_HISTORY_COUNT=N) for exercising incremental paging: N distinct
        // plays, each a distinct song + timestamp, cycling the source templates.
        if let raw = env["PDJ_SEED_HISTORY_COUNT"], let n = Int(raw), n > 0 {
            let templates: [(PlayContext, String)] = [
                (PlayContext(source: .mix, contextId: "d", contextName: "Friday Night Mix"), "Track"),
                (PlayContext(source: .playlist, contextId: "d", contextName: "Roadtrip"), "Song"),
                (PlayContext(source: .pocket, contextId: "d", contextName: "Warmup"), "Cut"),
                (PlayContext.browser, "Single"),
                (PlayContext(source: .setlist, contextId: "d", contextName: "Saturday Set"), "Number"),
            ]
            for i in 0..<n {
                let t = templates[i % templates.count]
                record(songId: "seed_\(i)", title: "\(t.1) \(i + 1)", artist: "Artist \(i % 20)",
                       context: t.0, at: now - Double(i + 1) * hour)
            }
            return
        }
        let demos: [(id: String, title: String, artist: String, ctx: PlayContext, ago: Double)] = [
            ("seed_1", "Midnight City", "M83", PlayContext(source: .mix, contextId: "d", contextName: "Friday Night Mix"), 2 * hour),
            ("seed_2", "Roygbiv", "Boards of Canada", PlayContext(source: .playlist, contextId: "d", contextName: "Roadtrip"), 26 * hour),
            ("seed_3", "Teardrop", "Massive Attack", PlayContext(source: .pocket, contextId: "d", contextName: "Warmup"), 50 * hour),
            ("seed_1", "Midnight City", "M83", PlayContext.browser, 74 * hour),
            ("seed_4", "Xtal", "Aphex Twin", PlayContext(source: .setlist, contextId: "d", contextName: "Saturday Set"), 100 * hour),
        ]
        for d in demos {
            record(songId: d.id, title: d.title, artist: d.artist, context: d.ctx, at: now - d.ago)
        }
    }

    /// Wipe the log (Settings ▸ Storage "clear history"). Keeps the install identity.
    func clear() {
        events = []
        rebuildIndexes()
        revision &+= 1
        save()
    }

    // MARK: - Internals

    private func trimToCap() {
        let overflow = events.count - Self.maxEvents
        if overflow > 0 {
            events.removeFirst(overflow)
            rebuildIndexes()
        }
    }

    private func rebuildIndexes() {
        var last: [String: Double] = [:]
        var counts: [String: Int] = [:]
        for e in events {
            last[e.songId] = max(last[e.songId] ?? 0, e.playedAt)
            counts[e.songId, default: 0] += 1
        }
        lastPlayedIndex = last
        countIndex = counts
    }

    private func save() {
        let doc = Document(installId: installId, events: events)
        if let data = try? JSONEncoder().encode(doc) { try? data.write(to: fileURL, options: .atomic) }
    }
}

let playHistorySchemaVersion = 1
