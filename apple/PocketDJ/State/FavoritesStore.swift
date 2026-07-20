import Foundation
import Observation

/// Per-profile song FAVORITES — the ♥ toggle on song rows, the song detail page, and the
/// album track table, plus the Browse "favorite / not favorite" filter.
///
/// DOCTRINE (Levi 2026-07-20), three rules that shape everything here:
///
///   1. **Favorites are PER PROFILE, never global.** They live in their own
///      Application Support document synced through `CloudSyncService` — i.e. the
///      signed-in Apple ID's PRIVATE CloudKit database. A beta tester's favorites reach
///      the tester's own devices and nowhere else; they are structurally incapable of
///      reaching Levi's. Vinyl and "My Digital" favorites in particular stay personal —
///      they are never published to the shared catalog.
///
///   2. **Apple Music two-way sync is OWNER-ONLY.** Only the owner's install pushes ♥ to
///      Apple Music / pulls loves back (see `OwnerIdentity` + `FavoritesSyncService`).
///      This store is deliberately ignorant of that gate: it records intent and fires
///      `onChanged`; the sync service decides whether that intent leaves the device.
///
///   3. **Unfavorites are FIRST-CLASS, not absences.** An explicit un-♥ is stored as a
///      `favorited: false` TOMBSTONE rather than a deleted row. Two things depend on it:
///      the tester seed (below) must not resurrect something the user deliberately
///      removed, and an Apple Music pull must be able to tell "never favorited" from
///      "deliberately unfavorited" (the latter wins locally until the user says otherwise).
///
/// SEEDING: a tester's first run applies a shipped snapshot of the owner's APPLE MUSIC
/// favorites (`Config.favoritesSeedURL`) as their initial state — Apple-Music-sourced ids
/// only, so the owner's personal vinyl/digital ♥ never ship. Applied once per
/// `seedVersion`, and never over an existing explicit entry (tombstone or favorite).
///
/// Persists to Application Support `pocketdj-favorites.json` — the `DiscoverAddsStore`
/// durable-JSON pattern: decode-on-init, atomic save, `PDJ_USE_FIXTURE` seam.
@MainActor
@Observable
final class FavoritesStore {

    /// One song's favorite state. `favorited: false` is a TOMBSTONE (see rule 3), not a
    /// deletion — absence means "never touched", which is a different thing.
    struct Entry: Codable, Equatable {
        var songId: String
        var favorited: Bool
        /// When the user last toggled this (epoch ms). Drives the Apple Music
        /// reconcile tie-break: a local edit NEWER than the last pull wins.
        var atMs: Double
        /// Apple Music catalog id captured at toggle time, so an outbound push can run
        /// later (queued/offline/retry) without re-resolving the song against the catalog.
        /// Nil for vinyl / My Digital / Studio songs — those are local-only by nature.
        var appleMusicId: String?
        /// Set once this entry's state has been successfully mirrored to Apple Music.
        /// `nil` (or older than `atMs`) means "still owed an outbound push".
        var pushedAtMs: Double?
    }

    private struct Document: Codable {
        var schemaVersion: Int = 1
        var entries: [Entry] = []
        /// Highest seed version already applied — keeps a re-run from resurrecting
        /// favorites the user removed. Optional for forward/back compat.
        var seedVersion: Int?
    }

    /// songId → entry. The single source of truth; `favoriteIds` is a derived cache.
    private(set) var byId: [String: Entry] = [:]

    /// The ids currently favorited — the set Browse's filter and every row's ♥ read.
    /// Maintained alongside `byId` so a row's `isFavorite` is O(1) and the Browse filter
    /// never walks the dictionary (the ~90k-row hot path).
    private(set) var favoriteIds: Set<String> = []

    /// Seed generation already applied (0 = none). Surfaced for the owner's seed export.
    private(set) var seedVersion: Int = 0

    @ObservationIgnored private let fileURL: URL
    /// The on-disk document CloudSyncService syncs (same-URL doctrine as the other stores).
    var syncFileURL: URL { fileURL }

    /// Fired for every state change that ORIGINATES on this device (a user toggle) — the
    /// app wires this to `FavoritesSyncService` so an owner install mirrors it to Apple
    /// Music. Deliberately NOT fired by `reloadFromDisk` or `applySeed`: a cloud pull is
    /// already-known state and a seed is not the user's own act, so neither should
    /// generate outbound Apple Music writes.
    @ObservationIgnored var onChanged: ((Entry) -> Void)?

    init(fileURL: URL = FavoritesStore.defaultURL()) {
        self.fileURL = fileURL
        let doc = Self.decode(fileURL)
        adopt(doc)
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-favorites.json")
    }

    /// Under UI tests use an isolated, freshly-cleared file (the ProfileStore.launchURL idiom).
    ///
    /// `PDJ_KEEP_FIXTURE_FAVORITES=1` keeps the same fixture file across a relaunch instead of
    /// clearing it — the seam a UI test needs to prove a ♥ actually reached disk and survives
    /// the decode-on-init path, which an always-cleared file makes untestable by construction.
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-uitest-favorites.json")
            if ProcessInfo.processInfo.environment["PDJ_KEEP_FIXTURE_FAVORITES"] != "1" {
                try? FileManager.default.removeItem(at: url)
            }
            return url
        }
        return defaultURL()
    }

    // MARK: - Reads

    func isFavorite(_ songId: String) -> Bool { favoriteIds.contains(songId) }

    /// The explicit entry for a song, if the user has ever touched it (favorite OR
    /// tombstone). Nil means "never touched" — which seeding is allowed to fill.
    func entry(_ songId: String) -> Entry? { byId[songId] }

    /// Entries still owed an outbound Apple Music write (never pushed, or edited since the
    /// last push) AND actually mirrorable — i.e. carrying an Apple Music catalog id.
    /// Vinyl / My Digital / Studio favorites are excluded by construction: they have no
    /// Apple Music identity, so there is nothing upstream to write.
    var pendingPushes: [Entry] {
        byId.values
            .filter { $0.appleMusicId != nil && ($0.pushedAtMs ?? -1) < $0.atMs }
            .sorted { $0.atMs < $1.atMs }
    }

    // MARK: - Writes (user-originated)

    /// Flip a song's favorite state and return the new value. The ONE call every ♥ button
    /// makes. `appleMusicId` is the song's catalog id when it has one (nil for vinyl /
    /// digital / studio songs, which stay local-only forever).
    @discardableResult
    func toggle(_ songId: String, appleMusicId: String?) -> Bool {
        let next = !isFavorite(songId)
        set(songId, favorited: next, appleMusicId: appleMusicId)
        return next
    }

    /// Set an explicit favorite state (idempotent — a no-op write still refreshes nothing
    /// and fires nothing, so repeated taps of an already-correct state cost nothing).
    func set(_ songId: String, favorited: Bool, appleMusicId: String?) {
        if let existing = byId[songId], existing.favorited == favorited,
           existing.appleMusicId == (appleMusicId ?? existing.appleMusicId) {
            return
        }
        // Keep a previously-known catalog id when the caller doesn't supply one — the id
        // is a property of the SONG, and losing it would strand a pending push.
        let amId = appleMusicId ?? byId[songId]?.appleMusicId
        let entry = Entry(songId: songId, favorited: favorited,
                          atMs: Date().timeIntervalSince1970 * 1000,
                          appleMusicId: amId, pushedAtMs: nil)
        apply(entry)
        save()
        onChanged?(entry)
    }

    /// Mark an entry as successfully mirrored to Apple Music at `atMs`. Guarded on the
    /// toggle timestamp: if the user re-toggled while the push was in flight, the newer
    /// local edit stays pending rather than being marked clean by the stale write.
    func markPushed(songId: String, pushedAtMs: Double) {
        guard var e = byId[songId], e.atMs <= pushedAtMs else { return }
        e.pushedAtMs = pushedAtMs
        apply(e)
        save()
    }

    // MARK: - Writes (remote-originated)

    /// Adopt Apple Music's view of a song's love state (the inbound half of two-way sync).
    /// LOCAL EDITS WIN: a toggle made after `since` is not overwritten, so a ♥ made offline
    /// on the phone survives a pull that still shows the old upstream state. Returns true
    /// when the store actually changed.
    @discardableResult
    func applyRemote(songId: String, favorited: Bool, appleMusicId: String?, observedAtMs: Double) -> Bool {
        if let existing = byId[songId] {
            if existing.atMs > observedAtMs { return false }          // local edit is newer
            if existing.favorited == favorited {
                // Same state — record that upstream agrees so it stops looking pending.
                if (existing.pushedAtMs ?? -1) < existing.atMs {
                    markPushed(songId: songId, pushedAtMs: observedAtMs)
                }
                return false
            }
        }
        let entry = Entry(songId: songId, favorited: favorited, atMs: observedAtMs,
                          appleMusicId: appleMusicId ?? byId[songId]?.appleMusicId,
                          pushedAtMs: observedAtMs)
        apply(entry)
        save()
        return true                                                    // no onChanged — inbound
    }

    /// Apply the shipped owner-favorites seed as a NEW profile's initial state. Only fills
    /// songs the user has never touched (rule 3) and only runs once per `version`.
    /// Returns the number of entries actually seeded.
    @discardableResult
    func applySeed(songIds: [String], appleMusicIds: [String: String] = [:], version: Int) -> Int {
        guard version > seedVersion else { return 0 }
        let now = Date().timeIntervalSince1970 * 1000
        var seeded = 0
        for id in songIds where byId[id] == nil {
            // Seeded rows are marked pushed: they describe the OWNER's Apple Music state,
            // and must never generate outbound writes against a tester's account.
            apply(Entry(songId: id, favorited: true, atMs: now,
                        appleMusicId: appleMusicIds[id], pushedAtMs: now))
            seeded += 1
        }
        seedVersion = version
        save()
        return seeded
    }

    /// Re-decode after CloudSyncService pulled a newer copy. No `onChanged` — a pull is
    /// already-known state, and re-emitting it would push the cloud's view straight back
    /// up to Apple Music in a loop.
    func reloadFromDisk() {
        adopt(Self.decode(fileURL))
    }

    /// Wipe every favorite and tombstone — the destructive "clear all favorites" control.
    /// Deletes the on-disk document and resets the in-memory @Observable state to empty so
    /// the ♥ across the UI updates immediately. No `onChanged` — a wipe is not a per-song
    /// user toggle, so it generates no outbound Apple Music writes. `removeItem` swallows a
    /// missing file the same way `decode`/`save` swallow their I/O errors.
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        adopt(Document())
    }

    // MARK: - Internals

    private func apply(_ entry: Entry) {
        byId[entry.songId] = entry
        if entry.favorited { favoriteIds.insert(entry.songId) } else { favoriteIds.remove(entry.songId) }
    }

    private func adopt(_ doc: Document) {
        byId = Dictionary(uniqueKeysWithValues: doc.entries.map { ($0.songId, $0) })
        favoriteIds = Set(doc.entries.filter(\.favorited).map(\.songId))
        seedVersion = doc.seedVersion ?? 0
    }

    private nonisolated static func decode(_ url: URL) -> Document {
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return Document() }
        return doc
    }

    /// Save-coalescing depth. `save()` rebuilds and rewrites the WHOLE document, so calling
    /// it once per song inside a bulk reconcile is O(n²) encoding plus n atomic writes — and
    /// this is a @MainActor class, so on an Apple Music pull over a large library that lands
    /// as a multi-second launch freeze. `withCoalescedSaves` lets a bulk caller mutate freely
    /// and pay for exactly one write at the end.
    @ObservationIgnored private var saveDepth = 0
    @ObservationIgnored private var saveMissed = false

    /// Run `body`, collapsing every `save()` it triggers into a single trailing write.
    /// Re-entrant, and still writes exactly once if `body` throws partway.
    func withCoalescedSaves<T>(_ body: () throws -> T) rethrows -> T {
        saveDepth += 1
        defer {
            saveDepth -= 1
            if saveDepth == 0, saveMissed { saveMissed = false; save() }
        }
        return try body()
    }

    private func save() {
        guard saveDepth == 0 else { saveMissed = true; return }
        let doc = Document(entries: byId.values.sorted { $0.songId < $1.songId },
                           seedVersion: seedVersion == 0 ? nil : seedVersion)
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Rewrite song ids after a provisional (`amrec_`) entry is superseded by its indexed
    /// replacement — the same remap `CollectionsStore.remapSongIds` performs, so a ♥ made
    /// on a Discover add survives the nightly indexer landing the real track.
    func remapSongIds(_ pairs: [(from: String, to: String)]) {
        guard !pairs.isEmpty else { return }
        var changed = false
        for (from, to) in pairs {
            guard var e = byId.removeValue(forKey: from) else { continue }
            favoriteIds.remove(from)
            e.songId = to
            // A destination the user already touched explicitly wins over the remapped one.
            if byId[to] == nil { apply(e) }
            changed = true
        }
        if changed { save() }
    }
}
