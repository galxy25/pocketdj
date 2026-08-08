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
        /// The `installId` of the device that ORIGINATED this play, stamped at record time.
        /// ADDITIVE-OPTIONAL (older/peer events have none → nil, read as "this device").
        ///
        /// Load-bearing for two things once the log is UNIONed across devices: History can say
        /// where a play happened, and `rebuildIndexes` can keep the 30-second re-count window
        /// LOCAL — a play that arrived from another device must never suppress a genuine play here.
        var originInstallId: String?
    }

    /// The persisted, versioned document.
    struct Document: Codable {
        var schemaVersion: Int = playHistorySchemaVersion
        /// Stable identity of THIS install — the merge attribution key (see class doc).
        var installId: String
        var events: [PlayEvent] = []

        init(schemaVersion: Int = playHistorySchemaVersion, installId: String, events: [PlayEvent] = []) {
            self.schemaVersion = schemaVersion; self.installId = installId; self.events = events
        }

        enum CodingKeys: String, CodingKey { case schemaVersion, installId, events }

        /// LENIENT per-element decode, copied from `CollectionActivityStore`. Without it a single
        /// event carrying an unknown `PlaySource` raw value — written by a NEWER build and synced
        /// down to an older one — throws, the caller's `try?` yields nil, the log reads as EMPTY,
        /// and the next `record()` SAVES and PUSHES that empty log, destroying the real history on
        /// every device. Dropping the one unreadable event keeps everything this build understands.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? playHistorySchemaVersion
            installId = (try? c.decode(String.self, forKey: .installId)) ?? UUID().uuidString
            events = ((try? c.decode([LenientEvent].self, forKey: .events)) ?? []).compactMap(\.event)
        }
    }

    /// Per-element tolerant wrapper: yields nil instead of throwing, so one bad row can't take the
    /// whole log with it.
    private struct LenientEvent: Decodable {
        let event: PlayEvent?
        init(from decoder: Decoder) throws { event = try? PlayEvent(from: decoder) }
    }

    /// The append-only log, oldest → newest (insertion order == chronological for live plays).
    private(set) var events: [PlayEvent] = []
    /// Stable id of this install (for a future cross-profile merge).
    private(set) var installId: String
    /// Monotonic, bumped on every real mutation — the History view keys its recompute on this so
    /// a new play refreshes the timeline even when `events.count` is pinned at the cap.
    private(set) var revision = 0

    @ObservationIgnored private let fileURL: URL
    /// The on-disk document CloudSyncService syncs (registration reads the SAME URL the
    /// store was constructed with — never re-derives it, so fixture seams stay intact).
    var syncFileURL: URL { fileURL }
    /// O(1) dedupe + last-played reads: songId → most-recent playedAt. Rebuilt from `events`.
    @ObservationIgnored private var lastPlayedIndex: [String: Double] = [:]
    /// songId → number of events (History's group-by-song count). Rebuilt from `events`.
    @ObservationIgnored private var countIndex: [String: Int] = [:]
    /// songId → most-recent `playedAt` ACROSS EVERY DEVICE. Distinct from `lastPlayedIndex`, which
    /// is deliberately local-only (it drives the 30 s re-count window). This one answers "when was
    /// this song last listened to, anywhere", which is what the storage prune wants.
    @ObservationIgnored private var lastPlayedAnyDeviceIndex: [String: Double] = [:]

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
                              contextName: context.contextName, title: title, artist: artist,
                              originInstallId: installId)
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
        // FIXTURE variant (PDJ_SEED_HISTORY=fixture): plays of songs that exist in the bundled
        // fixture catalog, so a test can act on a History row against real catalog state —
        // add the selection to a playlist and see the playlist's song count move. The default
        // seed below deliberately uses ids the catalog does NOT know (it proves the snapshot
        // fallback renders), which no collection can resolve.
        if env["PDJ_SEED_HISTORY"] == "fixture" {
            let fixtures: [(id: String, title: String, artist: String, ago: Double)] = [
                ("sng_2", "Pulse", "Aria", 2 * hour),
                ("sng_3", "Drift", "Aria", 26 * hour),
                ("sng_4", "Swing Low", "Bento", 50 * hour),
            ]
            for f in fixtures {
                record(songId: f.id, title: f.title, artist: f.artist,
                       context: PlayContext(source: .playlist, contextId: "d", contextName: "Roadtrip"),
                       at: now - f.ago)
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

    /// Did this play happen on a DIFFERENT device? A nil origin is a legacy event from before
    /// attribution existed — this device's own, so it reads as local.
    func isFromAnotherDevice(_ e: PlayEvent) -> Bool {
        guard let origin = e.originInstallId else { return false }
        return origin != installId
    }

    private func rebuildIndexes() {
        var last: [String: Double] = [:]
        var counts: [String: Int] = [:]
        var lastAnywhere: [String: Double] = [:]
        for e in events {
            // COUNTS span every device — that is the point of a merged history.
            counts[e.songId, default: 0] += 1
            lastAnywhere[e.songId] = max(lastAnywhere[e.songId] ?? 0, e.playedAt)
            // The RE-COUNT WINDOW does not. `lastPlayedIndex` exists solely to collapse this
            // device's double-hook/seek re-notes within 30 s; folding a peer's play into it would
            // let a play on the Mac silently swallow a real play here seconds later. A nil origin
            // is a legacy event from before attribution — this device's own, so it counts.
            guard e.originInstallId == nil || e.originInstallId == installId else { continue }
            last[e.songId] = max(last[e.songId] ?? 0, e.playedAt)
        }
        lastPlayedIndex = last
        countIndex = counts
        lastPlayedAnyDeviceIndex = lastAnywhere
    }

    /// When this song was last played on ANY device, or nil if never. O(1).
    ///
    /// The storage prune evicts least-recently-PLAYED downloads, and Levi's call is that a play on
    /// another device counts: a track you listen to constantly on the Mac should not be first out
    /// of the phone's cache just because the phone wasn't the one playing it.
    func lastPlayedAtAnyDevice(_ songId: String) -> Double? { lastPlayedAnyDeviceIndex[songId] }

    private func save() {
        let doc = Document(installId: installId, events: events)
        if let data = try? JSONEncoder().encode(doc) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// UNION the on-disk document into the live log after CloudSyncService pulled a peer's copy.
    ///
    /// THIS USED TO BE A WHOLESALE REPLACE, and that is why history never worked across devices:
    /// the sync is whole-document last-writer-wins, so plays made on the Mac simply OVERWROTE the
    /// plays made on the phone. Union-by-event-id keeps both (idempotent — the same document
    /// applied twice changes nothing), which is exactly what `CollectionActivityStore` already
    /// does for the activity log.
    ///
    /// It also no longer adopts the pulled document's `installId`: this install continues to exist
    /// and is now merging peers IN, so its own identity must survive — otherwise its future plays
    /// would be attributed to whichever device it last pulled from.
    ///
    /// THE SAVE IS CONDITIONAL, for the reason Stage 3 established the hard way: `save()`
    /// re-encodes with THIS install's id, so its bytes always differ from the pulled payload. An
    /// unconditional save would leave the file dirty after EVERY pull, and since the sync compares
    /// mtimes and never content, two devices would push the whole log back and forth forever.
    @discardableResult
    func reloadFromDisk() -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return false }
        var byId = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var addedFromDisk = 0
        for e in doc.events where byId[e.id] == nil { byId[e.id] = e; addedFromDisk += 1 }
        // A superset worth publishing exists only if WE hold rows the pulled document lacks.
        let weHoldRowsTheDocLacks = byId.count > doc.events.count
        events = byId.values.sorted { $0.playedAt < $1.playedAt }
        if events.count > Self.maxEvents { trimToCap() }
        rebuildIndexes()
        if addedFromDisk > 0 || weHoldRowsTheDocLacks { revision &+= 1 }
        guard weHoldRowsTheDocLacks else { return false }
        save()
        return true
    }
}

let playHistorySchemaVersion = 1
