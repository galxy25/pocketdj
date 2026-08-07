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
///
/// ── Why the cursors are a WINDOW, not a high-water mark ─────────────────────────────────────
/// The three source stores are CloudKit-synced with UNION merges that insert a PEER's events
/// carrying their ORIGINAL, older timestamps (`PlayHistoryStore.reloadFromDisk` and friends).
/// The engine toggle lives in `SettingsStore` (UserDefaults, device-local by design), so
/// "ON on the phone, OFF on the Mac" is the NORMAL configuration — the Mac uploads nothing and
/// its plays arrive here below this device's high-water mark. A strict `atMs > cursor` filter
/// therefore skipped them FOREVER, silently: the server's history permanently missed every
/// play made on the other device.
///
/// So each stream selects `atMs >= cursor - overlapWindow` (30 days) MINUS the ids this device
/// has already had acknowledged (`SyncState.uploaded*`, pruned by the same floor). Re-sends are
/// harmless — the server dedupes plays/activity/puzzle by event id and merges favorites LWW —
/// and the ack list is what keeps a quiet flush at zero requests instead of re-uploading the
/// whole window every 10 minutes. It also fixes the exact-millisecond straddle at a batch
/// boundary that the strict `>` could strand.
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
        /// Acknowledged uploads inside the trailing overlap window, one `"<atMs>|<id>"` entry
        /// each (see the type doc). ADDITIVE-OPTIONAL: an older doc decodes to empty, which
        /// only costs one idempotent re-send of the window.
        var uploadedPlays: [String] = []
        var uploadedFavorites: [String] = []
        var uploadedActivity: [String] = []
        var uploadedPuzzle: [String] = []

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, lastPlayAtMs, lastFavoriteAtMs, lastActivityAtMs,
                 lastPuzzleAtMs, lastCollectionsHash, lastSyncedAtMs,
                 uploadedPlays, uploadedFavorites, uploadedActivity, uploadedPuzzle
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
            uploadedPlays = (try? c.decode([String].self, forKey: .uploadedPlays)) ?? []
            uploadedFavorites = (try? c.decode([String].self, forKey: .uploadedFavorites)) ?? []
            uploadedActivity = (try? c.decode([String].self, forKey: .uploadedActivity)) ?? []
            uploadedPuzzle = (try? c.decode([String].self, forKey: .uploadedPuzzle)) ?? []
        }
    }

    /// The account-deletion tombstone: the server-side DELETE that failed (offline / 503) so a
    /// later launch can finish the erasure the user asked for. Deliberately NOT CloudSynced.
    private struct PendingDeleteDoc: Codable {
        var schemaVersion: Int?
        var key: String?
        var profileId: String?
        var requestedAtMs: Double?
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
    /// Sibling of the key doc — `…-rec-pending-delete.json` next to it.
    @ObservationIgnored private var pendingDeleteFileURL: URL {
        keyFileURL.deletingLastPathComponent()
            .appendingPathComponent(keyFileURL.deletingPathExtension().lastPathComponent
                                    + "-pending-delete.json")
    }
    /// The on-disk key doc CloudSyncService syncs (same-URL doctrine as every store).
    var keySyncFileURL: URL { keyFileURL }

    @ObservationIgnored private var sync = SyncState()
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var isFlushing = false
    @ObservationIgnored private var autoFlushTask: Task<Void, Never>?
    /// Which `startAutoFlush` armed the live loop. A cancelled loop's tail must not detach the
    /// handle of the loop that REPLACED it (see `startAutoFlush`).
    @ObservationIgnored private var autoFlushGeneration = 0
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    /// Per-song collection-suggestion cache (wire rows so the Add sheet can re-filter): LRU
    /// cap 20, TTL 15 min.
    @ObservationIgnored private var suggestionCache: [String: (atMs: Double, wire: [RecCollectionSuggestionWire])] = [:]
    @ObservationIgnored private var suggestionCacheOrder: [String] = []

    private static let cacheTTLMs: Double = 15 * 60 * 1000
    private static let batchCap = 500
    /// How far BELOW each cursor a flush still looks, so a peer event merged in by CloudKit with
    /// an older timestamp still uploads (see the type doc). 30 days comfortably covers CloudKit
    /// pull latency; anything older than that on a device that has been flushing is already
    /// on the server.
    private static let overlapWindowMs: Double = 30 * 24 * 60 * 60 * 1000
    /// Safety bound on each remembered-ack list (the floor is what normally prunes it). An
    /// evicted entry costs one idempotent re-send, never a lost event.
    private static let ackCap = 10_000
    /// Client-side mirrors of the server's snapshot caps (`cleanSnapshot` in index.mjs) — the
    /// server truncates anyway; trimming here keeps the membership hash honest about what was
    /// actually uploaded.
    private static let snapshotCollectionCap = 500
    private static let snapshotSongIdCap = 5_000

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

    /// Launch-settle delay and loop period. Overridable so a unit test can drive the loop's
    /// cancel/re-arm race without waiting 20 s (the `fixtureForTesting` seam idiom).
    @ObservationIgnored var autoFlushDelayNs: UInt64 = 20 * 1_000_000_000
    @ObservationIgnored var autoFlushPeriodNs: UInt64 = 600 * 1_000_000_000

    /// Test-visible: is a loop armed? (the one-loop invariant this file guards).
    var isAutoFlushArmed: Bool { autoFlushTask != nil }

    /// Idempotent: ONE loop. Initial 20 s delay (launch settle), then flush every 10 min while
    /// enabled; exits when disabled (re-armed by `enabledDidChange`).
    ///
    /// The generation guard is load-bearing: a task cancelled mid-`postEvents` unwinds
    /// ASYNCHRONOUSLY, so an off→on toggle can arm the replacement BEFORE the cancelled task
    /// reaches its tail. An unconditional `autoFlushTask = nil` there wiped the replacement's
    /// handle, defeating the `guard` below — the next arm (another toggle, or a second macOS
    /// window's `.task`) then started a SECOND concurrent loop that no toggle-off could cancel.
    func startAutoFlush() {
        guard autoFlushTask == nil else { return }
        autoFlushGeneration &+= 1
        let generation = autoFlushGeneration
        autoFlushTask = Task { [weak self] in
            let delay = self?.autoFlushDelayNs ?? 20 * 1_000_000_000
            try? await Task.sleep(nanoseconds: delay)
            // Finishing an account deletion's server-side wipe is the ONE thing that runs
            // regardless of the toggle — it only ever DELETES data the user asked to erase.
            await self?.retryPendingCloudDelete()
            while !Task.isCancelled {
                guard let self, self.isEnabled else { break }
                await self.flushNow()
                try? await Task.sleep(nanoseconds: self.autoFlushPeriodNs)
            }
            guard let self, self.autoFlushGeneration == generation else { return }
            self.autoFlushTask = nil
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

    /// Upload everything inside each stream's trailing window that the server hasn't
    /// acknowledged yet, in ≤500-per-stream batches until drained (the server caps a batch at
    /// 2000 total events; 4 × 500 fits). Cursors advance ONLY to the max atMs actually SENT,
    /// acks are remembered ONLY on 2xx.
    func flushNow() async {
        guard isEnabled, !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        let key = ensureKey()
        let profileId = profileIdProvider()

        // The trailing overlap floors — everything at/after them is a candidate, minus what the
        // server already acknowledged. This is what lets a CloudKit-merged peer event (older
        // timestamp, below the cursor) still reach the server. See the type doc.
        let playFloor = Self.windowFloor(sync.lastPlayAtMs)
        let favFloor = Self.windowFloor(sync.lastFavoriteAtMs)
        let actFloor = Self.windowFloor(sync.lastActivityAtMs)
        let puzzleFloor = Self.windowFloor(sync.lastPuzzleAtMs)
        let sentPlays = Set(sync.uploadedPlays)
        let sentFavs = Set(sync.uploadedFavorites)
        let sentActs = Set(sync.uploadedActivity)
        let sentPuzzle = Set(sync.uploadedPuzzle)

        // Snapshot the deltas ON MAIN (cheap value-type filters over @MainActor stores).
        var plays = history.events
            .filter { $0.playedAt >= playFloor
                      && !sentPlays.contains(Self.ack($0.playedAt, $0.id.uuidString)) }
            .sorted { $0.playedAt < $1.playedAt }
            .map { RecPlayEventWire(id: $0.id.uuidString, songId: $0.songId,
                                    atMs: $0.playedAt, source: $0.source.rawValue) }
        var favs = favorites.byId.values
            .filter { $0.atMs >= favFloor && !sentFavs.contains(Self.ack($0.atMs, $0.songId)) }
            .sorted { $0.atMs < $1.atMs }
            .map { RecFavoriteWire(songId: $0.songId, favorited: $0.favorited, atMs: $0.atMs) }
        var acts = activity.events
            .filter { $0.at >= actFloor && !sentActs.contains(Self.ack($0.at, $0.id.uuidString)) }
            .sorted { $0.at < $1.at }
            .map { RecActivityWire(id: $0.id.uuidString, atMs: $0.at, kind: $0.kind.rawValue,
                                   itemId: $0.itemId, collectionId: $0.collectionId,
                                   collectionKind: $0.collectionKind, collectionName: $0.collectionName) }
        var puzzle = (puzzleEventsProvider?(puzzleFloor) ?? [])
            .filter { !sentPuzzle.contains(Self.ack($0.atMs, $0.id)) }
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
                syncError = Self.keyMismatchMessage
                return   // cursors NOT advanced
            } catch {
                syncError = "Couldn't reach the recommendation service."
                return   // cursors NOT advanced; retry next cycle
            }
            // 2xx: advance each cursor to the max atMs actually sent, and REMEMBER the ids so
            // the overlap window doesn't re-send them next flush.
            if let last = batchPlays.last { sync.lastPlayAtMs = max(sync.lastPlayAtMs, last.atMs) }
            if let last = batchFavs.last { sync.lastFavoriteAtMs = max(sync.lastFavoriteAtMs, last.atMs) }
            if let last = batchActs.last { sync.lastActivityAtMs = max(sync.lastActivityAtMs, last.atMs) }
            if let last = batchPuzzle.last { sync.lastPuzzleAtMs = max(sync.lastPuzzleAtMs, last.atMs) }
            sync.uploadedPlays = Self.remember(sync.uploadedPlays,
                                               batchPlays.map { Self.ack($0.atMs, $0.id) }, floor: playFloor)
            sync.uploadedFavorites = Self.remember(sync.uploadedFavorites,
                                                   batchFavs.map { Self.ack($0.atMs, $0.songId) }, floor: favFloor)
            sync.uploadedActivity = Self.remember(sync.uploadedActivity,
                                                  batchActs.map { Self.ack($0.atMs, $0.id) }, floor: actFloor)
            sync.uploadedPuzzle = Self.remember(sync.uploadedPuzzle,
                                                batchPuzzle.map { Self.ack($0.atMs, $0.id) }, floor: puzzleFloor)
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

    // MARK: - Overlap-window bookkeeping

    /// The floor a stream's flush filter uses: `cursor - overlapWindow`, never below 0.
    private static func windowFloor(_ cursor: Double) -> Double {
        max(0, cursor - overlapWindowMs)
    }

    /// One remembered ack, `"<atMs>|<id>"`. The timestamp rides so the list prunes EXACTLY by
    /// the window floor — a size-only cap would oscillate (evict → re-send → evict).
    private static func ack(_ atMs: Double, _ id: String) -> String {
        "\(Int(atMs.rounded()))|\(id)"
    }

    private static func ackAtMs(_ entry: String) -> Double {
        guard let sep = entry.firstIndex(of: "|") else { return 0 }
        return Double(entry[entry.startIndex..<sep]) ?? 0
    }

    /// Append the acks of a delivered batch and drop everything now below the floor (with a
    /// hard `ackCap` backstop, newest kept).
    private static func remember(_ existing: [String], _ added: [String], floor: Double) -> [String] {
        guard !added.isEmpty || !existing.isEmpty else { return existing }
        var kept = (existing + added).filter { ackAtMs($0) >= floor }
        if kept.count > ackCap { kept = Array(kept.suffix(ackCap)) }
        return kept
    }

    /// The current collections membership as the snapshot wire: pockets carry `songIds`
    /// directly; playlists flatten their `.song` node leaves recursively (membership, not
    /// resolution — albums/pockets are NOT expanded, mirroring `playlist(_:contains:)`).
    /// Trimmed to the server's own snapshot caps so the membership hash describes what the
    /// server actually stores.
    private func collectionsSnapshotWire() -> RecCollectionsSnapshotWire {
        var entries: [RecCollectionsSnapshotWire.Entry] = []
        for p in collections.pockets {
            entries.append(.init(id: p.id, kind: "pocket", name: p.name,
                                 songIds: Array(p.songIds.prefix(Self.snapshotSongIdCap))))
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
            entries.append(.init(id: pl.id, kind: "playlist", name: pl.name,
                                 songIds: Array(ids.prefix(Self.snapshotSongIdCap))))
        }
        return RecCollectionsSnapshotWire(atMs: Date().timeIntervalSince1970 * 1000,
                                          collections: Array(entries.prefix(Self.snapshotCollectionCap)))
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
            syncError = Self.keyMismatchMessage
        } catch {
            if forYou.isEmpty { syncError = "Couldn't reach the recommendation service." }
        }
    }

    /// The wedged-key message. It names a recovery that CAN succeed: "Delete cloud data" now
    /// presents the enrollment secret, which the server accepts in place of the bound key
    /// (before that it 403'd too, so the advice looped the user between two dead ends).
    private static let keyMismatchMessage =
        "This device's recommendation key doesn't match the cloud data. Tap Delete cloud data "
        + "below to reset it — your recommendations rebuild from this device's history."

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
    ///
    /// Works even when this device's key is the WRONG one (the wedge case): the request carries
    /// the enrollment secret, which the server accepts in place of the bound key. It also works
    /// when this device never minted a key — another device may have created state under the
    /// same profile id, and the user asked for it gone.
    @discardableResult
    func deleteCloudData() async -> Bool {
        let key = ensureKey()
        do {
            try await client.deleteState(key: key, profileId: profileIdProvider())
        } catch RecEngineClient.ClientError.keyMismatch {
            // Distinct from a transient failure: retrying with the same key can't help.
            syncError = "The server refused to delete this profile's data. "
                + "Update to the latest PocketDJ build and try again."
            return false
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
    ///
    /// `cloudDeleted` is the RESULT of the server-side delete that ran just before. When it
    /// FAILED (offline, a 503), wiping the key file here used to orphan the profile's
    /// `rec/state/<hash>.json` in S3 forever — the key was the only credential that could
    /// authorize the DELETE, the profile id that addresses the object is reset moments later,
    /// and the bucket has no lifecycle expiry. So on failure the key is PRESERVED and a
    /// tombstone (key + profile id) is written; `retryPendingCloudDelete` finishes the job on
    /// a later launch, then removes both.
    func clearLocal(cloudDeleted: Bool = true) {
        autoFlushTask?.cancel(); autoFlushTask = nil
        debounceTask?.cancel(); debounceTask = nil
        if cloudDeleted {
            try? FileManager.default.removeItem(at: keyFileURL)
            try? FileManager.default.removeItem(at: pendingDeleteFileURL)
            key = nil
        } else {
            writePendingDelete()
        }
        try? FileManager.default.removeItem(at: stateFileURL)
        sync = SyncState()
        forYou = []
        forYouFetchedAtMs = nil
        lastSyncedAtMs = nil
        suggestionCache = [:]
        suggestionCacheOrder = []
        syncError = nil
    }

    /// Is a server-side deletion still owed? (Settings ▸ Debug / tests; the retry is automatic.)
    var hasPendingCloudDelete: Bool {
        FileManager.default.fileExists(atPath: pendingDeleteFileURL.path)
    }

    private func writePendingDelete() {
        guard let key else { return }
        let doc = PendingDeleteDoc(schemaVersion: 1, key: key, profileId: profileIdProvider(),
                                   requestedAtMs: Date().timeIntervalSince1970 * 1000)
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: pendingDeleteFileURL, options: .atomic)
        }
    }

    /// Finish a deletion the network refused earlier. Runs on the auto-flush task's first pass
    /// (launch) and on foreground, and — deliberately — REGARDLESS of the Settings toggle: the
    /// user asked for their data to be erased, and this is the only call that can honor it.
    /// It is the single exception to "toggle off ⇒ zero network", and it only ever DELETES.
    /// No tombstone ⇒ no request at all, so a normal disabled install stays silent.
    func retryPendingCloudDelete() async {
        guard let data = try? Data(contentsOf: pendingDeleteFileURL),
              let doc = try? JSONDecoder().decode(PendingDeleteDoc.self, from: data),
              let pendingKey = doc.key, !pendingKey.isEmpty,
              let pendingProfile = doc.profileId, !pendingProfile.isEmpty else { return }
        do {
            try await client.deleteState(key: pendingKey, profileId: pendingProfile)
        } catch {
            return   // still owed — the next launch/foreground tries again
        }
        try? FileManager.default.removeItem(at: pendingDeleteFileURL)
        // The preserved key existed ONLY to authorize this delete.
        if key == pendingKey {
            try? FileManager.default.removeItem(at: keyFileURL)
            key = nil
        }
    }
}
