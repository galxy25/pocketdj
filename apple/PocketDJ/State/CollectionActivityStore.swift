import Foundation
import Observation

/// The device-local, APPEND-ONLY log of COLLECTION ACTIVITY — every time the user ADDs an item to
/// a pocket/playlist, HEARTs / un-HEARTs a song, or REMOVEs an item from a collection. It powers
/// the Activity segment of the History view (a timeline of "Added X to Y", "♥ Hearted Z", "Removed
/// X from Y") alongside the song-play timeline.
///
/// ── Why a NEW store, not PlayHistoryStore/PlayEvent ─────────────────────────────────────────────
/// PlayEvent is deliberately song-play-centric: its 30 s same-song re-count window + the
/// countIndex/lastPlayedIndex it maintains feed the "recently played" collection sort and the
/// group-by-song History reads. An add/heart/remove is a different KIND of fact — no re-count
/// window, no per-song aggregate — so bolting it onto PlayEvent would corrupt those reads. This is
/// its own append-only file (`pocketdj-collection-activity.json`), zero wipe-risk to the play log.
///
/// ── Shape mirrors PlayHistoryStore ──────────────────────────────────────────────────────────────
/// Same proven durable-JSON idiom: atomic save, decode-on-init, `PDJ_USE_FIXTURE` launch seam, a
/// `maxEvents` cap, a monotonic `revision` the view keys recomputes on, a stable per-event `UUID` +
/// a document `installId` so a future cross-profile merge is just `union(by: id)` (see `merge`).
@MainActor
@Observable
final class CollectionActivityStore {

    /// What happened. Raw values are the persisted tokens — never rename.
    enum ActivityKind: String, Codable, CaseIterable, Hashable {
        case add, heart, unheart, remove

        /// SF Symbol for the timeline accessory.
        var symbol: String {
            switch self {
            case .add:     return "plus.circle"
            case .heart:   return "heart.fill"
            case .unheart: return "heart.slash"
            case .remove:  return "minus.circle"
            }
        }
    }

    /// One activity event. `itemTitle` / `collectionName` are SNAPSHOTS at record time so the row
    /// stays readable after the item leaves the catalog or the collection is renamed/deleted.
    /// `collectionId`/`collectionKind`/`collectionName` are nil for HEART events (a ♥ isn't scoped
    /// to a collection). Studio items (`smp_`/`lp_`/`ptn_`/`tk_`) have no catalog song, so their
    /// title is snapshotted here (or nil ⇒ the row falls back to the id).
    struct ActivityEvent: Codable, Identifiable, Equatable, Hashable {
        var id: UUID
        /// Epoch ms of the event.
        var at: Double
        var kind: ActivityKind
        var itemId: String
        var itemTitle: String?
        var collectionId: String?
        var collectionKind: String?    // AddTarget.Kind raw ("pocket" / "playlist"); nil for heart
        var collectionName: String?
    }

    /// The persisted, versioned document. LENIENT decode (like the collections document): a
    /// missing/older/partial blob never throws — a missing `events` list ⇒ [], a missing
    /// `installId` ⇒ a fresh one, unknown keys ignored — so an empty or forward-version file loads
    /// degraded rather than resetting the store.
    struct Document: Codable {
        var schemaVersion: Int = collectionActivitySchemaVersion
        /// Stable identity of THIS install — the merge attribution key.
        var installId: String
        var events: [ActivityEvent] = []

        init(schemaVersion: Int = collectionActivitySchemaVersion, installId: String, events: [ActivityEvent] = []) {
            self.schemaVersion = schemaVersion; self.installId = installId; self.events = events
        }

        enum CodingKeys: String, CodingKey { case schemaVersion, installId, events }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? collectionActivitySchemaVersion
            installId = (try? c.decode(String.self, forKey: .installId)) ?? UUID().uuidString
            events = (try? c.decode([ActivityEvent].self, forKey: .events)) ?? []
        }
    }

    /// The append-only log, oldest → newest.
    private(set) var events: [ActivityEvent] = []
    /// Stable id of this install (for a future cross-profile merge).
    private(set) var installId: String
    /// Monotonic, bumped on every real mutation — the History view keys its recompute on this.
    private(set) var revision = 0

    @ObservationIgnored private let fileURL: URL
    /// The on-disk document CloudSyncService syncs (registration reads the SAME URL the store was
    /// constructed with — never re-derives it, so fixture seams stay intact).
    var syncFileURL: URL { fileURL }

    /// The log is append-only and would otherwise grow without bound. Cap it and drop the oldest.
    nonisolated static let maxEvents = 20_000

    init(fileURL: URL = CollectionActivityStore.defaultURL()) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            events = doc.events
            installId = doc.installId
        } else {
            installId = UUID().uuidString
        }
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-collection-activity.json")
    }

    /// Under UI tests use an isolated, freshly-cleared file (deterministic, never touches the
    /// user's real activity log). Mirrors PlayHistoryStore.launchURL.
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-collection-activity.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    /// Record an activity event. `at` is injectable for tests; callers use the default (now).
    /// Returns the appended event (empty `itemId` is ignored → nil).
    @discardableResult
    func record(kind: ActivityKind, itemId: String, itemTitle: String? = nil,
                collectionId: String? = nil, collectionKind: String? = nil, collectionName: String? = nil,
                at nowMs: Double = Date().timeIntervalSince1970 * 1000) -> ActivityEvent? {
        guard !itemId.isEmpty else { return nil }
        let event = ActivityEvent(id: UUID(), at: nowMs, kind: kind, itemId: itemId, itemTitle: itemTitle,
                                  collectionId: collectionId, collectionKind: collectionKind,
                                  collectionName: collectionName)
        events.append(event)
        if events.count > Self.maxEvents { trimToCap() }
        revision &+= 1
        save()
        return event
    }

    /// Test/merge seam: replace the whole log (persists).
    func replaceAll(_ newEvents: [ActivityEvent]) {
        events = newEvents
        if events.count > Self.maxEvents { trimToCap() }
        revision &+= 1
        save()
    }

    /// Cross-profile merge seam: UNION `incoming` into the log by event id (idempotent — importing
    /// the same log twice is a no-op), re-sorted chronologically. Aggregate-free by design, so this
    /// is a clean set-union (unlike the play stats, which can't un-double a summed count).
    func merge(with incoming: [ActivityEvent]) {
        var byId = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for e in incoming where byId[e.id] == nil { byId[e.id] = e }
        events = byId.values.sorted { $0.at < $1.at }
        if events.count > Self.maxEvents { trimToCap() }
        revision &+= 1
        save()
    }

    /// Wipe the log (account deletion / clear history). Keeps the install identity.
    func clear() {
        events = []
        revision &+= 1
        save()
    }

    // MARK: - Internals

    private func trimToCap() {
        let overflow = events.count - Self.maxEvents
        if overflow > 0 { events.removeFirst(overflow) }
    }

    private func save() {
        let doc = Document(installId: installId, events: events)
        if let data = try? JSONEncoder().encode(doc) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// Re-decode the on-disk document after CloudSyncService pulled a newer cloud copy
    /// (whole-document LWW). Adopts the cloud doc's installId too, like PlayHistoryStore.
    func reloadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return }
        events = doc.events
        installId = doc.installId
        revision &+= 1
    }
}

let collectionActivitySchemaVersion = 1
