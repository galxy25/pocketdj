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
    /// `catalogAdd`/`catalogRemove` (appended 2026-07) track adds/removals to the user's
    /// LIBRARY/CATALOG itself (Discover ＋Add, imports, custom audio, and the Remove-from-Library
    /// action) — distinct from `.add`/`.remove` which scope to a pocket/playlist. They carry no
    /// `collection*` fields (like `.heart`). New raw values are decoded leniently (see
    /// `Document.init(from:)`) so an older build that lacks these cases skips the events instead of
    /// dropping the whole log.
    enum ActivityKind: String, Codable, CaseIterable, Hashable {
        case add, heart, unheart, remove, catalogAdd, catalogRemove

        /// SF Symbol for the timeline accessory.
        var symbol: String {
            switch self {
            case .add:           return "plus.circle"
            case .heart:         return "heart.fill"
            case .unheart:       return "heart.slash"
            case .remove:        return "minus.circle"
            case .catalogAdd:    return "square.and.arrow.down"
            case .catalogRemove: return "trash"
            }
        }
    }

    /// One activity event. `itemTitle` / `collectionName` are SNAPSHOTS at record time so the row
    /// stays readable after the item leaves the catalog or the collection is renamed/deleted.
    /// `collectionId`/`collectionKind`/`collectionName` are nil for HEART events (a ♥ isn't scoped
    /// to a collection). Studio items (`smp_`/`lp_`/`ptn_`/`tk_`) have no catalog song, so their
    /// title is snapshotted here (or nil ⇒ the row reads "an unknown item" and shows the raw id
    /// beneath it).
    struct ActivityEvent: Codable, Identifiable, Equatable, Hashable {
        var id: UUID
        /// Epoch ms of the event.
        var at: Double
        var kind: ActivityKind
        var itemId: String
        var itemTitle: String?
        /// Artist snapshot at record time. ADDITIVE-OPTIONAL (older/peer events have none → nil).
        /// Why it exists: a row whose `itemId` no longer resolves in the LOCAL catalog — the song
        /// came from an Apple Music source playlist and was never indexed on this device, or its
        /// source was toggled off — used to degrade to a bare namespaced id. Title alone is often
        /// ambiguous, so the artist is what makes such a row still identifiable (R3).
        var itemArtist: String?
        var collectionId: String?
        var collectionKind: String?    // AddTarget.Kind raw ("pocket" / "playlist"); nil for heart
        var collectionName: String?
        /// The `installId` of the device that ORIGINATED this event, stamped at record time.
        /// ADDITIVE-OPTIONAL (older/peer events have none → nil). Load-bearing for the Apple Music
        /// write-back BACKFILL: because this log is cloud-synced (a peer device's adds are UNIONed
        /// in via `reloadFromDisk`), a backfill that re-drove EVERY add would re-deliver an add
        /// another device already pushed upstream — a duplicate in the real Apple Music playlist,
        /// since the write-back queue that would dedup it is deliberately device-local. So the
        /// backfill only re-drives events this install originated (nil ⇒ legacy, treated as local).
        var originInstallId: String?
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
            // Decode each event LENIENTLY: a single event whose `kind` is an unknown raw value —
            // e.g. a NEWER app version (which added an ActivityKind case) synced this doc down to an
            // OLDER build — would otherwise throw and, via the `try?`, reset the ENTIRE log to []
            // (and then re-push that truncated log, clobbering peers' events in the cloud). Wrapping
            // each element so an unknown/malformed event decodes to nil and is dropped keeps every
            // event this build DOES understand. Forward-compatible for any future kinds too.
            events = ((try? c.decode([LenientEvent].self, forKey: .events)) ?? []).compactMap(\.event)
        }
    }

    /// Per-element tolerant wrapper: decodes an `ActivityEvent`, yielding nil instead of throwing
    /// when the event can't be decoded (chiefly an unknown `ActivityKind` raw value written by a
    /// newer build). Its own `init(from:)` never throws, so the containing `[LenientEvent]` decode
    /// always succeeds and simply omits the un-decodable rows.
    private struct LenientEvent: Decodable {
        let event: ActivityEvent?
        init(from decoder: Decoder) throws { event = try? ActivityEvent(from: decoder) }
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
    func record(kind: ActivityKind, itemId: String, itemTitle: String? = nil, itemArtist: String? = nil,
                collectionId: String? = nil, collectionKind: String? = nil, collectionName: String? = nil,
                at nowMs: Double = Date().timeIntervalSince1970 * 1000) -> ActivityEvent? {
        guard !itemId.isEmpty else { return nil }
        let event = ActivityEvent(id: UUID(), at: nowMs, kind: kind, itemId: itemId, itemTitle: itemTitle,
                                  itemArtist: itemArtist,
                                  collectionId: collectionId, collectionKind: collectionKind,
                                  collectionName: collectionName, originInstallId: installId)
        events.append(event)
        if events.count > Self.maxEvents { trimToCap() }
        revision &+= 1
        save()
        return event
    }

    /// UI-test seam (`PDJ_SEED_ACTIVITY`): seed three rows that exercise the THREE resolution
    /// states an activity row can be in, so a UI test can prove the R3 rendering on a real device
    /// rather than in a unit test. No-op outside the seam and once the log is non-empty.
    ///
    ///  1. RESOLVABLE — the item is in this device's catalog; the row names it from the LIVE catalog.
    ///  2. DENORMALIZED — the item is NOT in this catalog (the R3 case: an Apple Music song added
    ///     from a source playlist that was never indexed here), but the record-time title/artist
    ///     snapshots make it identifiable anyway.
    ///  3. BARE — neither catalog nor snapshot knows it (a legacy row recorded before the snapshots
    ///     existed); it reads "an unknown item" and shows the raw id beneath.
    func seedFixtureIfRequested() {
        guard ProcessInfo.processInfo.environment["PDJ_SEED_ACTIVITY"] != nil, events.isEmpty else { return }
        let now = Date().timeIntervalSince1970 * 1000
        record(kind: .add, itemId: "sng_1", itemTitle: "Neon", itemArtist: "Aria",
               collectionId: "pls_seed", collectionKind: "playlist", collectionName: "Warmup",
               at: now - 60_000)
        record(kind: .add, itemId: "am_9876543210", itemTitle: "Running It Up", itemArtist: "Aria",
               collectionId: "pls_seed_am", collectionKind: "playlist", collectionName: "AM Mix",
               at: now - 120_000)
        record(kind: .add, itemId: "sng_ghost_legacy", itemTitle: nil, itemArtist: nil,
               collectionId: "pls_seed_am", collectionKind: "playlist", collectionName: "AM Mix",
               at: now - 180_000)
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
    /// Deletes the on-disk document entirely (no residual empty-but-present JSON) so the
    /// AccountDeletionService "each store removes its persisted file" contract holds — the
    /// same true no-residual wipe as CollectionsStore/FavoritesStore.clear(). `removeItem`
    /// swallows a missing file exactly like `decode`/`save` swallow their I/O errors.
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        events = []
        revision &+= 1
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

    /// Re-adopt the on-disk document after CloudSyncService pulled a newer cloud copy.
    ///
    /// DELIBERATELY DIVERGES from PlayHistoryStore's whole-document LWW replace: this is an
    /// APPEND-ONLY, aggregate-free EVENT log, so a wholesale replace would let device B's log
    /// OVERWRITE device A's local events (a real user add/heart/remove silently lost). Instead we
    /// UNION the disk doc's events into the in-memory log by event id (idempotent — re-importing
    /// the same log is a no-op), keep ALL of them, and re-sort chronologically. This is strictly
    /// better than LWW here (no lost events) and O(n). We keep our OWN installId (this install
    /// continues to exist and merges peers in — mirrors `merge(with:)`, which also leaves it be),
    /// and we `save()` so the merged log is durable and rides the next push back up (the LWW
    /// reload can skip the save because it only re-reads what's already on disk; the union produces
    /// a superset that isn't yet persisted).
    func reloadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return }
        var byId = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for e in doc.events where byId[e.id] == nil { byId[e.id] = e }
        events = byId.values.sorted { $0.at < $1.at }
        if events.count > Self.maxEvents { trimToCap() }
        revision &+= 1
        save()
    }
}

let collectionActivitySchemaVersion = 1
