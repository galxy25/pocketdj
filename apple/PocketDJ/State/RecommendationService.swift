import Foundation
import Observation
import CryptoKit

/// The cloud RECOMMENDATION ENGINE orchestrator (WS-E): while — and ONLY while — the Settings
/// toggle "Use PocketDJ Recommendation Engine" is ON (default OFF), it batch-uploads deltas
/// derived from the EXISTING stores (play history / favorites / collection activity /
/// collections membership — no new recording hooks) to `Config.recEngineBase`, and serves the
/// two suggestion surfaces: the History ▸ For You tab and the Suggested-collections rows on
/// SongDetail + the Add-to-Collection sheet.
///
/// PRIVACY GATE: every network-touching method guards `isEnabled` first. There is no other
/// call site that can reach `RecEngineClient`, so toggle-off means literally zero calls.
///
/// TWO documents, deliberately different sync scopes:
///  • `pocketdj-rec-key.json` — the per-profile random bearer key, CloudSync-registered
///    ("rec-key") so every device of the same Apple ID presents the SAME key and the server's
///    trust-on-first-use binding holds across them. Minted lazily on the first flush while
///    enabled. NOTE: two devices enabling near-simultaneously can race the CloudKit LWW — the
///    loser's early uploads 403 until its key-doc pull lands (`reloadKeyFromDisk`), then
///    self-heal on the next flush.
///  • `pocketdj-rec-sync.json` — per-device upload cursors, NOT CloudSync-registered on
///    purpose: the server dedupes by event id, so two devices uploading overlapping unions is
///    harmless, while shared cursors would let one device's advance starve the other's upload.
@MainActor
@Observable
final class RecommendationService {

    // MARK: - View models

    struct SongSuggestion: Identifiable, Equatable {
        var songId: String
        var name: String
        var artist: String
        var reasons: [String]
        var id: String { songId }
    }

    struct CollectionSuggestion: Identifiable, Equatable {
        var id: String
        var kind: String
        var name: String
        var reasons: [String]
    }

    // MARK: - Observable state

    private(set) var forYou: [SongSuggestion] = []
    private(set) var forYouFetchedAtMs: Double?
    private(set) var isLoadingForYou = false
    private(set) var lastSyncedAtMs: Double?
    private(set) var syncError: String?

    // MARK: - Persisted documents

    /// The CloudKit-synced key doc (lenient decode — the settings-blob doctrine).
    private struct KeyDoc: Codable {
        var schemaVersion: Int?
        var key: String?
    }

    /// Device-local upload cursors. All fields default (0 / nil) so an older/partial doc
    /// decodes degraded, never resets.
    struct SyncState: Codable {
        var schemaVersion = 1
        var lastPlayAtMs: Double = 0
        var lastFavoriteAtMs: Double = 0
        var lastActivityAtMs: Double = 0
        var lastPuzzleAtMs: Double = 0
        var lastCollectionsHash: String?
        var lastSyncedAtMs: Double?

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, lastPlayAtMs, lastFavoriteAtMs, lastActivityAtMs,
                 lastPuzzleAtMs, lastCollectionsHash, lastSyncedAtMs
        }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
            lastPlayAtMs = (try? c.decode(Double.self, forKey: .lastPlayAtMs)) ?? 0
            lastFavoriteAtMs = (try? c.decode(Double.self, forKey: .lastFavoriteAtMs)) ?? 0
            lastActivityAtMs = (try? c.decode(Double.self, forKey: .lastActivityAtMs)) ?? 0
            lastPuzzleAtMs = (try? c.decode(Double.self, forKey: .lastPuzzleAtMs)) ?? 0
            lastCollectionsHash = try? c.decode(String.self, forKey: .lastCollectionsHash)
            lastSyncedAtMs = try? c.decode(Double.self, forKey: .lastSyncedAtMs)
        }
    }

    // MARK: - Dependencies

    @ObservationIgnored private let client: RecEngineClient
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let history: PlayHistoryStore
    @ObservationIgnored private let favorites: FavoritesStore
    @ObservationIgnored private let activity: CollectionActivityStore
    @ObservationIgnored private let collections: CollectionsStore
    @ObservationIgnored private let profileIdProvider: () -> String

    /// WS-D (Games tab / Collector's Puzzle) seam: events since a cursor. Ships nil; the Games
    /// workstream wires it in PocketDJApp when its store lands — this file must never reference
    /// a WS-D type beyond the wire struct.
    @ObservationIgnored var puzzleEventsProvider: ((_ sinceMs: Double) -> [RecPuzzleEventWire])?

    @ObservationIgnored private let keyFileURL: URL
    @ObservationIgnored private let stateFileURL: URL
    /// The on-disk key doc CloudSyncService syncs (same-URL doctrine as every store).
    var keySyncFileURL: URL { keyFileURL }

    @ObservationIgnored private var sync = SyncState()
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var isFlushing = false
    @ObservationIgnored private var autoFlushTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    /// Per-song collection-suggestion cache (wire rows so the Add sheet can re-filter): LRU
    /// cap 20, TTL 15 min.
    @ObservationIgnored private var suggestionCache: [String: (atMs: Double, wire: [RecCollectionSuggestionWire])] = [:]
    @ObservationIgnored private var suggestionCacheOrder: [String] = []

    private static let cacheTTLMs: Double = 15 * 60 * 1000
    private static let batchCap = 500

    init(client: RecEngineClient,
         settings: SettingsStore,
         history: PlayHistoryStore,
         favorites: FavoritesStore,
         activity: CollectionActivityStore,
         collections: CollectionsStore,
         profileIdProvider: @escaping () -> String,
         keyFileURL: URL = RecommendationService.launchKeyURL(),
         stateFileURL: URL = RecommendationService.launchStateURL()) {
        self.client = client
        self.settings = settings
        self.history = history
        self.favorites = favorites
        self.activity = activity
        self.collections = collections
        self.profileIdProvider = profileIdProvider
        self.keyFileURL = keyFileURL
        self.stateFileURL = stateFileURL
        if let data = try? Data(contentsOf: stateFileURL),
           let decoded = try? JSONDecoder().decode(SyncState.self, from: data) {
            sync = decoded
            lastSyncedAtMs = decoded.lastSyncedAtMs
        }
        key = Self.decodeKey(keyFileURL)
    }

    // MARK: - File locations (the launchURL fixture-seam idiom)

    nonisolated static func defaultKeyURL() -> URL {
        appSupport().appendingPathComponent("pocketdj-rec-key.json")
    }
    nonisolated static func defaultStateURL() -> URL {
        appSupport().appendingPathComponent("pocketdj-rec-sync.json")
    }
    nonisolated static func launchKeyURL() -> URL {
        fixtureURL("pdj-uitest-rec-key.json") ?? defaultKeyURL()
    }
    nonisolated static func launchStateURL() -> URL {
        fixtureURL("pdj-uitest-rec-sync.json") ?? defaultStateURL()
    }
    private nonisolated static func appSupport() -> URL {
        (try? FileManager.default.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
    }
    private nonisolated static func fixtureURL(_ name: String) -> URL? {
        guard ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    // MARK: - Gate

    /// UI-test / preview seam: canned suggestions with zero network. Requires BOTH env vars so
    /// a stray PDJ_REC_FIXTURE in a real run can never light the feature up.
    private static let fixtureOnEnv: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["PDJ_REC_FIXTURE"] == "1" && env["PDJ_USE_FIXTURE"] != nil
    }()

    /// Unit-test override for the env-derived fixture flag (a `static let` can't be flipped
    /// once evaluated). nil in the app — the env decides.
    @ObservationIgnored var fixtureForTesting: Bool?
    private var fixtureOn: Bool { fixtureForTesting ?? Self.fixtureOnEnv }

    /// THE privacy gate — every network-touching method guards this first.
    var isEnabled: Bool { fixtureOn || settings.recEngineEnabled }

    // MARK: - Key management

    private static func decodeKey(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(KeyDoc.self, from: data),
              let k = doc.key, !k.isEmpty else { return nil }
        return k
    }

    /// Re-decode after CloudSyncService pulled a peer's key doc — the self-heal for the
    /// two-devices-enabled-simultaneously race (the pulled key wins; next flush uses it).
    func reloadKeyFromDisk() {
        if let pulled = Self.decodeKey(keyFileURL) { key = pulled }
    }

    /// The key, minted + persisted on first use (32 random bytes, hex).
    private func ensureKey() -> String {
        if let key { return key }
        let minted = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        key = minted
        if let data = try? JSONEncoder().encode(KeyDoc(schemaVersion: 1, key: minted)) {
            try? data.write(to: keyFileURL, options: .atomic)
        }
        return minted
    }

    // MARK: - Auto flush

    /// Idempotent: one loop. Initial 20 s delay (launch settle), then flush every 10 min while
    /// enabled; exits when disabled (re-armed by `enabledDidChange`).
    func startAutoFlush() {
        guard autoFlushTask == nil else { return }
        autoFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            while !Task.isCancelled {
                guard let self, self.isEnabled else { break }
                await self.flushNow()
                try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            }
            self?.autoFlushTask = nil
        }
    }

    /// 5 s debounce then flush (the scenePhase-background hook).
    func flushSoon() {
        guard isEnabled else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.flushNow()
        }
    }

    // MARK: - Flush

    /// Upload everything past the cursors, in ≤500-per-stream batches until drained (the
    /// server caps a batch at 2000 total events; 4 × 500 fits). Cursors advance ONLY to the
    /// max atMs actually SENT, and only on 2xx.
    func flushNow() async {
        guard isEnabled, !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        let key = ensureKey()
        let profileId = profileIdProvider()

        // Snapshot the deltas ON MAIN (cheap value-type filters over @MainActor stores).
        var plays = history.events
            .filter { $0.playedAt > sync.lastPlayAtMs }
            .sorted { $0.playedAt < $1.playedAt }
            .map { RecPlayEventWire(id: $0.id.uuidString, songId: $0.songId,
                                    atMs: $0.playedAt, source: $0.source.rawValue) }
        var favs = favorites.byId.values
            .filter { $0.atMs > sync.lastFavoriteAtMs }
            .sorted { $0.atMs < $1.atMs }
            .map { RecFavoriteWire(songId: $0.songId, favorited: $0.favorited, atMs: $0.atMs) }
        var acts = activity.events
            .filter { $0.at > sync.lastActivityAtMs }
            .sorted { $0.at < $1.at }
            .map { RecActivityWire(id: $0.id.uuidString, atMs: $0.at, kind: $0.kind.rawValue,
                                   itemId: $0.itemId, collectionId: $0.collectionId,
                                   collectionKind: $0.collectionKind, collectionName: $0.collectionName) }
        var puzzle = (puzzleEventsProvider?(sync.lastPuzzleAtMs) ?? [])
            .sorted { $0.atMs < $1.atMs }

        let snapshot = collectionsSnapshotWire()
        let snapshotHash = Self.snapshotHash(snapshot)
        var pendingSnapshot: RecCollectionsSnapshotWire? =
            snapshotHash != sync.lastCollectionsHash ? snapshot : nil

        guard !plays.isEmpty || !favs.isEmpty || !acts.isEmpty || !puzzle.isEmpty
                || pendingSnapshot != nil else { return }

        while !plays.isEmpty || !favs.isEmpty || !acts.isEmpty || !puzzle.isEmpty
                || pendingSnapshot != nil {
            let batchPlays = Array(plays.prefix(Self.batchCap))
            let batchFavs = Array(favs.prefix(Self.batchCap))
            let batchActs = Array(acts.prefix(Self.batchCap))
            let batchPuzzle = Array(puzzle.prefix(Self.batchCap))
            let batch = RecUploadBatch(
                deviceId: DeviceIdentity.current,
                sentAtMs: Date().timeIntervalSince1970 * 1000,
                plays: batchPlays.isEmpty ? nil : batchPlays,
                favorites: batchFavs.isEmpty ? nil : batchFavs,
                activity: batchActs.isEmpty ? nil : batchActs,
                puzzle: batchPuzzle.isEmpty ? nil : batchPuzzle,
                collectionsSnapshot: pendingSnapshot)
            do {
                _ = try await client.postEvents(batch, key: key, profileId: profileId)
            } catch RecEngineClient.ClientError.keyMismatch {
                syncError = "Recommendation key mismatch — try Delete cloud data, then toggle off and on."
                return   // cursors NOT advanced
            } catch {
                syncError = "Couldn't reach the recommendation service."
                return   // cursors NOT advanced; retry next cycle
            }
            // 2xx: advance each cursor to the max atMs actually sent.
            if let last = batchPlays.last { sync.lastPlayAtMs = max(sync.lastPlayAtMs, last.atMs) }
            if let last = batchFavs.last { sync.lastFavoriteAtMs = max(sync.lastFavoriteAtMs, last.atMs) }
            if let last = batchActs.last { sync.lastActivityAtMs = max(sync.lastActivityAtMs, last.atMs) }
            if let last = batchPuzzle.last { sync.lastPuzzleAtMs = max(sync.lastPuzzleAtMs, last.atMs) }
            if pendingSnapshot != nil { sync.lastCollectionsHash = snapshotHash }
            pendingSnapshot = nil
            plays.removeFirst(batchPlays.count)
            favs.removeFirst(batchFavs.count)
            acts.removeFirst(batchActs.count)
            puzzle.removeFirst(batchPuzzle.count)
            let now = Date().timeIntervalSince1970 * 1000
            sync.lastSyncedAtMs = now
            lastSyncedAtMs = now
            syncError = nil
            persistSyncState()
        }
    }

    /// The current collections membership as the snapshot wire: pockets carry `songIds`
    /// directly; playlists flatten their `.song` node leaves recursively (membership, not
    /// resolution — albums/pockets are NOT expanded, mirroring `playlist(_:contains:)`).
    private func collectionsSnapshotWire() -> RecCollectionsSnapshotWire {
        var entries: [RecCollectionsSnapshotWire.Entry] = []
        for p in collections.pockets {
            entries.append(.init(id: p.id, kind: "pocket", name: p.name, songIds: p.songIds))
        }
        for pl in collections.playlists {
            var ids: [String] = []
            var seen = Set<String>()
            func walk(_ nodes: [PlaylistNode]) {
                for n in nodes {
                    if n.kind == .song, let id = n.songId, seen.insert(id).inserted { ids.append(id) }
                    if let kids = n.children { walk(kids) }
                }
            }
            walk(pl.sequences)
            entries.append(.init(id: pl.id, kind: "playlist", name: pl.name, songIds: ids))
        }
        return RecCollectionsSnapshotWire(atMs: Date().timeIntervalSince1970 * 1000,
                                          collections: entries)
    }

    /// Stable membership hash: one `id|kind|name|joined-songIds` line per entry, sorted, SHA-256.
    private static func snapshotHash(_ snapshot: RecCollectionsSnapshotWire) -> String {
        let lines = snapshot.collections
            .map { "\($0.id)|\($0.kind)|\($0.name)|\($0.songIds.joined(separator: ","))" }
            .sorted()
            .joined(separator: "\n")
        return SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func persistSyncState() {
        if let data = try? JSONEncoder().encode(sync) {
            try? data.write(to: stateFileURL, options: .atomic)
        }
    }

    // MARK: - For You

    func refreshForYou(force: Bool = false) async {
        guard isEnabled else { return }
        if fixtureOn {
            forYou = Self.fixtureForYou
            forYouFetchedAtMs = Date().timeIntervalSince1970 * 1000
            return
        }
        let now = Date().timeIntervalSince1970 * 1000
        if !force, let at = forYouFetchedAtMs, now - at < Self.cacheTTLMs, !forYou.isEmpty { return }
        isLoadingForYou = true
        defer { isLoadingForYou = false }
        await flushNow()   // recs should see the latest plays
        do {
            let resp = try await client.forYou(limit: 50, key: ensureKey(), profileId: profileIdProvider())
            forYou = resp.songs.map {
                SongSuggestion(songId: $0.songId, name: $0.name ?? $0.songId,
                               artist: $0.artist ?? "", reasons: $0.reasons ?? [])
            }
            forYouFetchedAtMs = Date().timeIntervalSince1970 * 1000
            syncError = nil
        } catch RecEngineClient.ClientError.keyMismatch {
            syncError = "Recommendation key mismatch — try Delete cloud data, then toggle off and on."
        } catch {
            if forYou.isEmpty { syncError = "Couldn't reach the recommendation service." }
        }
    }

    /// Fixture canned rows (only under the seam). They render standalone — For You rows never
    /// require catalog resolution.
    private static let fixtureForYou: [SongSuggestion] = [
        SongSuggestion(songId: "sng_fix_1", name: "Neon", artist: "Aria",
                       reasons: ["Same genre as recent plays"]),
        SongSuggestion(songId: "sng_fix_2", name: "Running It Up", artist: "Aria",
                       reasons: ["BPM near 120"]),
        SongSuggestion(songId: "sng_fix_3", name: "Golden Hour", artist: "Mira",
                       reasons: ["Often played together"]),
    ]

    // MARK: - Collection suggestions (SongDetail + Add sheet)

    func collectionSuggestions(for songId: String) async -> [CollectionSuggestion] {
        let wire = await rawCollectionSuggestions(for: songId)
        return wire.map {
            CollectionSuggestion(id: $0.id, kind: $0.kind ?? "playlist",
                                 name: $0.name ?? $0.id, reasons: $0.reasons ?? [])
        }
    }

    /// The cached wire rows (the Add sheet feeds these to `RecSuggestionFilter`).
    func rawCollectionSuggestions(for songId: String) async -> [RecCollectionSuggestionWire] {
        guard isEnabled else { return [] }
        if fixtureOn {
            var out: [RecCollectionSuggestionWire] = collections.playlists.prefix(2).map {
                RecCollectionSuggestionWire(id: $0.id, kind: "playlist", name: $0.name,
                                            score: 1.0, reasons: ["Fits this song"])
            }
            if let p = collections.pockets.first {
                out.append(RecCollectionSuggestionWire(id: p.id, kind: "pocket", name: p.name,
                                                       score: 1.0, reasons: ["Fits this song"]))
            }
            return out
        }
        let now = Date().timeIntervalSince1970 * 1000
        if let hit = suggestionCache[songId], now - hit.atMs < Self.cacheTTLMs { return hit.wire }
        do {
            let resp = try await client.collectionSuggestions(songId: songId, key: ensureKey(),
                                                              profileId: profileIdProvider())
            cacheSuggestions(songId: songId, wire: resp.suggestions, atMs: now)
            return resp.suggestions
        } catch {
            return []   // suggestion surfaces just stay hidden — never block UI
        }
    }

    private func cacheSuggestions(songId: String, wire: [RecCollectionSuggestionWire], atMs: Double) {
        suggestionCache[songId] = (atMs, wire)
        suggestionCacheOrder.removeAll { $0 == songId }
        suggestionCacheOrder.append(songId)
        while suggestionCacheOrder.count > 20 {
            suggestionCache.removeValue(forKey: suggestionCacheOrder.removeFirst())
        }
    }

    // MARK: - Lifecycle

    /// Settings toggled. OFF: stop the loops and clear the in-memory suggestion state (cursors
    /// + key are RETAINED — re-enable resumes incrementally; server state persists until the
    /// explicit "Delete cloud data"). ON: arm the auto-flush.
    func enabledDidChange() {
        if isEnabled {
            startAutoFlush()
        } else {
            autoFlushTask?.cancel(); autoFlushTask = nil
            debounceTask?.cancel(); debounceTask = nil
            forYou = []
            forYouFetchedAtMs = nil
            suggestionCache = [:]
            suggestionCacheOrder = []
            syncError = nil
        }
    }

    /// "Delete cloud data": remove the server-side state object. On success the cursors reset
    /// to zero so a later re-enable re-uploads history fresh. Explicitly NOT invoked by the
    /// toggle — a toggle flip stays cheap/reversible.
    @discardableResult
    func deleteCloudData() async -> Bool {
        guard let key else { return false }
        do {
            try await client.deleteState(key: key, profileId: profileIdProvider())
        } catch {
            syncError = "Couldn't delete the cloud data — try again."
            return false
        }
        sync = SyncState()
        persistSyncState()
        forYou = []
        forYouFetchedAtMs = nil
        suggestionCache = [:]
        suggestionCacheOrder = []
        syncError = nil
        return true
    }

    /// Account-deletion contract: remove both persisted files + in-memory reset.
    func clearLocal() {
        autoFlushTask?.cancel(); autoFlushTask = nil
        debounceTask?.cancel(); debounceTask = nil
        try? FileManager.default.removeItem(at: keyFileURL)
        try? FileManager.default.removeItem(at: stateFileURL)
        key = nil
        sync = SyncState()
        forYou = []
        forYouFetchedAtMs = nil
        lastSyncedAtMs = nil
        suggestionCache = [:]
        suggestionCacheOrder = []
        syncError = nil
    }
}
